import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Key, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/notices.dart';
import '../../app/providers.dart';
import '../../domain/connection.dart';
import '../../domain/scene.dart';
import '../../domain/scene_stream.dart';
import '../../services/authenticated_url.dart';
import '../../services/media_kit_playback_engine.dart';
import '../../shared/diagnostics.dart';
import 'activity_sync.dart';
import 'load_diagnostics.dart';
import 'playback_engine.dart';
import 'playback_state.dart';
import 'stream_selection.dart';

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

/// How long a stall has to run, with nothing arriving, before the player
/// gives up on the direct stream and retries on Stash's transcode.
///
/// Long enough that an ordinary network hiccup rides it out on the
/// original file, which is always the better picture. Short enough that
/// the pathological case (measured at 63 seconds of stall, and 70 MB of
/// header reads libmpv discards) is cut off long before a viewer would
/// give up on it.
const Duration defaultStallFallbackDelay = Duration(seconds: 8);

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

/// Where [PlaybackController]'s load diagnostics go. Production writes to
/// the console via [logDiagnostic]; tests collect the lines and assert on
/// them, which is the only way the wording of a report anyone actually
/// reads gets pinned by a test.
typedef PlaybackLogger = void Function(String message);

/// Creates the timer [PlaybackController] uses to wait out a stall before
/// giving up on the direct stream. A factory rather than a bare duration
/// so a test can fire the deadline deliberately instead of waiting eight
/// real seconds, and so no real timer is ever left pending.
typedef StallTimerFactory = Timer Function(Duration, void Function());

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
    PlaybackLogger? log,
    DateTime Function()? clock,
    StallTimerFactory? stallTimerFactory,
    Duration stallFallbackDelay = defaultStallFallbackDelay,
  }) : _engine = engine,
       _resolveConnection = resolveConnection,
       _setFullscreenPlatform = setFullscreenPlatform,
       _log = log ?? _defaultLog,
       _clock = clock ?? DateTime.now,
       _createStallTimer = stallTimerFactory ?? Timer.new,
       _stallFallbackDelay = stallFallbackDelay {
    final factory = activitySyncFactory ?? _defaultActivitySyncFactory;
    _activitySync = factory(
      resumePositionSeconds: () => _durationToSeconds(_state.position),
    );
  }

  static ActivitySync _defaultActivitySyncFactory({
    required double Function() resumePositionSeconds,
  }) => ActivitySync(resumePositionSeconds: resumePositionSeconds);

  static void _defaultLog(String message) => logDiagnostic('playback', message);

  static double _durationToSeconds(Duration duration) =>
      duration.inMicroseconds / Duration.microsecondsPerSecond;

  final PlaybackEngine _engine;
  final ConnectionResolver _resolveConnection;
  final FullscreenRequester _setFullscreenPlatform;
  final PlaybackLogger _log;
  final DateTime Function() _clock;
  final StallTimerFactory _createStallTimer;
  final Duration _stallFallbackDelay;
  late final ActivitySync _activitySync;

  /// How far into the scene the currently open stream begins.
  ///
  /// Zero on any kind with a real timeline, which mpv opens at an offset
  /// within and reports absolute positions for. Non-zero only on a
  /// progressive transcode, whose own clock always restarts at zero
  /// because the offset is baked into the URL, so every position the
  /// engine reports has to have this added back before anyone sees it.
  Duration _streamStartOffset = Duration.zero;

  /// Armed while a stall is running, cancelled the moment it ends, by a
  /// new scene, or by teardown. A real pending timer outliving the
  /// controller is exactly the leak `ActivitySync` already documents
  /// having had to fix, and Flutter's own test binding fails a test that
  /// leaves one behind.
  Timer? _stallTimer;

  /// Times the load currently in flight (or the most recent one, for the
  /// milestones that land after every stage has closed). Replaced by each
  /// [loadScene], so a scene's milestones are always reported against its
  /// own load rather than a previous scene's.
  LoadTimeline? _timeline;

  /// The most recently resolved connection, kept for two reasons that
  /// used to need two fields. [_openStream] authenticates each endpoint
  /// against it, and [_runEngineCommand]'s catch (which has no connection
  /// in scope of its own) needs the key to redact a real one out of an
  /// error message. Set the moment [loadScene] resolves a connection,
  /// regardless of whether the rest of that call succeeds, and never
  /// re-read lazily: this controller is rebuilt fresh on every
  /// connection generation change, so this only ever holds this
  /// generation's config.
  ConnectionConfig? _connection;

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

  /// Whether the current rung has already had one automatic decision
  /// made against it, by either [_onStallDeadline] or
  /// [_handleStreamError]: an advance to the next rung, or (once the
  /// ladder is spent) a reopen of this one. See [_handleStreamError]'s
  /// own doc for why a further report against the same rung must not get
  /// to make a second one. Reset to `false` by [_bindStreams] on every
  /// scene load and by [_switchTo] on every genuine advance (never on a
  /// same-rung reopen, since that rung already had its one trial).
  bool _rungTrialUsed = false;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Duration>? _bufferedSubscription;
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
    _streamStartOffset = Duration.zero;
    _cancelStallWatch();

    // Claim this generation synchronously, before any `await` — including
    // the subscription cancellation below. Two `loadScene` calls issued
    // back-to-back (before either reaches its first suspension point)
    // would otherwise both compute the same "next generation" against the
    // same stale `_state.generation`, defeating the whole guard this
    // class relies on to reject stale continuations and stream events.
    _state = PlaybackState(
      scene: scene,
      phase: PlaybackPhase.loading,
      loadStage: LoadStage.connecting,
      // Known before any video is fetched, so the transport shows the
      // real length immediately rather than growing into it.
      duration: scene.knownDuration ?? Duration.zero,
      generation: generation,
      volume: _state.volume,
      muted: _state.muted,
      fullscreen: _state.fullscreen,
    );
    notifyListeners();

    // A fresh timeline per load, started here rather than at the first
    // `await` below, so the connection resolve (which on a cold launch
    // includes reading the API key out of the platform keystore) is
    // inside the measurement rather than before it.
    final timeline = LoadTimeline(
      sceneId: scene.id,
      clock: _clock,
      media: describeMedia(scene),
    )..enter(LoadStage.connecting);
    _timeline = timeline;

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

    // Hoisted above the `try` (rather than a `final` inside it) so the
    // `catch` below can still redact a real key out of an error thrown
    // *after* the connection resolved — e.g. `_engine.open`/`seek`/`play`
    // — instead of falling out of scope and forcing an empty one into
    // `redactSensitive` (final review I6).
    ConnectionConfig? config;
    try {
      config = await _resolveConnection();
      _connection = config;
      if (_disposed || generation != _state.generation) return;

      final source = scene.paths.stream;
      if (source == null) {
        _finishLoad(timeline);
        _state = _state.copyWith(
          phase: PlaybackPhase.failed,
          failure: 'This scene has no playable video file.',
          clearLoadStage: true,
        );
        notifyListeners();
        return;
      }

      final resumeSeconds = scene.effectiveResume;
      final resumeTarget = resumeSeconds == null
          ? null
          : _secondsToDuration(resumeSeconds);

      final selection = StreamSelection.forScene(
        scene,
        directFallback: Uri.parse(config.serverUrl).resolve(source),
      );
      _state = _state.copyWith(streams: selection);

      _enterStage(timeline, LoadStage.opening, generation);
      // The resume position is handed to `open` rather than seeked to
      // once it returns. A seek issued after the fact reaches a backend
      // that may not have the file yet, and the real one rejected it
      // outright while this controller recorded a successful two
      // millisecond `resume-seek` and the scene played from zero.
      await _openStream(
        selection.current,
        at: resumeTarget ?? Duration.zero,
        play: false,
        generation: generation,
      );
      if (_disposed || generation != _state.generation) return;

      if (resumeTarget != null) {
        _state = _state.copyWith(position: resumeTarget);
        notifyListeners();
      }
      // Whether or not a resume seek was needed, `_state.position` now
      // genuinely reflects this scene's starting position (zero is a real
      // answer here, not a placeholder) — see `_positionEstablished`'s doc.
      _positionEstablished = true;

      _enterStage(timeline, LoadStage.starting, generation);
      await _engine.play();
      if (_disposed || generation != _state.generation) return;

      _finishLoad(timeline);
      _state = _state.copyWith(
        phase: PlaybackPhase.ready,
        clearLoadStage: true,
      );
      notifyListeners();
    } catch (error) {
      // Reported before the generation guard below returns: a load that
      // died four seconds into `open` is exactly the load worth having
      // timings for, and a superseded one still tells you how long the
      // abandoned attempt cost.
      _finishLoad(timeline);
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: PlaybackPhase.failed,
        failure: redactSensitive('$error', apiKey: config?.apiKey ?? ''),
        clearLoadStage: true,
      );
      notifyListeners();
    }
  }

  /// Arms the stall watch. Reactive rather than predictive on purpose:
  /// telling the two kinds of file apart up front would mean reading the
  /// container's box structure before every scene, costing a round trip
  /// on every load to serve the roughly one in twenty-four that needs it.
  /// Waiting costs nothing on the files that work.
  void _armStallWatch(int generation) {
    final selection = _state.streams;
    // A stream the viewer chose is never swapped out from under them,
    // and a spent ladder has nowhere left to go.
    if (_stallTimer != null) return;
    if (selection == null || selection.isManual) return;
    if (selection.nextRung() == null) return;
    _stallTimer = _createStallTimer(_stallFallbackDelay, () {
      _stallTimer = null;
      unawaited(_onStallDeadline(generation));
    });
  }

  void _cancelStallWatch() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// The stall has run its full delay. Switch only if it is still running
  /// and still has nothing to show for it.
  ///
  /// A stall timer this generation still owns (see [_switchTo]'s own doc
  /// for why a stale one can never reach here at all) firing at the same
  /// moment [_handleStreamError] is mid-decision for the same rung is not
  /// a real race: only one of them can still be holding a *live* timer or
  /// an unconsumed [_rungTrialUsed] credit once the other has already
  /// called [_switchTo], since that call cancels the one and spends the
  /// other. The `_rungTrialUsed` check below is therefore belt-and-braces
  /// (structurally, it should already be `false` every time this method
  /// gets this far) rather than the thing actually doing the work, but it
  /// keeps this method honest about the same rule [_handleStreamError]
  /// follows: a rung only gets to be judged once.
  Future<void> _onStallDeadline(int generation) async {
    if (_disposed || generation != _state.generation) return;
    if (!_state.buffering) return;
    // Data is arriving, just slowly. The original file is the better
    // picture, so a stall that is winning is left to win.
    if (_state.buffered > Duration.zero) return;

    final selection = _state.streams;
    final next = selection?.nextRung();
    if (selection == null || next == null || _rungTrialUsed) return;

    _rungTrialUsed = true;
    _log(
      'scene ${_state.scene?.id}: ${selection.current.label} stalled with '
      'nothing cached, retrying on ${next.label} at '
      '${_state.position.inSeconds}s',
    );
    await _switchTo(selection.advance(next), generation);
  }

  /// Opens [stream] so that playback begins at [at]. The single place any
  /// stream is ever opened: the initial load, an automatic ladder step,
  /// and a manual pick all arrive here.
  ///
  /// [play] is an argument rather than something read off
  /// `_state.playing`, because [loadScene] resets `playing` to false
  /// before it opens anything. Inferring the intent would leave every
  /// scene sitting paused on arrival. The switch paths pass the current
  /// value instead, so choosing a different stream while paused stays
  /// paused.
  ///
  /// Where [at] goes depends on the kind. A stream with a real timeline
  /// is opened at an offset within it. A progressive transcode has none
  /// to seek within, so the offset travels as Stash's own `start=` query
  /// parameter and [_streamStartOffset] becomes the bridge between the
  /// stream's clock (which restarts at zero) and the scene's. Nothing
  /// here rewrites the path: an endpoint that reaches this branch is
  /// already the route it is meant to be, and MP4 is not the only
  /// progressive kind (appending `.mp4` to a WEBM endpoint would ask
  /// Stash for a route it does not serve).
  Future<void> _openStream(
    SceneStream stream, {
    required Duration at,
    required bool play,
    required int generation,
  }) async {
    if (_disposed || generation != _state.generation) return;
    final config = _connection;
    if (config == null) return;

    final authenticated = authenticatedUrl(
      Uri.parse(config.serverUrl),
      stream.url.toString(),
      config.apiKey,
    );

    if (stream.kind.hasRealTimeline) {
      _streamStartOffset = Duration.zero;
      await _engine.open(
        authenticated,
        play: play,
        startAt: at > Duration.zero ? at : null,
      );
    } else {
      _streamStartOffset = at;
      await _engine.open(
        at > Duration.zero
            ? authenticated.replace(
                queryParameters: {
                  ...authenticated.queryParameters,
                  'start': at.inSeconds.toString(),
                },
              )
            : authenticated,
        play: play,
      );
    }
  }

  /// Reopens the current scene on [stream], carrying the viewer's
  /// position across.
  ///
  /// Deliberately does not bump [PlaybackState.generation] and does not
  /// touch [ActivitySync]: this is the same scene continuing, not a new
  /// one, so the activity accounting must carry on uninterrupted.
  ///
  /// The single place any switch actually happens, whether the trigger
  /// was a stall deadline or an engine-reported error, which is why its
  /// first three actions matter for both triggers rather than just the
  /// one that called it this time:
  ///
  /// - [_cancelStallWatch] deterministically stops a stall timer already
  ///   armed for the rung this call is moving away from. A `Timer` that
  ///   is cancelled never fires, full stop, so an error-driven switch can
  ///   never leave a stall deadline live to act on stale state, and a
  ///   stall-driven switch can never race its own deadline again.
  /// - Cancelling and rebinding [_errorsSubscription] drops any error
  ///   already queued for delivery to the *old* subscription at the
  ///   moment of the switch, rather than letting it land on whatever
  ///   rung this call is moving *to* instead: a plain
  ///   `StreamController.broadcast()` cancels a subscription's delivery
  ///   synchronously, so an event already scheduled for it is never
  ///   delivered: not to the cancelled subscription, and not to the
  ///   fresh one either, since a new listener never receives a broadcast
  ///   stream's past events. See [_handleStreamError]'s own doc for why
  ///   this alone cannot close every version of the same problem, and
  ///   [_rungTrialUsed] for the rest of it.
  /// - Resetting [_rungTrialUsed] only when [selection] is genuinely a
  ///   different stream than what was current (never on a same-rung
  ///   reopen) gives a newly-arrived rung its own fresh trial without
  ///   handing a stale report that arrives just *after* this settles a
  ///   second bite at skipping ahead again.
  Future<void> _switchTo(StreamSelection selection, int generation) async {
    _cancelStallWatch();
    // Fire-and-forget: the protective effect (no further delivery to the
    // old subscription) is synchronous the moment `cancel()` is called,
    // not once its own returned future resolves, so nothing here needs
    // to await it before rebinding.
    unawaited(_errorsSubscription?.cancel());
    if (_state.streams?.current != selection.current) {
      _rungTrialUsed = false;
    }
    _bindErrorsSubscription(generation);

    final resumeAt = _state.position;
    final wasPlaying = _state.playing;
    _state = _state.copyWith(
      phase: PlaybackPhase.loading,
      loadStage: LoadStage.opening,
      streams: selection,
      buffered: Duration.zero,
      position: resumeAt,
    );
    _positionEstablished = true;
    notifyListeners();

    try {
      await _openStream(
        selection.current,
        at: resumeAt,
        play: wasPlaying,
        generation: generation,
      );
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: PlaybackPhase.ready,
        clearLoadStage: true,
      );
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _state.generation) return;

      // A server can advertise a stream and then refuse to serve it, so a
      // refusal is treated exactly like a stall: try the next rung. A
      // stream the viewer chose is never swapped out from under them, and
      // a spent ladder has nowhere left to go, so both end here.
      final next = selection.isManual ? null : selection.nextRung();
      if (next != null) {
        _log(
          'scene ${_state.scene?.id}: ${selection.current.label} would not '
          'open, trying ${next.label}',
        );
        await _switchTo(selection.advance(next), generation);
        return;
      }

      _state = _state.copyWith(
        phase: PlaybackPhase.failed,
        failure: redactSensitive('$error', apiKey: _connection?.apiKey ?? ''),
        clearLoadStage: true,
      );
      notifyListeners();
    }
  }

  /// Reopens the current progressive transcode so that it begins at
  /// [target]. The offset lives in the URL, not in a seek, so every move
  /// is a reopen.
  Future<void> _reopenAt(Duration target, int generation) async {
    final selection = _state.streams;
    if (selection == null) return;
    final wasPlaying = _state.playing;
    _state = _state.copyWith(
      phase: PlaybackPhase.loading,
      loadStage: LoadStage.opening,
      buffered: Duration.zero,
      position: target,
    );
    _positionEstablished = true;
    notifyListeners();

    try {
      await _openStream(
        selection.current,
        at: target,
        play: wasPlaying,
        generation: generation,
      );
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: PlaybackPhase.ready,
        clearLoadStage: true,
      );
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: PlaybackPhase.failed,
        failure: redactSensitive('$error', apiKey: _connection?.apiKey ?? ''),
        clearLoadStage: true,
      );
      notifyListeners();
    }
  }

  /// Advances [timeline] and mirrors the stage into [state] so the
  /// loading overlay can name what is currently taking the time.
  void _enterStage(LoadTimeline timeline, LoadStage stage, int generation) {
    timeline.enter(stage);
    if (_disposed || generation != _state.generation) return;
    _state = _state.copyWith(loadStage: stage);
    notifyListeners();
  }

  /// Closes [timeline] and logs its stage report, exactly once per load.
  void _finishLoad(LoadTimeline timeline) {
    if (timeline.isFinished) return;
    _log(timeline.finish());
  }

  /// Logs a first-time milestone ("playing after ...", "position
  /// advancing after ...") against the load currently being timed.
  ///
  /// [mark] returns `null` for a milestone already recorded, so a
  /// four-times-a-second position stream reports its first advance and
  /// then says nothing, rather than flooding the console with the same
  /// line for the whole scene.
  void _logMilestone(String? Function(LoadTimeline timeline) mark) {
    final timeline = _timeline;
    if (timeline == null) return;
    final report = mark(timeline);
    if (report != null) _log(report);
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

    // A progressive transcode has nothing to seek within: Stash generates
    // it as it sends it, so asking the engine to seek fails and surfaces
    // as "it cannot seek". Moving means asking the server for a new
    // stream that begins at the target instead.
    final selection = _state.streams;
    if (selection != null && !selection.current.kind.hasRealTimeline) {
      await _reopenAt(clamped, generation);
      return;
    }

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
        // `Duration.zero` doubles as "duration unknown" (see
        // `PlaybackState.duration`'s own doc) — seeking there before the
        // engine's duration stream has emitted would land at the start,
        // not the end, and then report `resumeTime: 0` on the next
        // checkpoint, wiping the scene's real server-side resume point
        // (final review I7). No-op until a real duration is known, the
        // same way `exitFullscreen` above short-circuits when there is
        // nothing to do.
        return _state.duration > Duration.zero
            ? seekAbsolute(_state.duration)
            : Future<void>.value();
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
    _cancelStallWatch();
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
      if (value) _logMilestone((timeline) => timeline.markPlaying());
      _state = _state.copyWith(playing: value);
      notifyListeners();
      // "Accepted" per this method's own doc: only events that passed the
      // guard above reach ActivitySync, so a superseded generation's
      // playing events can never be recorded as this scene's activity.
      _activitySync.playingChanged(value);
    });
    _bufferingSubscription = _engine.buffering.listen((value) {
      if (_disposed || generation != _state.generation) return;
      // The stall is the wait the viewer actually experiences, so it is
      // timed here rather than inferred from the load stages, every one
      // of which can close in milliseconds on a scene that takes a
      // minute to show a frame.
      if (value) {
        _timeline?.markStalled();
        _armStallWatch(generation);
      } else {
        _cancelStallWatch();
        _logMilestone((timeline) => timeline.markUnstalled(_state.buffered));
      }
      _state = _state.copyWith(buffering: value);
      notifyListeners();
      _activitySync.bufferingChanged(value);
    });
    _bufferedSubscription = _engine.buffered.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(buffered: value);
      notifyListeners();
    });
    _positionSubscription = _engine.position.listen((value) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(position: _streamStartOffset + value);
      _positionEstablished = true;
      notifyListeners();
    });
    _durationSubscription = _engine.duration.listen((value) {
      if (_disposed || generation != _state.generation) return;
      // The server's scanned duration wins whenever there is one.
      if (_state.scene?.knownDuration != null) return;
      // Failing that, believe the engine only on a stream that can be
      // honest about its length. A progressive transcode reports how much
      // of itself has arrived, which climbs for the whole scene and would
      // drag the transport's total up with it. A manifest enumerates every
      // segment of the whole file up front, so its number is real.
      if (_state.streams?.current.kind.reportsTrueDuration == false) return;
      _state = _state.copyWith(duration: value);
      notifyListeners();
    });
    _rungTrialUsed = false;
    _bindErrorsSubscription(generation);
  }

  /// (Re)binds [_errorsSubscription] to [_engine.errors]. Called once by
  /// [_bindStreams] for the scene's initial rung, and again by
  /// [_switchTo] on every switch: see that method's own doc for why
  /// rebinding, not just leaving the original subscription running for
  /// the whole scene, matters.
  void _bindErrorsSubscription(int generation) {
    _errorsSubscription = _engine.errors.listen((message) {
      if (_disposed || generation != _state.generation) return;
      unawaited(_handleStreamError(message, generation));
    });
  }

  /// Reacts to one line from [PlaybackEngine.errors], on the same terms
  /// [_switchTo]'s own catch already applies to a refused [_openStream]
  /// call: advance to the next rung unless the viewer picked this stream
  /// themselves or the ladder is already spent. This is the other half
  /// of that same rule, for a server that advertises a stream and only
  /// fails it after `open` already returned: real playback is
  /// asynchronous, so `open` itself never throws for a refusal, only the
  /// errors stream reports it, later.
  ///
  /// Unlike a thrown `open`, a message on this stream carries no
  /// identity: there is no way to tell whether it describes the rung
  /// this generation just switched *away* from, or the one it switched
  /// *to*. libmpv can report a single failed load as more than one error
  /// line (a demuxer-open failure and its own end-of-file summary for
  /// the same refusal, say), and every one of them is delivered here,
  /// one at a time, only once the previous one has been fully reacted
  /// to. That means a stray report for an already-abandoned rung can and
  /// does arrive after this generation has already moved past it,
  /// looking exactly like a fresh failure of wherever it landed. The
  /// same is true of [_onStallDeadline]'s own decisions: nothing stops a
  /// stall timeout and an engine-reported error from both existing for
  /// the same underlying failure, one arriving just after the other has
  /// already switched.
  ///
  /// That ambiguity is resolved by proof rather than by timing, and
  /// [_rungTrialUsed] is what makes the proof possible: whichever
  /// trigger (this method, or [_onStallDeadline]) reaches a rung first
  /// gets to decide for it, advancing if there is a next rung or (once
  /// the ladder is spent) reopening it once, and marks that rung's trial
  /// used. Any further report while `_rungTrialUsed` is still `true` for
  /// the *current* rung cannot be trusted to be about it rather than
  /// about whatever this generation already left behind, so it goes
  /// straight to the terminal branch below instead of getting to skip
  /// (or fail) a rung on its own unproven say-so. [_switchTo] resets the
  /// flag the moment it lands on a genuinely different stream, so a
  /// rung that never actually had a problem of its own still gets a
  /// fresh, full-speed trial: the ambiguity only ever costs a rung that
  /// already used its own trial a chance to skip further, never a
  /// newly-arrived one a chance to be judged fairly. A rung that is
  /// genuinely broken still surfaces as a failure: either its own reopen
  /// fails too ([_switchTo]'s own catch still applies to that attempt),
  /// or a second, truly independent report against it lands in the
  /// terminal branch directly.
  Future<void> _handleStreamError(String message, int generation) async {
    if (_disposed || generation != _state.generation) return;

    final selection = _state.streams;
    if (selection != null && !selection.isManual && !_rungTrialUsed) {
      _rungTrialUsed = true;
      final next = selection.nextRung();
      if (next != null) {
        _log(
          'scene ${_state.scene?.id}: ${selection.current.label} reported '
          '$message, trying ${next.label}',
        );
        await _switchTo(selection.advance(next), generation);
      } else {
        _log(
          'scene ${_state.scene?.id}: ${selection.current.label} reported '
          '$message, reopening it once before giving up',
        );
        await _switchTo(selection, generation);
      }
      return;
    }

    _state = _state.copyWith(
      phase: PlaybackPhase.failed,
      failure: redactSensitive(message, apiKey: _connection?.apiKey ?? ''),
    );
    notifyListeners();
  }

  /// Cancels (and clears) every currently-bound stream subscription
  /// concurrently, so replacing a scene's subscriptions never leaves a
  /// meaningful window where an old subscription is still deliverable
  /// while a new one is already active.
  Future<void> _cancelSubscriptions() async {
    final subscriptions = <StreamSubscription<void>?>[
      _playingSubscription,
      _bufferingSubscription,
      _bufferedSubscription,
      _positionSubscription,
      _durationSubscription,
      _errorsSubscription,
    ];
    _playingSubscription = null;
    _bufferingSubscription = null;
    _bufferedSubscription = null;
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
        controlFailure: redactSensitive(
          '$error',
          apiKey: _connection?.apiKey ?? '',
        ),
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

/// Builds one [PlaybackEngine], optionally routing its media requests
/// through an HTTP proxy at [httpProxyUrl].
typedef PlaybackEngineFactory = PlaybackEngine Function({String? httpProxyUrl});

/// Constructs one concrete [PlaybackEngine] instance. Production's
/// default is a real [MediaKitPlaybackEngine], which starts native
/// playback libraries — tests override *this* provider (not
/// [playbackEngineProvider] itself; see that provider's doc for why)
/// with a factory that hands back a `FakePlaybackEngine` instead, the
/// same way `stashApiFactoryProvider` lets `LibraryController` tests
/// swap in a `FakeStashApi`.
final playbackEngineFactoryProvider = Provider<PlaybackEngineFactory>(
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
/// Also watches [socksForwardProxyProvider] so the engine is built knowing
/// where to send its own requests. libmpv does its networking in C, outside
/// the `http.Client` everything else here shares, so the proxy has to be
/// handed to it explicitly rather than inherited.
final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  ref.watch(connectionGenerationProvider);
  final proxy = ref.watch(socksForwardProxyProvider);
  final factory = ref.watch(playbackEngineFactoryProvider);
  return factory(httpProxyUrl: proxy?.httpProxyUrl);
});

