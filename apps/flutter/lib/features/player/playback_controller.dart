import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Key, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/connection.dart';
import '../../domain/scene.dart';
import '../../services/authenticated_url.dart';
import '../../services/media_kit_playback_engine.dart';
import 'playback_engine.dart';
import 'playback_state.dart';

/// One user-facing player command a keyboard shortcut
/// (`player_shortcuts.dart`, wired up by Task 11's scene screen) can
/// resolve to. [PlaybackController.handleAction] is the single entry
/// point that turns any of these into the right controller call, so the
/// keyboard-shortcut layer never needs to know what a shortcut actually
/// does — only which [PlayerAction] a key maps to.
enum PlayerAction {
  togglePlayPause,
  seekBackward5,
  seekForward5,
  seekBackward10,
  seekForward10,
  seekBackward60,
  seekForward60,
  seekToStart,
  seekToEnd,
  volumeDown,
  volumeUp,
  toggleMute,
  toggleFullscreen,
  exitFullscreen,
}

/// The exact amount every volume keyboard shortcut (Digit9/Digit0)
/// changes [PlaybackState.volume] by.
const double playerVolumeStep = 0.05;

/// Resolves the connection (server URL + API key) [PlaybackController]
/// should authenticate its stream URLs against. A thunk rather than a
/// plain value for the same reason `LibraryController`'s `_DeferredStashApi`
/// is: [playbackControllerProvider] must hand back a controller
/// synchronously, but the underlying connection config
/// (`effectiveConnectionProvider`) resolves asynchronously.
typedef ConnectionResolver = Future<ConnectionConfig> Function();

/// Asks the real OS/window to enter or leave fullscreen, returning
/// whether it actually took effect. [PlaybackController.setFullscreen]
/// only updates [PlaybackState.fullscreen] when this returns `true` — a
/// callback that throws is treated the same as a `false` result.
typedef FullscreenRequester = Future<bool> Function(bool fullscreen);

