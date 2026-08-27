import 'dart:async';

/// Signature of `StashApi.saveSceneActivity`, injected rather than a
/// `StashApi` instance directly — [ActivitySync] shouldn't need to know how
/// to obtain one (production resolves it from `stashApiProvider`, which is
/// itself async), only how to call it.
typedef SaveSceneActivity =
    Future<void> Function({
      required String id,
      required double resumeTime,
      required double playDuration,
    });

/// The exact wait schedule between the first failed checkpoint attempt and
/// each of the next three. Four total attempts (the initial one plus these
/// three retries) are made before [ActivitySync] gives up on a checkpoint
/// and surfaces a warning — see [ActivitySync.flush].
const retryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// The exact, non-modal warning [ActivitySync] reports (via its injected
/// `onWarning`) after four total failed attempts to save a checkpoint. Not
/// an error: playback itself is never interrupted by a sync failure — see
/// [ActivitySync.flush]'s doc for why.
const activitySyncWarningMessage =
    'Playback progress could not be synced. Playback will continue and retry later.';

/// Wall-clock seconds of *active* playback (`playing && !buffering`)
/// [ActivitySync] accumulates before its periodic [tick] triggers a
/// checkpoint on its own, without a lifecycle event (pause/seek/scene
/// replacement/dispose) asking for one.
const _checkpointThreshold = Duration(seconds: 10);

/// How often [ActivitySync]'s own internal timer wakes [tick] up once
/// tracking starts. This is *only* a wakeup cadence — [tick] itself decides,
/// using the injected clock, whether the real ~10s threshold has actually
/// been reached; a shorter or longer cadence only changes how promptly a
/// due checkpoint is noticed, never whether one is.
const _tickWakeupInterval = Duration(seconds: 1);

/// Wall-clock activity accounting for one [PlaybackController]: how many
/// seconds of a scene the user has actually watched since the last
/// successfully-saved checkpoint, and getting that number (plus the current
/// resume position) to `StashApi.saveSceneActivity` reliably — without ever
/// letting a slow or failing network call touch playback itself.
///
/// ## What counts
///
/// Only wall-clock time while the engine reports `playing == true` and
/// `buffering == false` counts towards the queued delta ([playingChanged]
/// and [bufferingChanged] both feed the same `active` computation — a scene
/// that buffers for 30 seconds while nominally "playing" must contribute
/// zero). [playingChanged] additionally treats a transition to
/// `playing: false` as a pause and flushes immediately, one of this class's
/// four lifecycle flush boundaries (the other three are [flush] itself,
/// called by `PlaybackController` before a seek and once more during
/// [PlaybackController.dispose] by way of this class's own [dispose], and
/// [replaceScene], called before a new scene's ID replaces the old one).
///
/// ## Accumulation
///
/// [_playStartedAt] marks when the current active span began; it is
/// `null` whenever playback isn't active. Every flush (periodic or
/// lifecycle) and every transition out of "active" accumulates
/// `clock() - _playStartedAt` into [queuedActive] *exactly once* — a flush
/// that folds elapsed time in, immediately followed by a pause that folds
/// the same span in again from a stale marker, would double-bill it. A
/// flush that fires while still active re-marks `_playStartedAt` to "now"
/// afterwards so the clock keeps running for the *next* boundary; a
/// transition to inactive instead clears it, since there is no "next
/// span" until playback resumes.
///
/// ## Checkpoints and retries
///
/// [flush] snapshots [queuedActive] before doing anything async, so any
/// activity that accrues *during* the request — including across its own
/// retries — is never touched by that flush's own bookkeeping: on success,
/// only the snapshot is subtracted, never the current total, so time added
/// mid-flight survives. On failure it retries after the exact
/// [retryDelays] schedule (1s, 2s, 4s — four attempts in total); if the
/// fourth also fails, the snapshot is left queued for the next flush,
/// [activitySyncWarningMessage] is reported through the injected
/// `onWarning` exactly once, and [flush] still completes normally — a
/// sync failure never throws into playback, never pauses it, and never
/// changes its playing state.
///
/// Every flush (periodic or lifecycle) is serialized through the single
/// [_flushTail] future, so a periodic [tick] landing while a
/// lifecycle-triggered flush is still retrying queues behind it instead of
/// racing it — no two checkpoint requests for this scene are ever
/// in flight at once.
///
/// [dispose] cancels the periodic timer first (so it can never fire again,
/// not even mid-teardown) and then performs one last [flush] before
/// completing — matching `PlaybackController`'s own single-dispose-site
/// discipline, this is safe to call more than once.
class ActivitySync {
  ActivitySync({
    required double Function() resumePositionSeconds,
    SaveSceneActivity? saveActivity,
    void Function(String message)? onWarning,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Duration tickInterval = _tickWakeupInterval,
  }) : _resumePositionSeconds = resumePositionSeconds,
       _saveActivity = saveActivity ?? _noopSaveActivity,
       _onWarning = onWarning ?? _noopWarning,
       _clock = clock ?? DateTime.now,
       _delay = delay ?? _realDelay,
       _tickInterval = tickInterval;