/// [PlaybackController] provider. Rebuilt — a fresh controller, which
/// disposes the previous one's engine — whenever
/// [connectionGenerationProvider] changes, the same way
/// `libraryControllerProvider` is: a settings-driven reconnection must
/// not keep streaming from the old server/key.
///
/// The fullscreen requester is a placeholder that always reports **failure**
/// without touching any real window: this codebase has no window-manager
/// integration on either target yet (final review C4), and implementing one
/// couldn't be verified from the host this fix shipped from (no macOS host;
/// Linux fullscreen is unverifiable headlessly) — shipping an unverifiable
/// implementation as "done" would repeat the exact mistake C4 named.
/// Reporting `false` keeps [setFullscreen] honest: [PlaybackState.fullscreen]
/// never flips to `true`. There is no fullscreen button in the player
/// chrome to disable: `player_top_bar.dart` and `player_bar.dart` never
/// shipped one, so the F and Escape shortcuts (`player_shortcuts.dart`,
/// mapped to [PlayerAction.toggleFullscreen] and
/// [PlayerAction.exitFullscreen]) stay wired and simply no-op through this
/// requester instead of pretending fullscreen took effect. A real
/// [setFullscreenPlatform] (Linux: GTK `gtk_window_fullscreen` via the
/// runner or a `window_manager`-class dependency; macOS:
/// `NSWindow.toggleFullScreen(_:)`, as the SwiftUI app already does) is
/// clearly-scoped follow-up work, not part of this fix.
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
    setFullscreenPlatform: (fullscreen) async => false,
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
