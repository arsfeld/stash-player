import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:stash_player_flutter/services/authenticated_url.dart';
import 'package:stash_player_flutter/services/disk_thumbnail_repository.dart';
import 'package:stash_player_flutter/services/thumbnail_repository.dart';

/// One recorded fetch, with its own [completer] so a test can decide
/// exactly when — and in what order — each in-flight request resolves.
/// This is what makes the concurrency tests meaningful: they measure the
/// number of fetches genuinely in flight at once, not just the total
/// number issued.
class RecordedFetch {
  RecordedFetch({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, String> headers;
  final Completer<http.Response> completer = Completer<http.Response>();
}

class FakeFetcher {
  final List<RecordedFetch> calls = [];

  int _inFlight = 0;
  int maxInFlight = 0;

  Future<http.Response> call(Uri uri, Map<String, String> headers) async {
    final recorded = RecordedFetch(uri: uri, headers: headers);
    calls.add(recorded);
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      return await recorded.completer.future;
    } finally {
      _inFlight--;
    }
  }
}

Future<Uint8List> _identityResize(
  Uint8List bytes,
  int width,
  int height,
) async => bytes;

/// Polls until [fetcher] has recorded at least [count] calls. The
/// repository does a real (async) disk `exists()` check before it ever
/// reaches the fetcher, so a single microtask flush isn't reliably enough
/// to observe a call landing — this polls with small real delays instead
/// of assuming a fixed number of event-loop turns.
Future<void> waitForCalls(FakeFetcher fetcher, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (fetcher.calls.length < count) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out waiting for $count fetch call(s); only saw '
        '${fetcher.calls.length}.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

File cacheFilePath(Directory cacheRoot, String source, int width, int height) {
  final key = sha256
      .convert(utf8.encode('$source\n${width}x$height'))
      .toString();
  return File(
    p.join(
      cacheRoot.path,
      'dev.arsfeld.stashplayer.flutter',
      'thumbnails',
      '$key.png',
    ),
  );
}

/// A genuine, CRC-valid 1x1 PNG (grayscale + alpha), used by the one test
/// that exercises the real `ui.instantiateImageCodec`-based resizer
/// rather than an injected fake.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final baseUri = Uri.parse('https://stash.example');
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('thumbnail_repo_test_');
  });

  tearDown(() async {
    if (await cacheRoot.exists()) {
      await cacheRoot.delete(recursive: true);
    }
  });

  test(
    'caches to disk and skips HTTP on a second call for the same key',
    () async {
      final fetcher = FakeFetcher();
      final repo = DiskThumbnailRepository(
        baseUri: baseUri,
        apiKey: 'SECRET',
        cacheRoot: cacheRoot,
        fetch: fetcher.call,
        resize: _identityResize,
      );

      final first = repo.load('/scene/1/screenshot', 240, 135);
      await waitForCalls(fetcher, 1);
      fetcher.calls[0].completer.complete(
        http.Response.bytes(utf8.encode('bytes-a'), 200),
      );
      expect(await first, utf8.encode('bytes-a'));
      expect(fetcher.calls, hasLength(1));

      final second = await repo.load('/scene/1/screenshot', 240, 135);

      expect(second, utf8.encode('bytes-a'));
      expect(
        fetcher.calls,
        hasLength(1),
        reason: 'second call must not hit HTTP',
      );
    },
  );

  test('a different width or height produces a different cache file under the '
      'expected path prefix', () async {
    final fetcher = FakeFetcher();
    final repo = DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: '',
      cacheRoot: cacheRoot,
      fetch: fetcher.call,
      resize: _identityResize,
    );

    final loadA = repo.load('/scene/1/screenshot', 240, 135);
    await waitForCalls(fetcher, 1);
    fetcher.calls[0].completer.complete(
      http.Response.bytes(utf8.encode('a'), 200),
    );
    await loadA;

    final loadB = repo.load('/scene/1/screenshot', 480, 270);
    await waitForCalls(fetcher, 2);
    fetcher.calls[1].completer.complete(
      http.Response.bytes(utf8.encode('b'), 200),
    );
    await loadB;

    expect(fetcher.calls, hasLength(2));

    final fileA = cacheFilePath(cacheRoot, '/scene/1/screenshot', 240, 135);
    final fileB = cacheFilePath(cacheRoot, '/scene/1/screenshot', 480, 270);

    expect(fileA.existsSync(), isTrue);
    expect(fileB.existsSync(), isTrue);
    expect(fileA.path, isNot(equals(fileB.path)));

    final expectedPrefix = p.join(
      cacheRoot.path,
      'dev.arsfeld.stashplayer.flutter',
      'thumbnails',
    );
    expect(fileA.path, startsWith(expectedPrefix));
    expect(fileB.path, startsWith(expectedPrefix));
  });

  test(
    'fetch receives the authenticated URL and ApiKey header when configured',
    () async {
      final fetcher = FakeFetcher();
      final repo = DiskThumbnailRepository(
        baseUri: baseUri,
        apiKey: 'SECRET',
        cacheRoot: cacheRoot,
        fetch: fetcher.call,
        resize: _identityResize,
      );

      final future = repo.load('/scene/1/screenshot', 240, 135);
      await waitForCalls(fetcher, 1);
      final recorded = fetcher.calls.single;
      recorded.completer.complete(
        http.Response.bytes(utf8.encode('bytes'), 200),
      );
      await future;

      expect(
        recorded.uri,
        authenticatedUrl(baseUri, '/scene/1/screenshot', 'SECRET'),
      );
      expect(recorded.headers['ApiKey'], 'SECRET');
    },
  );

  test(
    'does not duplicate an apikey already present on the source URL',
    () async {
      final fetcher = FakeFetcher();
      final repo = DiskThumbnailRepository(
        baseUri: baseUri,
        apiKey: 'SECRET',
        cacheRoot: cacheRoot,
        fetch: fetcher.call,
        resize: _identityResize,
      );

      const source = '/scene/1/screenshot?apikey=EXISTING';
      final future = repo.load(source, 240, 135);
      await waitForCalls(fetcher, 1);
      final recorded = fetcher.calls.single;
      recorded.completer.complete(
        http.Response.bytes(utf8.encode('bytes'), 200),
      );
      await future;

      expect(recorded.uri.queryParametersAll['apikey'], hasLength(1));
      expect(recorded.uri.queryParameters['apikey'], 'EXISTING');
    },
  );

  test('13 blocked requests never exceed 12 simultaneous fetches, and the '
      '13th proceeds once a permit is released', () async {
    final fetcher = FakeFetcher();
    final repo = DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: '',
      cacheRoot: cacheRoot,
      fetch: fetcher.call,
      resize: _identityResize,
    );

    final requestCount = thumbnailConcurrencyLimit + 1;
    final futures = <Future<Uint8List?>>[
      for (var i = 0; i < requestCount; i++)
        repo.load('/scene/$i/screenshot', 240, 135),
    ];

    await waitForCalls(fetcher, thumbnailConcurrencyLimit);
    // Give a buggy unbounded implementation a chance to start the extra
    // request too, so this genuinely proves the cap rather than just an
    // eventual count.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fetcher.calls, hasLength(thumbnailConcurrencyLimit));
    expect(fetcher.maxInFlight, thumbnailConcurrencyLimit);

    fetcher.calls[0].completer.complete(
      http.Response.bytes(utf8.encode('0'), 200),
    );
    await waitForCalls(fetcher, requestCount);
    expect(fetcher.calls, hasLength(requestCount));

    for (var i = 1; i < fetcher.calls.length; i++) {
      fetcher.calls[i].completer.complete(
        http.Response.bytes(utf8.encode('$i'), 200),
      );
    }

    final results = await Future.wait(futures);
    expect(results, everyElement(isNotNull));
  });

  test('a failed HTTP response returns null and is not cached', () async {
    final fetcher = FakeFetcher();
    final repo = DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: '',
      cacheRoot: cacheRoot,
      fetch: fetcher.call,
      resize: _identityResize,
    );

    final first = repo.load('/scene/1/screenshot', 240, 135);
    await waitForCalls(fetcher, 1);
    fetcher.calls[0].completer.complete(http.Response.bytes(const [], 500));
    expect(await first, isNull);
    expect(
      cacheFilePath(cacheRoot, '/scene/1/screenshot', 240, 135).existsSync(),
      isFalse,
    );

    // A failure must not be negatively cached: the next request for the
    // same key genuinely retries over HTTP instead of remembering the
    // earlier failure forever.
    final second = repo.load('/scene/1/screenshot', 240, 135);
    await waitForCalls(fetcher, 2);
    fetcher.calls[1].completer.complete(
      http.Response.bytes(utf8.encode('ok'), 200),
    );
    expect(await second, isNotNull);
    expect(fetcher.calls, hasLength(2));
  });

  test('a decode failure returns null and is not cached', () async {
    final fetcher = FakeFetcher();
    final repo = DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: '',
      cacheRoot: cacheRoot,
      fetch: fetcher.call,
      resize: (bytes, width, height) async =>
          throw const FormatException('bad image'),
    );

    final future = repo.load('/scene/1/screenshot', 240, 135);
    await waitForCalls(fetcher, 1);
    fetcher.calls[0].completer.complete(
      http.Response.bytes(utf8.encode('not-an-image'), 200),
    );

    expect(await future, isNull);
    expect(
      cacheFilePath(cacheRoot, '/scene/1/screenshot', 240, 135).existsSync(),
      isFalse,
    );
  });

  test('a filesystem failure while caching returns null, leaves no orphaned '
      'temp file, and a later call still succeeds', () async {
    // Force the cache write to fail without touching permissions: a
    // plain *file* sitting where the cache's app-segment directory
    // needs to be created makes `Directory(...).create(recursive:
    // true)` throw (`FileSystemException`, "Not a directory") instead
    // of silently succeeding — a reliable, portable stand-in for a
    // full or read-only filesystem.
    final blockedSegment = File(
      p.join(cacheRoot.path, 'dev.arsfeld.stashplayer.flutter'),
    );
    await blockedSegment.create(recursive: true);

    final fetcher = FakeFetcher();
    final repo = DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: '',
      cacheRoot: cacheRoot,
      fetch: fetcher.call,
      resize: _identityResize,
    );

    final first = repo.load('/scene/1/screenshot', 240, 135);
    await waitForCalls(fetcher, 1);
    fetcher.calls[0].completer.complete(
      http.Response.bytes(utf8.encode('bytes'), 200),
    );

    expect(await first, isNull);

    // No orphaned `.tmp` sibling anywhere under the cache root — the
    // failed write must clean up after itself.
    final leftovers = await cacheRoot
        .list(recursive: true)
        .where((entity) => entity.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);

    // Unblock the filesystem and prove both the cache path and the
    // fetch permit pool recovered: a fresh batch reaches full
    // concurrency and every one of them successfully caches to disk.
    await blockedSegment.delete();

    final futures = <Future<Uint8List?>>[
      for (var i = 0; i < thumbnailConcurrencyLimit; i++)
        repo.load('/scene/ok-$i/screenshot', 240, 135),
    ];
    await waitForCalls(fetcher, thumbnailConcurrencyLimit + 1);
    expect(fetcher.maxInFlight, thumbnailConcurrencyLimit);

    for (var i = 1; i < fetcher.calls.length; i++) {
      fetcher.calls[i].completer.complete(
        http.Response.bytes(utf8.encode('$i'), 200),
      );
    }
    final results = await Future.wait(futures);
    expect(results, everyElement(isNotNull));
    for (var i = 0; i < thumbnailConcurrencyLimit; i++) {
      expect(
        cacheFilePath(
          cacheRoot,
          '/scene/ok-$i/screenshot',
          240,
          135,
        ).existsSync(),
        isTrue,
      );
    }
  });

  test('a failed fetch releases its permit so the pool recovers to full '
      'concurrency afterward', () async {
    final fetcher = FakeFetcher();
    final repo = DiskThumbnailRepository(
      baseUri: baseUri,
      apiKey: '',
      cacheRoot: cacheRoot,
      fetch: fetcher.call,
      resize: _identityResize,
    );

    final failed = repo.load('/scene/fail/screenshot', 240, 135);
    await waitForCalls(fetcher, 1);
    fetcher.calls[0].completer.complete(http.Response.bytes(const [], 500));
    expect(await failed, isNull);

    // A leaked permit would permanently shrink the pool by one and this
    // would time out instead of reaching full concurrency again.
    final futures = <Future<Uint8List?>>[
      for (var i = 0; i < thumbnailConcurrencyLimit; i++)
        repo.load('/scene/ok-$i/screenshot', 240, 135),
    ];
    await waitForCalls(fetcher, thumbnailConcurrencyLimit + 1);
    expect(fetcher.maxInFlight, thumbnailConcurrencyLimit);

    for (var i = 1; i < fetcher.calls.length; i++) {
      fetcher.calls[i].completer.complete(
        http.Response.bytes(utf8.encode('$i'), 200),
      );
    }
    final results = await Future.wait(futures);
    expect(results, everyElement(isNotNull));
  });

  test(
    'the default resizer decodes and re-encodes a real image end to end',
    () async {
      final fetcher = FakeFetcher();
      final repo = DiskThumbnailRepository(
        baseUri: baseUri,
        apiKey: '',
        cacheRoot: cacheRoot,
        fetch: fetcher.call,
        // No `resize` override — exercises the real
        // `ui.instantiateImageCodec`-backed default.
      );

      final future = repo.load('/scene/1/screenshot', 1, 1);
      await waitForCalls(fetcher, 1);
      fetcher.calls[0].completer.complete(
        http.Response.bytes(_onePixelPng, 200),
      );

      final result = await future;
      expect(result, isNotNull);
      expect(result, isNotEmpty);

      final file = cacheFilePath(cacheRoot, '/scene/1/screenshot', 1, 1);
      expect(file.existsSync(), isTrue);
      expect(await file.readAsBytes(), result);
    },
  );

  test('the default resizer disposes its codec and frame image without '
      'disrupting repeated calls', () async {
    // `defaultThumbnailResizer` disposes the `ui.Codec` and `ui.Image`
    // it creates in `finally` blocks around every exit path. There's no
    // direct way to assert native memory was freed from a unit test,
    // but disposing the image *before* extracting its PNG bytes (a
    // plausible ordering mistake) would corrupt or throw on the very
    // first call, and disposing the wrong object would throw on a
    // later call — so calling it repeatedly is a meaningful regression
    // guard for a bad disposal order, even though it can't prove the
    // memory was actually released.
    for (var i = 0; i < 5; i++) {
      final bytes = await defaultThumbnailResizer(_onePixelPng, 1, 1);
      expect(bytes, isNotEmpty);
    }
  });
}
