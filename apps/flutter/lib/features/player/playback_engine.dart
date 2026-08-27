import 'package:flutter/widgets.dart';

/// Application-owned boundary between the player UI (Tasks 9-11: the
/// playback controller, activity sync, and scene screen) and whatever
/// media backend actually decodes and renders video.
///
/// [PlaybackEngine] is the only type those layers may depend on for
/// playback. `MediaKitPlaybackEngine` (`lib/services/`) is the sole
/// production implementation, and it — together with its own test file —
/// is the only place in this codebase allowed to import `package:media_kit`
/// or `package:media_kit_video`. Every other test exercising playback
/// behavior should depend on `FakePlaybackEngine`
/// (`test/support/fake_playback_engine.dart`) instead of this real engine.
///
/// [Uri]s passed to [open] may already carry an authenticated `?apikey=`
/// query value (see `Client.authenticatedUrl`/`authenticatedUrl` in
/// `lib/services/authenticated_url.dart`) — the media backend can't carry
/// an `ApiKey` request header, so the key has to travel in the URL
/// instead. Implementations must never let that key reach [errors]
/// unredacted.
abstract interface class PlaybackEngine {
  /// Whether the engine is currently playing.
  Stream<bool> get playing;

  /// Whether the engine is currently buffering.
  Stream<bool> get buffering;

  /// Current playback position of the open media.
  Stream<Duration> get position;

  /// Duration of the currently open media.
  Stream<Duration> get duration;

  /// Credential-safe error messages surfaced by the backend. The [Uri]
  /// opened via [open] can carry an API key in its query string —
  /// implementations must redact it (and any other credential-shaped
  /// text) before an error reaches this stream.
  Stream<String> get errors;

  /// The widget presenting this engine's video output. Callers decide
  /// where in the tree it is mounted; the engine owns everything about
  /// how the surface itself is built and kept in sync with playback.
  Widget buildVideoSurface({Key? key});

  /// Opens [uri] for playback. Starts playing immediately when [play] is
  /// `true`; otherwise the engine stays paused until [play] is called.
  Future<void> open(Uri uri, {bool play = false});

  /// Resumes (or starts) playback of the currently open media.
  Future<void> play();

  /// Pauses playback of the currently open media.
  Future<void> pause();

  /// Seeks to [position] within the currently open media.
  Future<void> seek(Duration position);

  /// Sets playback volume. [zeroToOne] is clamped to `0.0`-`1.0` by the
  /// implementation before being applied.
  Future<void> setVolume(double zeroToOne);

  /// Mutes or unmutes playback without discarding the volume level set
  /// via [setVolume].
  Future<void> setMuted(bool muted);

  /// Releases every resource held by this engine. Safe to call more than
  /// once — a second call must not throw or re-release anything.
  Future<void> dispose();
}