/// Owns everything about driving a [PlaybackEngine] for one scene at a
/// time: resolving and authenticating its stream URL, the resume-on-open
/// seek, clamped absolute/relative seeking, volume/mute, fullscreen, and
/// turning a [PlayerAction] into the right call.
///
/// [PlaybackEngine] is shared across scene changes — [loadScene] never
/// disposes or replaces it, only this controller's own subscriptions to
/// its streams. Only [dispose] disposes the engine, and exactly once.
///
/// Every engine stream (`playing`/`buffering`/`position`/`duration`/
/// `errors`) is a broadcast controller with no replayed last value, so
/// this controller (re)binds its subscriptions *before* [loadScene]
/// triggers anything that could emit (`open`/`seek`/`play`) — binding
/// after would silently miss whatever the engine emits first.
///
/// [PlaybackState.generation] guards every multi-`await` sequence
/// ([loadScene], [seekAbsolute], and the bound stream callbacks) the
/// same way `LibraryController` guards its own paging requests: the
/// generation in effect when an async operation started is captured up
/// front and re-checked after every `await` (success and failure paths
/// alike) before that operation is allowed to touch the engine or update
/// [state] — so a scene replaced (or this controller disposed) mid-flight
/// can't have its stale result clobber whatever superseded it.
///
/// Activity flushing (the eventual `ActivitySync.flush` Task 10 will
/// build) is a seam, not something this controller implements: the
/// injected [onFlushActivity] defaults to a no-op and is called at
/// exactly two points — before the engine seek in [seekAbsolute], and
/// during [dispose] — never anywhere else.
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required PlaybackEngine engine,
    required ConnectionResolver resolveConnection,
    required FullscreenRequester setFullscreenPlatform,
    Future<void> Function()? onFlushActivity,
  }) : _engine = engine,
       _resolveConnection = resolveConnection,
       _setFullscreenPlatform = setFullscreenPlatform,
       _onFlushActivity = onFlushActivity ?? _defaultFlush;

  static Future<void> _defaultFlush() async {}

  final PlaybackEngine _engine;
  final ConnectionResolver _resolveConnection;
  final FullscreenRequester _setFullscreenPlatform;
  final Future<void> Function() _onFlushActivity;

  PlaybackState _state = const PlaybackState();
  PlaybackState get state => _state;

  /// Set by [dispose]. Checked alongside the generation guard in every
  /// callback and post-`await` continuation so a response or stream
  /// event landing after teardown never calls `notifyListeners()` on a
  /// disposed [ChangeNotifier] (which throws) and never issues another
  /// command to an already-disposed [_engine] (which the real adapter
  /// and `FakePlaybackEngine` both reject).
  bool _disposed = false;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorsSubscription;

  /// The widget presenting the shared engine's video output. Stable
  /// across scene changes since the engine itself never changes.
  Widget buildVideoSurface({Key? key}) => _engine.buildVideoSurface(key: key);

  /// Opens [scene] for playback: synchronously bumps
  /// [PlaybackState.generation] and resets transient state (playing/
  /// buffering/duration/position/failure — but not the sticky volume/
  /// muted/fullscreen prefs), then cancels this controller's
  /// subscriptions to the *previous* scene's stream events, rebinds
  /// streams for the new generation, and resolves the connection,
  /// authenticates [scene]'s stream URL, opens it, seeks the effective
  /// resume position (if any — see `Scene.effectiveResume` for the exact
  /// rule), and starts playback.
  Future<void> loadScene(Scene scene) async {
    if (_disposed) return;
    final generation = _state.generation + 1;

    // Claim this generation synchronously, before any `await` — including
    // the subscription cancellation below. Two `loadScene` calls issued
    // back-to-back (before either reaches its first suspension point)
    // would otherwise both compute the same "next generation" against the
    // same stale `_state.generation`, defeating the whole guard this
    // class relies on to reject stale continuations and stream events.
    _state = PlaybackState(
      scene: scene,
      phase: PlaybackPhase.loading,
      generation: generation,
      volume: _state.volume,
      muted: _state.muted,
      fullscreen: _state.fullscreen,
    );
    notifyListeners();

    await _cancelSubscriptions();
    if (_disposed || generation != _state.generation) return;

    _bindStreams(generation);

    try {
      final config = await _resolveConnection();
      if (_disposed || generation != _state.generation) return;

      final source = scene.paths.stream;
      if (source == null) {
        _state = _state.copyWith(
          phase: PlaybackPhase.failed,
          failure: 'This scene has no playable video file.',
        );
        notifyListeners();
        return;
      }

      final uri = authenticatedUrl(
        Uri.parse(config.serverUrl),
        source,
        config.apiKey,
      );

      await _engine.open(uri, play: false);
      if (_disposed || generation != _state.generation) return;

      final resumeSeconds = scene.effectiveResume;
      if (resumeSeconds != null) {
        final target = _secondsToDuration(resumeSeconds);
        await _engine.seek(target);
        if (_disposed || generation != _state.generation) return;
        _state = _state.copyWith(position: target);
        notifyListeners();
      }

      await _engine.play();
      if (_disposed || generation != _state.generation) return;

      _state = _state.copyWith(phase: PlaybackPhase.ready);
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: PlaybackPhase.failed,
        failure: redactSensitive('$error', apiKey: ''),
      );
      notifyListeners();
    }
  }

  /// Plays if currently paused, pauses if currently playing — based on
  /// this controller's own accepted [PlaybackState.playing], which the
  /// bound `playing` stream keeps in sync with the engine, not a fresh
  /// engine query.
  Future<void> playPause() async {
    if (_disposed) return;
    if (_state.playing) {
      await _engine.pause();
    } else {
      await _engine.play();
    }
  }

  /// Seeks to [target], clamped to `[Duration.zero, duration]` once
  /// [PlaybackState.duration] is known (see that field's doc for the
  /// "unknown" sentinel) — otherwise only floored at zero. Flushes
  /// pending activity via [onFlushActivity] *before* issuing the engine
  /// seek.
  Future<void> seekAbsolute(Duration target) async {
    if (_disposed) return;
    final generation = _state.generation;
    final clamped = _clamp(target);

    await _onFlushActivity();
    if (_disposed || generation != _state.generation) return;

    await _engine.seek(clamped);
    if (_disposed || generation != _state.generation) return;

    _state = _state.copyWith(position: clamped);
    notifyListeners();
  }

  /// Seeks by [delta] relative to this controller's own accepted
  /// [PlaybackState.position] — never a fresh engine query, which can
  /// return a stale value while a seek is outstanding and make
  /// successive relative seeks all land in the same place.
  Future<void> seekRelative(Duration delta) =>
      seekAbsolute(_state.position + delta);

  /// Sets volume, clamped to `[0.0, 1.0]`.
  Future<void> setVolume(double value) async {
    if (_disposed) return;
    final generation = _state.generation;
    final clamped = value.clamp(0.0, 1.0);

    await _engine.setVolume(clamped);
    if (_disposed || generation != _state.generation) return;

    _state = _state.copyWith(volume: clamped);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    if (_disposed) return;
    final generation = _state.generation;
    final next = !_state.muted;

    await _engine.setMuted(next);
    if (_disposed || generation != _state.generation) return;

    _state = _state.copyWith(muted: next);
    notifyListeners();
  }

  /// Requests [value] via the [FullscreenRequester] injected at
  /// construction, only updating [PlaybackState.fullscreen] once that
  /// call actually succeeds — a `false` result or a thrown error leaves
  /// state exactly as it was.
  Future<void> setFullscreen(bool value) async {
    if (_disposed) return;
    final generation = _state.generation;

    bool succeeded;
    try {
      succeeded = await _setFullscreenPlatform(value);
    } catch (_) {
      succeeded = false;
    }
    if (_disposed || generation != _state.generation || !succeeded) return;

    _state = _state.copyWith(fullscreen: value);
    notifyListeners();
  }

  /// Turns [action] into the corresponding controller call — the single
  /// place that knows what each [PlayerAction] means, so the keyboard
  /// shortcut layer doesn't have to.
  Future<void> handleAction(PlayerAction action) {
    switch (action) {
      case PlayerAction.togglePlayPause:
        return playPause();
      case PlayerAction.seekBackward5:
        return seekRelative(const Duration(seconds: -5));
      case PlayerAction.seekForward5:
        return seekRelative(const Duration(seconds: 5));
      case PlayerAction.seekBackward10:
        return seekRelative(const Duration(seconds: -10));
      case PlayerAction.seekForward10:
        return seekRelative(const Duration(seconds: 10));
      case PlayerAction.seekBackward60:
        return seekRelative(const Duration(seconds: -60));
      case PlayerAction.seekForward60:
        return seekRelative(const Duration(seconds: 60));
      case PlayerAction.seekToStart:
        return seekAbsolute(Duration.zero);
      case PlayerAction.seekToEnd:
        return seekAbsolute(_state.duration);
      case PlayerAction.volumeDown:
        return setVolume(_state.volume - playerVolumeStep);
      case PlayerAction.volumeUp:
        return setVolume(_state.volume + playerVolumeStep);
      case PlayerAction.toggleMute:
        return toggleMute();
      case PlayerAction.toggleFullscreen:
        return setFullscreen(!_state.fullscreen);
      case PlayerAction.exitFullscreen:
        return _state.fullscreen ? setFullscreen(false) : Future<void>.value();
    }
  }

  /// Tears this controller down: cancels its stream subscriptions,
  /// flushes pending activity via [onFlushActivity], and disposes the
  /// shared [PlaybackEngine] — exactly once, safe to call more than
  /// once. Overrides [ChangeNotifier.dispose]'s `void` signature with
  /// `Future<void>` (permitted since the base return type is `void`) so
  /// a caller that wants to await full teardown can, while Riverpod's
  /// own synchronous teardown call still kicks the async work off
  /// correctly as a fire-and-forget.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _state = _state.copyWith(phase: PlaybackPhase.disposed);

    await _cancelSubscriptions();
    await _onFlushActivity();
    await _engine.dispose();

    super.dispose();
  }

  void _bindStreams(int generation) {
    _playingSubscription = _engine.playing.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(playing: value);
      notifyListeners();
    });
    _bufferingSubscription = _engine.buffering.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(buffering: value);
      notifyListeners();
    });
    _positionSubscription = _engine.position.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(position: value);
      notifyListeners();
    });
    _durationSubscription = _engine.duration.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(duration: value);
      notifyListeners();
    });
    _errorsSubscription = _engine.errors.listen((message) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(phase: PlaybackPhase.failed, failure: message);
      notifyListeners();
    });
  }

  /// Cancels (and clears) every currently-bound stream subscription
  /// concurrently, so replacing a scene's subscriptions never leaves a
  /// meaningful window where an old subscription is still deliverable
  /// while a new one is already active.
  Future<void> _cancelSubscriptions() async {
    final subscriptions = <StreamSubscription<void>?>[
      _playingSubscription,
      _bufferingSubscription,
      _positionSubscription,
      _durationSubscription,
      _errorsSubscription,
    ];
    _playingSubscription = null;
    _bufferingSubscription = null;
    _positionSubscription = null;
    _durationSubscription = null;
    _errorsSubscription = null;
    await Future.wait([
      for (final subscription in subscriptions)
        if (subscription != null) subscription.cancel(),
    ]);
  }

  Duration _clamp(Duration target) {
    final lower = target < Duration.zero ? Duration.zero : target;
    final knownDuration = _state.duration;
    if (knownDuration > Duration.zero && lower > knownDuration) {
      return knownDuration;
    }
    return lower;
  }

  static Duration _secondsToDuration(double seconds) => Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );
}