  static Future<void> _noopSaveActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) async {}

  static void _noopWarning(String message) {}

  static Future<void> _realDelay(Duration duration) =>
      Future<void>.delayed(duration);

  final double Function() _resumePositionSeconds;
  final SaveSceneActivity _saveActivity;
  final void Function(String message) _onWarning;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Duration _tickInterval;

  String? _sceneId;
  bool _playing = false;
  bool _buffering = false;

  /// Set while playback is active; the wall-clock moment the current
  /// active span began, per the injected clock. `null` whenever playback
  /// isn't active (see the class doc's "Accumulation" section).
  DateTime? _playStartedAt;

  /// Seconds of active playback accumulated but not yet acknowledged by a
  /// successful [flush]. Exposed read-only as [queuedActive].
  Duration _queuedActive = Duration.zero;

  DateTime? _lastSuccessfulCheckpointAt;

  Timer? _timer;
  bool _disposed = false;

  /// One future every flush (periodic or lifecycle) chains onto, so no two
  /// ever run concurrently. [_doFlush] never completes with an error, so
  /// chaining onto it repeatedly can never leave this future permanently
  /// failed ("poisoned") for later flushes.
  Future<void> _flushTail = Future<void>.value();

  /// Active seconds accumulated since the last successful checkpoint,
  /// including whatever has accrued in the current active span (not yet
  /// folded in — that only happens at a flush or a transition to
  /// inactive). Exposed for tests; production code has no reason to read
  /// it.
  Duration get queuedActive => _queuedActive;

  /// When the last checkpoint actually succeeded, per the injected clock —
  /// `null` until the first one does. Exposed for tests/diagnostics;
  /// [flush]'s own retry/warning logic is driven entirely by [queuedActive]
  /// and doesn't consult this.
  DateTime? get lastSuccessfulCheckpointAt => _lastSuccessfulCheckpointAt;

  bool get _active => _playing && !_buffering;

  /// Called from the playback engine's accepted `playing` stream events
  /// (i.e. ones that have already passed `PlaybackController`'s own
  /// generation/disposed guards). A transition to `false` is treated as a
  /// pause and triggers an immediate [flush]; a transition to `true` only
  /// starts (or resumes) the active clock.
  void playingChanged(bool playing) {
    if (_disposed || _playing == playing) return;
    _playing = playing;
    _applyActiveTransition();
    if (!playing) unawaited(flush());
  }

  /// Called from the playback engine's accepted `buffering` stream events,
  /// the same way [playingChanged] is. Buffering never itself triggers a
  /// flush — it only stops (or resumes) the active clock, so a long
  /// buffering stall while nominally playing contributes zero.
  void bufferingChanged(bool buffering) {
    if (_disposed || _buffering == buffering) return;
    _buffering = buffering;
    _applyActiveTransition();
  }

  void _applyActiveTransition() {
    if (_active) {
      _playStartedAt = _clock();
      _ensureTimer();
    } else {
      _accumulate(resetMarker: true);
    }
  }

  /// Periodic wakeup — see [_tickWakeupInterval]. Cheaply checks whether
  /// the queued delta *plus* whatever has accrued in the current active
  /// span (without mutating anything) has reached [_checkpointThreshold],
  /// and if so kicks off a [flush]. Below threshold, this sends nothing.
  void tick() {
    if (_disposed) return;
    if (_queuedActive + _pendingActiveSpan() >= _checkpointThreshold) {
      unawaited(flush());
    }
  }

  Duration _pendingActiveSpan() {
    final startedAt = _playStartedAt;
    if (startedAt == null) return Duration.zero;
    final elapsed = _clock().difference(startedAt);
    return elapsed > Duration.zero ? elapsed : Duration.zero;
  }

  /// Folds `clock() - _playStartedAt` into [_queuedActive] exactly once,
  /// if playback is currently active (a no-op otherwise). [resetMarker]
  /// controls what happens to the active-span marker afterwards: `true`
  /// (a genuine transition to inactive) clears it, `false` (a flush that
  /// doesn't itself mean playback stopped) re-marks it to "now" so the
  /// next boundary picks up from here rather than double-counting or
  /// losing time.
  void _accumulate({required bool resetMarker}) {
    final startedAt = _playStartedAt;
    if (startedAt == null) return;
    final now = _clock();
    final elapsed = now.difference(startedAt);
    if (elapsed > Duration.zero) _queuedActive += elapsed;
    _playStartedAt = resetMarker ? null : now;
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(_tickInterval, (_) => tick());
  }

  /// Flushes whatever is queued for the *current* scene to
  /// `StashApi.saveSceneActivity`, retrying on failure per [retryDelays]
  /// and reporting [activitySyncWarningMessage] once if all four attempts
  /// fail. Always completes normally — never throws — so a caller (a
  /// lifecycle boundary in `PlaybackController`) never needs to guard
  /// against a sync failure interrupting playback; see the class doc.
  ///
  /// A no-op (but still serialized behind [_flushTail]) if no scene is
  /// currently tracked (before the first [replaceScene] call).
  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    return _enqueueFlush();
  }

  /// The actual [_flushTail] chaining, shared by [flush] and [dispose] —
  /// [dispose] needs its own final flush to still run even though it has
  /// already set [_disposed], which is exactly what [flush] itself now
  /// refuses to do.
  Future<void> _enqueueFlush() {
    final next = _flushTail.then((_) => _doFlush());
    _flushTail = next;
    return next;
  }

  Future<void> _doFlush() async {
    try {
      // Accumulate before doing anything async — this is the one required
      // accumulation point for a flush that doesn't already come from a
      // transition to inactive (which accumulates via `_applyActiveTransition`
      // instead, still exactly once overall since this is a no-op once
      // `_playStartedAt` is already null).
      _accumulate(resetMarker: false);

      final sceneId = _sceneId;
      if (sceneId == null) return;

      // Snapshot now, before any await: active time that accrues while
      // this request (and its retries) are in flight must survive, so only
      // this snapshot — never the live total — is ever subtracted.
      final snapshot = _queuedActive;
      final resumeTime = _resumePositionSeconds();
      final playDuration =
          snapshot.inMicroseconds / Duration.microsecondsPerSecond;

      var attempt = 1;
      while (true) {
        try {
          await _saveActivity(
            id: sceneId,
            resumeTime: resumeTime,
            playDuration: playDuration,
          );
          _queuedActive -= snapshot;
          _lastSuccessfulCheckpointAt = _clock();
          return;
        } catch (_) {
          if (attempt > retryDelays.length) {
            _onWarning(activitySyncWarningMessage);
            return;
          }
          await _delay(retryDelays[attempt - 1]);
          attempt++;
        }
      }
    } catch (_) {
      // Belt-and-braces: every branch above already avoids throwing, but
      // nothing here may ever escape into the `_flushTail` chain — doing
      // so would poison every later flush for the lifetime of this
      // ActivitySync (see [_flushTail]'s doc).
    }
  }

  /// Flushes whatever is queued for the *old* scene (using its ID, not
  /// [sceneId]) and only then starts tracking [sceneId] from a clean
  /// slate — any leftover delta the old scene's flush couldn't save is
  /// discarded rather than misattributed to the new scene.
  ///
  /// `PlaybackController.loadScene` calls this before the new scene
  /// otherwise starts driving the engine, so no activity for the new
  /// scene can be recorded before this completes.
  Future<void> replaceScene(String sceneId) async {
    if (_disposed) return;
    await flush();
    _sceneId = sceneId;
    _queuedActive = Duration.zero;
    _playStartedAt = null;
    _playing = false;
    _buffering = false;
  }

  /// Cancels the periodic timer (so it can never fire — and so never call
  /// `saveSceneActivity` — again) and performs one last [flush]. Safe to
  /// call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _enqueueFlush();
    } catch (_) {
      // flush() is contractually guaranteed not to throw; this is
      // belt-and-braces so a bug there can never strand this dispose call.
    }
  }
}
