import 'dart:typed_data';

/// Fetches, resizes, and caches scene thumbnails.
///
/// Implementations must never throw: any missing source, HTTP failure, or
/// decode failure resolves to `null` so callers can fall back to a stable
/// placeholder (see `ScenePlaceholder` in `lib/shared/`) instead of an
/// exception reaching the widget tree.
abstract interface class ThumbnailRepository {
  /// Returns PNG-encoded bytes for the thumbnail at [source] resized to
  /// [width]x[height], or `null` if it could not be fetched or decoded.
  ///
  /// [source] is whatever a scene's `paths.screenshot` supplies — a path
  /// relative to the connection's server, or an already-absolute URL,
  /// with or without its own `apikey` query value.
  Future<Uint8List?> load(String source, int width, int height);
}

/// Hard cap on simultaneous thumbnail fetches (a milestone-wide global
/// constraint, not a tuning knob). Keeps a large library grid from
/// opening dozens of concurrent HTTP requests against the Stash server.
const int thumbnailConcurrencyLimit = 12;
