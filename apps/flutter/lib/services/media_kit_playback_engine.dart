import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../features/player/playback_engine.dart';
import 'authenticated_url.dart';

/// The narrow surface [MediaKitPlaybackEngine] needs from a real
/// `package:media_kit` [Player]: exactly the streams and commands the
/// adapter forwards, expressed without any `media_kit` types so a test
/// double can implement it without ever constructing a real [Player] —
/// which, in a headless test environment, tries to initialize native
/// playback libraries. [_RealMediaKitPlayerPort] is the only
/// implementation that touches `package:media_kit` directly; every other
/// implementation (in tests) is a plain in-memory fake.
abstract interface class MediaKitPlayerPort {
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get duration;

  /// Raw, not-yet-redacted error text as reported by the package.
  /// [MediaKitPlaybackEngine] is responsible for redacting this before it
  /// reaches [PlaybackEngine.errors] — this port has no opinion on
  /// credentials.
  Stream<String> get error;

  Future<void> open(Uri uri, {required bool play});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// [volume] is 0-100, matching the package's own scale; mapping from
  /// the interface's 0.0-1.0 scale happens in [MediaKitPlaybackEngine].
  Future<void> setVolume(double volume);

  Future<void> dispose();
}

/// Wraps a real [Player] behind [MediaKitPlayerPort]. This class and
/// [MediaKitPlaybackEngine]'s production factory are the only places in
/// this codebase allowed to construct `package:media_kit` /
/// `package:media_kit_video` objects.
class _RealMediaKitPlayerPort implements MediaKitPlayerPort {
  _RealMediaKitPlayerPort(this._player);

  final Player _player;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<bool> get buffering => _player.stream.buffering;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<String> get error => _player.stream.error;

  @override
  Future<void> open(Uri uri, {required bool play}) =>
      _player.open(Media(uri.toString()), play: play);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() => _player.dispose();
}

/// [PlaybackEngine] backed by `package:media_kit`. Owns one [Player] and
/// one [VideoController] in production; every command and stream passes
/// through a [MediaKitPlayerPort] seam so this adapter itself can be
/// exercised in tests without a real player ever starting.
///
/// Correctness properties this type is responsible for:
///
/// - **Volume.** The interface's `0.0`-`1.0` scale is clamped *before*
///   being multiplied by 100 for the package, so an out-of-range call
///   (`setVolume(1.5)`, `setVolume(-0.2)`) never reaches the package with
///   an out-of-range value.
/// - **Mute.** `package:media_kit` has no runtime mute call — only a
///   [PlayerConfiguration] startup flag — so [setMuted] is implemented in
///   terms of [MediaKitPlayerPort.setVolume]: muting remembers the last
///   volume passed to [setVolume] and forwards zero; unmuting forwards
///   the remembered volume back. A volume change made while muted updates
///   what will be restored without forwarding to the port, so it can't
///   silently un-mute the output.
/// - **Errors.** [MediaKitPlayerPort.error] carries raw package text,
///   which can include the authenticated URI passed to [open] (and so an
///   API key in its `apikey=` query value). Every message is passed
///   through [redactSensitive] before reaching [errors]. This engine
///   never holds the API key itself — the caller is responsible for
///   baking it into the [Uri] given to [open] — so redaction relies
///   entirely on [redactSensitive]'s pattern-based rules (`ApiKey:`
///   header values and `?apikey=`/`&apikey=` query values), not its
///   exact-key match.
/// - **Disposal.** Guarded so a second [dispose] call is a safe no-op: it
///   neither double-cancels its subscriptions, double-closes its own
///   broadcast controllers, nor double-disposes the underlying port.
///   Subscriptions to the port's streams are cancelled *before* this
///   engine's own controllers are closed, so a port stream that fires
///   after [dispose] can never reach an already-closed controller.
class MediaKitPlaybackEngine implements PlaybackEngine {
  /// Builds the production engine: one real [Player] and one
  /// [VideoController] wired to it.
  ///
  /// [httpProxyUrl] is handed to libmpv as its `http-proxy` option. libmpv
  /// fetches media itself, in C, so it shares nothing with the app's
  /// `http.Client` and has to be told separately; `http-proxy` is the only
  /// proxy control it has, which is why the app's own hop is an HTTP proxy
  /// rather than a SOCKS client.
  factory MediaKitPlaybackEngine({String? httpProxyUrl}) {
    final player = Player();
    final platform = player.platform;
    if (httpProxyUrl != null && platform is NativePlayer) {
      // Fire-and-forget: `setProperty` waits for libmpv to finish starting
      // up, which happens well before the first `open()` can be issued.
      unawaited(platform.setProperty('http-proxy', httpProxyUrl));
    }
    final videoController = VideoController(player);
    return MediaKitPlaybackEngine._(
      port: _RealMediaKitPlayerPort(player),
      buildVideoSurface: ({Key? key}) =>
          Video(key: key, controller: videoController, fit: BoxFit.contain),
    );
  }

