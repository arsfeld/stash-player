import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Key, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/notices.dart';
import '../../app/providers.dart';
import '../../domain/connection.dart';
import '../../domain/scene.dart';
import '../../services/authenticated_url.dart';
import '../../services/media_kit_playback_engine.dart';
import 'activity_sync.dart';
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

/// Builds the [ActivitySync] a [PlaybackController] uses, given a thunk for
/// the controller's own currently-accepted position (in seconds — the
/// value `ActivitySync.flush` sends as `resumeTime`).
///
/// A factory rather than a ready-built [ActivitySync] for the same
/// "who constructs what, and when" reason [playbackEngineFactoryProvider]
/// is a factory rather than a [PlaybackEngine] instance: [ActivitySync]
/// needs a closure over this controller's own [PlaybackState.position],
/// which only exists once the controller itself is under construction —
/// so the controller builds its [ActivitySync] internally, via this
/// factory, rather than accepting a fully-formed one from a caller that
/// couldn't have supplied that closure yet.
typedef ActivitySyncFactory =
    ActivitySync Function({required double Function() resumePositionSeconds});

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
/// Wall-clock activity accounting is fully delegated to an [ActivitySync]
/// this controller owns (built via the injected [ActivitySyncFactory],
/// defaulting to a real, if inert-by-default, instance — see
/// [_defaultActivitySyncFactory]) and drives at exactly four boundaries:
/// [ActivitySync.playingChanged] and `bufferingChanged` from *accepted*
/// engine stream events (after the usual disposed/generation guard) in
/// [_bindStreams], [ActivitySync.flush] before the engine seek in
/// [seekAbsolute], [ActivitySync.replaceScene] in [loadScene] before the
/// new scene's ID takes over, and [ActivitySync.dispose] awaited in
/// [dispose] before the engine itself is disposed. [ActivitySync] is
/// contractually guaranteed to never throw, so the `try`/`catch` around
/// each of those calls is belt-and-braces, not the only handling — see
/// [ActivitySync]'s own class doc for what actually happens on a sync
/// failure (a warning, never a change to playback).
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required PlaybackEngine engine,
    required ConnectionResolver resolveConnection,
    required FullscreenRequester setFullscreenPlatform,
    ActivitySyncFactory? activitySyncFactory,
  }) : _engine = engine,
       _resolveConnection = resolveConnection,
       _setFullscreenPlatform = setFullscreenPlatform {
    final factory = activitySyncFactory ?? _defaultActivitySyncFactory;
    _activitySync = factory(
      resumePositionSeconds: () => _durationToSeconds(_state.position),
    );
  }

  static ActivitySync _defaultActivitySyncFactory({
    required double Function() resumePositionSeconds,
  }) => ActivitySync(resumePositionSeconds: resumePositionSeconds);

  static double _durationToSeconds(Duration duration) =>
      duration.inMicroseconds / Duration.microsecondsPerSecond;

  final PlaybackEngine _engine;
  final ConnectionResolver _resolveConnection;
  final FullscreenRequester _setFullscreenPlatform;
  late final ActivitySync _activitySync;

  PlaybackState _state = const PlaybackState();
  PlaybackState get state => _state;

  /// Set by [dispose]. Checked alongside the generation guard in every
  /// callback and post-`await` continuation so a response or stream
  /// event landing after teardown never calls `notifyListeners()` on a
  /// disposed [ChangeNotifier] (which throws) and never issues another
  /// command to an already-disposed [_engine] (which the real adapter
  /// and `FakePlaybackEngine` both reject).
  bool _disposed = false;

  /// Whether `_state.position` currently reflects a real, established
  /// position for the *current* scene — `true` once the resume-seek
  /// decision in `loadScene` has run (whether or not a seek actually
  /// happened) or the engine's `position` stream has fired at least once;
  /// `false` from the moment a new scene's state is built until then.
  /// `loadScene` reads this for the *outgoing* scene before resetting it,
  /// so a scene replaced before its own position was ever established
  /// (e.g. superseded by a second `loadScene` before the first's resume
  /// seek could land) reports its outgoing resume position as unknown
  /// rather than a bogus zero (N4) — see `ActivitySync.replaceScene`'s own
  /// doc for what it does with that.
  bool _positionEstablished = false;

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

    // Captured *before* `_state` is replaced below — `replaceScene` needs
    // the *outgoing* scene's last known position, and `_state.position`
    // is about to be reset to zero for the incoming scene. Reading it
    // after that reset (e.g. from inside ActivitySync's own live
    // resume-position callback) would report the new scene's zeroed
    // position as the old scene's resume point, silently wiping its real
    // one on the server on every single scene navigation. `null` when the
    // outgoing scene's position was never established at all (N4) — e.g.
    // this `loadScene` itself superseded one that hadn't yet reached its
    // own resume-seek decision — so that case is reported as unknown
    // rather than as a genuine (and wrong) zero.
    final outgoingPositionSeconds = _positionEstablished
        ? _durationToSeconds(_state.position)
        : null;
    _positionEstablished = false;

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

    // Flush whatever the *previous* scene owes under its own ID (and its
    // own captured position) before this controller starts driving the
    // engine for the new one — see ActivitySync.replaceScene's own doc
    // for why order and the explicit position matter here.
    await _activitySync.replaceScene(
      scene.id,
      outgoingResumeSeconds: outgoingPositionSeconds,
    );
    if (_disposed || generation != _state.generation) return;

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
      // Whether or not a resume seek was needed, `_state.position` now
      // genuinely reflects this scene's starting position (zero is a real
      // answer here, not a placeholder) — see `_positionEstablished`'s doc.
      _positionEstablished = true;

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
    final generation = _state.generation;
    if (_state.playing) {
      await _runEngineCommand(_engine.pause, generation: generation);
    } else {
      await _runEngineCommand(_engine.play, generation: generation);
    }
  }

  /// Seeks to [target], clamped to `[Duration.zero, duration]` once
  /// [PlaybackState.duration] is known (see that field's doc for the
  /// "unknown" sentinel) — otherwise only floored at zero. Flushes
  /// pending activity via [ActivitySync.flush] *before* issuing the engine
  /// seek.
  Future<void> seekAbsolute(Duration target) async {
    if (_disposed) return;
    final generation = _state.generation;
    final clamped = _clamp(target);

    try {
      await _activitySync.flush();
    } catch (_) {
      // ActivitySync.flush is contractually guaranteed not to throw (a
      // sync failure only ever produces a warning — see its class doc),
      // but this stays as belt-and-braces: a flush must never block the
      // user's actual seek (I5) even if that guarantee were ever broken.
      // The seek below still runs regardless of whether the flush
      // succeeded.
    }
    if (_disposed || generation != _state.generation) return;

    final succeeded = await _runEngineCommand(
      () => _engine.seek(clamped),
      generation: generation,
    );
    if (!succeeded || _disposed || generation != _state.generation) return;

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

    final succeeded = await _runEngineCommand(
      () => _engine.setVolume(clamped),
      generation: generation,
    );
    if (!succeeded || _disposed || generation != _state.generation) return;

    _state = _state.copyWith(volume: clamped);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    if (_disposed) return;
    final generation = _state.generation;
    final next = !_state.muted;

    final succeeded = await _runEngineCommand(
      () => _engine.setMuted(next),
      generation: generation,
    );
    if (!succeeded || _disposed || generation != _state.generation) return;

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

  /// Tears this controller down: cancels its stream subscriptions, awaits
  /// [ActivitySync.dispose] (its own last checkpoint flush plus cancelling
  /// its periodic timer), and disposes the shared [PlaybackEngine] —
  /// exactly once, safe to call more than once. Overrides
  /// [ChangeNotifier.dispose]'s `void` signature with `Future<void>`
  /// (permitted since the base return type is `void`) so a caller that
  /// wants to await full teardown can, while Riverpod's own synchronous
  /// teardown call still kicks the async work off correctly as a
  /// fire-and-forget.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _state = _state.copyWith(phase: PlaybackPhase.disposed);

    await _cancelSubscriptions();
    try {
      // Pause *before* the activity flush below, which can legitimately
      // take up to ActivitySync's own disposeFlushTimeout against a hung
      // checkpoint endpoint (N3): without this, the engine would keep
      // rendering audio/video for that entire window even though the user
      // has already navigated away — exactly the "keeps playing in the
      // background" failure the comment below already guards against for
      // the *undisposed* case, just arriving via a slow flush instead of a
      // throwing one. `_activitySync.dispose()`'s own final checkpoint
      // reads `_resumePositionSeconds` (this controller's own `_state`),
      // never the engine, so pausing first can't affect what it reports.
      await _engine.pause();
    } catch (_) {
      // Best-effort: a thrown pause must never block the activity flush
      // or the engine dispose below from still running.
    }
    try {
      // `_positionEstablished` covers this flush boundary the same way it
      // already covers `replaceScene` (N4): if the user navigated away
      // before this scene's own resume seek (or any position event) ever
      // landed, `_state.position` is still just the zeroed placeholder
      // from `loadScene`'s initial state build, not a real position — so
      // ActivitySync must not fall back to reporting it as one.
      await _activitySync.dispose(resumePositionKnown: _positionEstablished);
    } catch (_) {
      // ActivitySync.dispose is contractually guaranteed not to throw,
      // but this stays as belt-and-braces (I5): a sync failure must never
      // strand the engine undisposed. The GTK client's own playbin3
      // pipeline has exactly this documented failure mode (audio kept
      // playing in the background after teardown) when disposal is
      // skipped, so the engine dispose below always runs regardless of
      // whether the flush succeeded.
    }
    await _engine.dispose();

    super.dispose();
  }

  void _bindStreams(int generation) {
    _playingSubscription = _engine.playing.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(playing: value);
      notifyListeners();
      // "Accepted" per this method's own doc: only events that passed the
      // guard above reach ActivitySync, so a superseded generation's
      // playing events can never be recorded as this scene's activity.
      _activitySync.playingChanged(value);
    });
    _bufferingSubscription = _engine.buffering.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(buffering: value);
      notifyListeners();
      _activitySync.bufferingChanged(value);
    });
    _positionSubscription = _engine.position.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(position: value);
      _positionEstablished = true;
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

  /// Runs [call] (one of the engine's own command methods) and reports
  /// whether it completed without throwing.
  ///
  /// Every command method above (`playPause`, `seekAbsolute`, `setVolume`,
  /// `toggleMute`) runs unawaited from keyboard-shortcut dispatch, where
  /// `onKeyEvent` must return synchronously — nothing else is ever in a
  /// position to catch a thrown engine error (I6). Once a real engine's
  /// player has errored, `play`/`pause`/`seek`/`setVolume`/`setMuted` can
  /// all throw, so an uncaught error here would otherwise surface as an
  /// unhandled `Future` error (`FlutterError.onError`: a red screen in
  /// debug, a logged crash in release) for something as ordinary as
  /// pressing a key after playback has already failed.
  ///
  /// On failure this records the redacted error into
  /// [PlaybackState.controlFailure]/[PlaybackState.controlFailureSequence]
  /// — deliberately *not* [PlaybackState.phase]/[PlaybackState.failure],
  /// unlike [loadScene]'s own `catch`. An earlier version of this method
  /// routed every failure here into the same terminal
  /// [PlaybackPhase.failed] a genuinely-unplayable scene reaches, and
  /// nothing ever moved `phase` back afterward: a single failed
  /// `setVolume` — cosmetic, the video kept playing fine — permanently
  /// stranded the scene in `failed`, indistinguishable from "this video
  /// can never play," and silently absorbed every later control failure
  /// too (a phase that's already `failed` can't become "newly" failed
  /// again, so a UI diffing `phase` transitions sees nothing on the
  /// second, third, ... failure). Control-command failures are a
  /// different kind of event from "this scene stopped loading/playing
  /// entirely" and get their own channel so they can never affect
  /// [PlaybackState.phase], can never get "stuck", and are individually
  /// observable (via [PlaybackState.controlFailureSequence], not string
  /// equality on the message) no matter how many happen in a row.
  Future<bool> _runEngineCommand(
    Future<void> Function() call, {
    required int generation,
  }) async {
    try {
      await call();
      return true;
    } catch (error) {
      if (_disposed || generation != _state.generation) return false;
      _state = _state.copyWith(
        controlFailure: redactSensitive('$error', apiKey: ''),
        controlFailureSequence: _state.controlFailureSequence + 1,
      );
      notifyListeners();
      return false;
    }
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

/// Constructs one concrete [PlaybackEngine] instance. Production's
/// default is a real [MediaKitPlaybackEngine], which starts native
/// playback libraries — tests override *this* provider (not
/// [playbackEngineProvider] itself; see that provider's doc for why)
/// with a factory that hands back a `FakePlaybackEngine` instead, the
/// same way `stashApiFactoryProvider` lets `LibraryController` tests
/// swap in a `FakeStashApi`.
final playbackEngineFactoryProvider = Provider<PlaybackEngine Function()>(
  (ref) => MediaKitPlaybackEngine.new,
);

/// Builds the [PlaybackEngine] [playbackControllerProvider] uses, via
/// [playbackEngineFactoryProvider].
///
/// Watches [connectionGenerationProvider] so a settings-driven
/// reconnection rebuilds this to a *fresh* engine, not the one the old
/// (now-disposed) [PlaybackController] already tore down. Without this,
/// [playbackControllerProvider] would keep handing the same cached
/// engine instance to every new controller: the old controller's
/// `dispose()` disposes it on generation bump regardless, so the next
/// `loadScene` would call `open()` on an already-disposed engine, throw,
/// land in `PlaybackPhase.failed` — and stay there forever, since every
/// one of the disposed engine's streams is already closed and so never
/// emits again. Dead playback until the app restarts.
///
/// Deliberately split from [playbackEngineFactoryProvider] rather than
/// constructing the engine directly: a test that needs a
/// `FakePlaybackEngine` (which it always does — never a real
/// [MediaKitPlaybackEngine]) can override the factory alone and leave
/// this provider's own body — the `ref.watch(connectionGenerationProvider)`
/// call above — genuinely exercised, rather than replacing it with a
/// test-authored reimplementation of what the fix is supposed to do.
final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  ref.watch(connectionGenerationProvider);
  final factory = ref.watch(playbackEngineFactoryProvider);
  return factory();
});

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
///
/// The [ActivitySyncFactory] wires a real [ActivitySync] to
/// [stashApiProvider] for `saveSceneActivity` and to [globalNoticeProvider]
/// for its non-modal warning — the same channel `library_screen.dart`
/// already uses for "safe but not what the user asked for" notices, which
/// is exactly what a sync failure is (see [ActivitySync]'s own doc: it
/// never touches playback, only reports that it couldn't save).
///
/// Both `stashApiProvider.future` and `globalNoticeProvider.notifier` are
/// captured **once**, synchronously, right here — not re-resolved via
/// `ref` lazily inside the `saveActivity`/`onWarning` closures. A
/// `connectionGenerationProvider` bump rebuilds this provider (a fresh
/// controller, a fresh `ActivitySync`) while the *old* controller's
/// `dispose()` — and so its `ActivitySync`'s own final flush — keeps
/// running as unawaited teardown from Riverpod's perspective. If that
/// flush resolved `ref.read(stashApiProvider.future)` lazily at call
/// time, it would by then observe the *new* generation's `StashApi`
/// (same `ref`, already rebuilt) and POST the outgoing scene's last
/// checkpoint to the new server with the new API key — silently
/// corrupting whatever scene happens to share that ID there, or hitting a
/// disposed `ProviderContainer` and burning a full retry cycle on a call
/// that can never succeed. Capturing the `Future`/notifier once pins them
/// to *this* generation for the lifetime of *this* controller, exactly
/// the way a fresh `PlaybackController`/`ActivitySync` pair is already
/// built per generation.
final playbackControllerProvider = ChangeNotifierProvider<PlaybackController>((
  ref,
) {
  ref.watch(connectionGenerationProvider);
  final stashApiFuture = ref.read(stashApiProvider.future);
  final noticeController = ref.read(globalNoticeProvider.notifier);
  return PlaybackController(
    engine: ref.watch(playbackEngineProvider),
    resolveConnection: () => ref.read(effectiveConnectionProvider.future),
    setFullscreenPlatform: (fullscreen) async => true,
    activitySyncFactory: ({required resumePositionSeconds}) => ActivitySync(
      resumePositionSeconds: resumePositionSeconds,
      saveActivity:
          ({required id, required resumeTime, required playDuration}) async {
            final api = await stashApiFuture;
            await api.saveSceneActivity(
              id: id,
              resumeTime: resumeTime,
              playDuration: playDuration,
            );
          },
      onWarning: (message) => noticeController.show(
        AppNotice(message: message, severity: AppNoticeSeverity.warning),
      ),
    ),
  );
});