/// Builds the [PlaybackEngine] [playbackControllerProvider] uses.
/// Production's default constructs a real [MediaKitPlaybackEngine],
/// which starts native playback libraries — tests override this with a
/// `FakePlaybackEngine` instead, the same way `stashApiFactoryProvider`
/// lets `LibraryController` tests swap in a `FakeStashApi`.
final playbackEngineProvider = Provider<PlaybackEngine>(
  (ref) => MediaKitPlaybackEngine(),
);

/// [PlaybackController] provider. Rebuilt — a fresh controller, which
/// disposes the previous one's engine — whenever
/// [connectionGenerationProvider] changes, the same way
/// `libraryControllerProvider` is: a settings-driven reconnection must
/// not keep streaming from the old server/key.
///
/// The fullscreen requester is a placeholder that always reports success
/// without touching any real window: this codebase has no window-manager
/// integration yet, and wiring one up is out of this task's scope — Task
/// 11 (or later) can override [setFullscreenPlatform] with a real one
/// once the scene screen has a window/context to call it against.
final playbackControllerProvider = ChangeNotifierProvider<PlaybackController>((
  ref,
) {
  ref.watch(connectionGenerationProvider);
  return PlaybackController(
    engine: ref.watch(playbackEngineProvider),
    resolveConnection: () => ref.read(effectiveConnectionProvider.future),
    setFullscreenPlatform: (fullscreen) async => true,
  );
});