  /// Test-only entry point: swaps in [port] so no real [Player] or
  /// [VideoController] — and so no native playback library — is ever
  /// constructed. [buildVideoSurface] defaults to an inert placeholder;
  /// this engine's own conformance test never calls
  /// [PlaybackEngine.buildVideoSurface] (real playback is validated
  /// manually, not by headless widget construction), so the default is
  /// never exercised there.
  factory MediaKitPlaybackEngine.testable({
    required MediaKitPlayerPort port,
    Widget Function({Key? key})? buildVideoSurface,
  }) => MediaKitPlaybackEngine._(
    port: port,
    buildVideoSurface:
        buildVideoSurface ?? ({Key? key}) => SizedBox.shrink(key: key),
  );

  MediaKitPlaybackEngine._({
    required MediaKitPlayerPort port,
    required Widget Function({Key? key}) buildVideoSurface,
  }) : _port = port,
       _buildVideoSurface = buildVideoSurface {
    _subscriptions = [
      _port.playing.listen(_playingController.add),
      _port.buffering.listen(_bufferingController.add),
      _port.position.listen(_positionController.add),
      _port.duration.listen(_durationController.add),
      _port.error.listen(
        (message) =>
            _errorsController.add(redactSensitive(message, apiKey: '')),
      ),
    ];
  }

  final MediaKitPlayerPort _port;
  final Widget Function({Key? key}) _buildVideoSurface;

  late final List<StreamSubscription<void>> _subscriptions;

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _errorsController =
      StreamController<String>.broadcast();

  /// The last volume passed to [setVolume], on the interface's `0.0`-`1.0`
  /// scale, restored to the port when [setMuted] unmutes.
  double _volume = 1;
  bool _muted = false;
  bool _disposed = false;

  @override
  Stream<bool> get playing => _playingController.stream;

  @override
  Stream<bool> get buffering => _bufferingController.stream;

  @override
  Stream<Duration> get position => _positionController.stream;

  @override
  Stream<Duration> get duration => _durationController.stream;

  @override
  Stream<String> get errors => _errorsController.stream;

  @override
  Widget buildVideoSurface({Key? key}) => _buildVideoSurface(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false}) =>
      _port.open(uri, play: play);

  @override
  Future<void> play() => _port.play();

  @override
  Future<void> pause() => _port.pause();

  @override
  Future<void> seek(Duration position) => _port.seek(position);

  @override
  Future<void> setVolume(double zeroToOne) {
    _volume = zeroToOne.clamp(0.0, 1.0).toDouble();
    if (_muted) return Future<void>.value();
    return _port.setVolume(_volume * 100);
  }

  @override
  Future<void> setMuted(bool muted) {
    if (_muted == muted) return Future<void>.value();
    _muted = muted;
    return _port.setVolume(muted ? 0 : _volume * 100);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await Future.wait([
      _playingController.close(),
      _bufferingController.close(),
      _positionController.close(),
      _durationController.close(),
      _errorsController.close(),
    ]);
    await _port.dispose();
  }
}
