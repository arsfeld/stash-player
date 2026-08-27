import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'authenticated_url.dart';
import 'thumbnail_repository.dart';

/// Cache directory segment scoping this client's on-disk thumbnail cache.
/// Deliberately distinct from the released GTK client's own cache
/// directory (`stash-player-core::cache`) so the two never collide on a
/// machine that has both installed.
const String thumbnailCacheAppSegment = 'dev.arsfeld.stashplayer.flutter';

/// Fetches raw bytes for an authenticated thumbnail [uri], sending
/// [headers] (an `ApiKey` entry when a key is configured). Production
/// wires this to `http.Client.get`; tests inject a fake that can hold a
/// request open, so concurrency can be measured directly.
typedef ThumbnailFetcher =
    Future<http.Response> Function(Uri uri, Map<String, String> headers);

/// Decodes [bytes] and re-encodes the result as PNG at [width]x[height].
/// Production wires this to `ui.instantiateImageCodec`
/// ([defaultThumbnailResizer]); tests inject a fake to exercise decode
/// failure without needing real image data.
typedef ThumbnailResizer =
    Future<Uint8List> Function(Uint8List bytes, int width, int height);

/// [ThumbnailRepository] backed by an on-disk PNG cache, HTTP fetches
/// bounded to [thumbnailConcurrencyLimit] in-flight requests, and the
/// shared [authenticatedUrl] helper.
///
/// Correctness properties this type is specifically responsible for:
///
/// - The fetch permit is always released in a `finally`, on every exit
///   path (HTTP failure, non-2xx, decode failure, or success), so a
///   failure can never permanently shrink the pool.
/// - A cache write goes to a temporary sibling file that is then renamed
///   into place; rename within the same directory is atomic, so a reader
///   (or a crash) never observes a partially written PNG.
/// - A failed fetch or decode is never written to disk — a transient
///   server error is retried on the next call rather than remembered
///   forever ("negative caching").
/// - The cache key is `sha256("$source\n${width}x$height")`, i.e. it
///   covers the source URL exactly as given plus both dimensions, but
///   deliberately *not* the configured API key. The key's image bytes
///   don't depend on which valid key fetched them, so hashing the key in
///   too would bust every cached thumbnail on a routine key rotation for
///   no benefit; if [source] itself already carries its own `apikey`
///   query value (as some Stash-issued URLs do), that value is part of
///   [source] and so is naturally covered already.
class DiskThumbnailRepository implements ThumbnailRepository {
  DiskThumbnailRepository({
    required this.baseUri,
    required this.apiKey,
    required Directory cacheRoot,
    required ThumbnailFetcher fetch,
    ThumbnailResizer resize = defaultThumbnailResizer,
    int maxConcurrentFetches = thumbnailConcurrencyLimit,
  }) : _cacheRoot = cacheRoot,
       _fetch = fetch,
       _resize = resize,
       _semaphore = _Semaphore(maxConcurrentFetches);

  /// Builds the production repository: a real [http.Client]-backed
  /// fetcher, the real decode/encode pipeline, and the platform's
  /// application cache directory as the cache root, all at the project's
  /// [thumbnailConcurrencyLimit]-permit ceiling.
  static Future<DiskThumbnailRepository> create({
    required Uri baseUri,
    required String apiKey,
    required http.Client client,
  }) async {
    final cacheRoot = await getApplicationCacheDirectory();
    return DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: apiKey,
      cacheRoot: cacheRoot,
      fetch: (uri, headers) => client.get(uri, headers: headers),
    );
  }

  final Uri baseUri;
  final String apiKey;
  final Directory _cacheRoot;
  final ThumbnailFetcher _fetch;
  final ThumbnailResizer _resize;
  final _Semaphore _semaphore;

  @override
  Future<Uint8List?> load(String source, int width, int height) async {
    final file = _cacheFile(source, width, height);

    final cached = await _readCached(file);
    if (cached != null) return cached;

    await _semaphore.acquire();
    try {
      return await _fetchAndCache(file, source, width, height);
    } finally {
      _semaphore.release();
    }
  }

  Future<Uint8List?> _readCached(File file) async {
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (error) {
      _log('read', file.path, error);
      return null;
    }
  }

  Future<Uint8List?> _fetchAndCache(
    File file,
    String source,
    int width,
    int height,
  ) async {
    final uri = authenticatedUrl(baseUri, source, apiKey);
    final headers = <String, String>{if (apiKey.isNotEmpty) 'ApiKey': apiKey};

    final http.Response response;
    try {
      response = await _fetch(uri, headers);
    } catch (error) {
      _log('fetch', uri.toString(), error);
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _log('fetch', uri.toString(), 'HTTP ${response.statusCode}');
      return null;
    }

    final Uint8List resized;
    try {
      resized = await _resize(response.bodyBytes, width, height);
    } catch (error) {
      _log('decode', uri.toString(), error);
      return null;
    }

    await _writeAtomically(file, resized);
    return resized;
  }

  /// Writes [bytes] to a temporary sibling of [file] and renames it into
  /// place. A rename within the same directory is atomic, so a concurrent
  /// reader (or a crash mid-write) never observes a torn PNG at [file]'s
  /// final path — writing directly to that path would not have that
  /// guarantee.
  Future<void> _writeAtomically(File file, Uint8List bytes) async {
    await file.parent.create(recursive: true);
    final tempFile = File('${file.path}.${_nextTempFileSuffix()}.tmp');
    await tempFile.writeAsBytes(bytes, flush: true);
    await tempFile.rename(file.path);
  }

  File _cacheFile(String source, int width, int height) {
    final key = sha256
        .convert(utf8.encode('$source\n${width}x$height'))
        .toString();
    return File(
      p.join(
        _cacheRoot.path,
        thumbnailCacheAppSegment,
        'thumbnails',
        '$key.png',
      ),
    );
  }

  void _log(String stage, String subject, Object error) {
    developer.log(
      redactSensitive(
        'thumbnail $stage failed for $subject: $error',
        apiKey: apiKey,
      ),
      name: 'thumbnail_repository',
    );
  }
}

int _tempFileSequence = 0;

/// A per-process-unique suffix for a temporary cache file: even if two
/// concurrent requests race to fill the *same* cache key (two widgets
/// asking for the same thumbnail at once), each write goes to its own
/// temporary file, so neither can corrupt the other's rename.
String _nextTempFileSuffix() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_tempFileSequence++}';

/// The real thumbnail decode/encode pipeline: decode [bytes] scaled to
/// [width]x[height] via Skia, then re-encode the first (only) frame as
/// PNG.
Future<Uint8List> defaultThumbnailResizer(
  Uint8List bytes,
  int width,
  int height,
) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: width,
    targetHeight: height,
  );
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) {
    throw const FormatException('Failed to encode thumbnail as PNG.');
  }
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// A FIFO permit queue: at most [_maxPermits] callers hold a permit at
/// once, and callers that arrive once the pool is full queue in the order
/// they called [acquire] and are released in that same order.
class _Semaphore {
  _Semaphore(this._availablePermits);

  int _availablePermits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_availablePermits > 0) {
      _availablePermits--;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isEmpty) {
      _availablePermits++;
      return;
    }
    _waiters.removeFirst().complete();
  }
}
