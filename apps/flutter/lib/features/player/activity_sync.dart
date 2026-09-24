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

/// Defensive cap on any *single* accumulated active span (see
/// [ActivitySync._accumulate]). `DateTime.now` is wall-clock, not
/// monotonic: a suspended laptop can report a multi-hour gap between two
/// calls that, under normal operation, are only ever a checkpoint-plus-a-
/// tick apart (~11s). Without this cap, waking from sleep while `playing`
/// was left `true` (with no intervening buffering event) would bill the
/// entire suspended duration as watched time on the very next accumulate.
/// Any excess beyond this cap is simply never counted — there is no way to
/// know whether the user was actually watching during a gap this large, so
/// the safe assumption is that they weren't.
const _maxSingleActiveSpan = Duration(seconds: 30);

/// Flat headroom added to [retryDelays]'s own sum when computing
/// [disposeFlushTimeout] — see that constant's doc for why a margin is
/// needed at all. 3 seconds is deliberately small: a clearly-down
/// checkpoint endpoint (connection refused, DNS failure) typically fails
/// each attempt in well under a second, so this comfortably covers all
/// four attempts' own round-trip time without materially loosening the
/// dispose bound. It does not cover an attempt still in flight when this
/// margin runs out: `HttpStashApi._post` does enforce its own per-request
/// `.timeout()`, but that timeout is deliberately longer than this whole
/// margin, so a slow (not yet failed) attempt can still be outstanding when
/// [ActivitySync.dispose] gives up. That is fine — `dispose` bounds itself
/// independently via [disposeFlushTimeout] no matter what the in-flight
/// request is doing; this margin only needs to cover a *fast-failing*
/// endpoint's four round trips.
const _disposeFlushMargin = Duration(seconds: 3);

/// Upper bound on how long [ActivitySync.dispose] will wait for its final
/// checkpoint before giving up and letting teardown proceed. Must be
/// *strictly greater* than the sum of [retryDelays] (not merely equal to
/// it, as an earlier version of this constant was): a fully-failing
/// checkpoint's fourth attempt only begins once all three backoff delays
/// (1s + 2s + 4s = 7s) have elapsed, so a timeout of exactly 7s always
/// resolves at the same instant that final attempt would even start,
/// hard-stopping the chain (see [ActivitySync.dispose]'s own doc) before
/// it can be sent and before the brief's mandated "after the final failed
/// retry, call onWarning once" can ever happen on this boundary. Any
/// single flush that hasn't resolved by [retryDelays]'s sum plus
/// [_disposeFlushMargin] is either still waiting on a slow network
/// response or genuinely stuck, and either way `PlaybackController.dispose`
/// must not be starved behind it indefinitely (a disposed engine is a
/// "keeps playing audio in the background" bug) — but `PlaybackController`
/// pauses the engine before this flush ever runs (see its own `dispose`
/// doc), so the few extra seconds this margin adds no longer carry that
/// risk the way an unbounded wait would have.
final Duration disposeFlushTimeout =
    retryDelays.fold(Duration.zero, (sum, delay) => sum + delay) +
    _disposeFlushMargin;

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
/// span" until playback resumes. Any single span is capped at
/// [_maxSingleActiveSpan] (see its own doc) to defend against a
/// non-monotonic wall clock.
///
/// ## Checkpoints and retries
///
/// [flush] snapshots [queuedActive] before doing anything async, so any
/// activity that accrues *during* the request — including across its own
/// retries — is never touched by that flush's own bookkeeping: on success,
/// only the snapshot is subtracted, never the current total, so time added
/// mid-flight survives. On failure it retries after the exact
/// [retryDelays] schedule (1s, 2s, 4s — four attempts in total); if the
/// fourth also fails, the snapshot is left queued for the next flush and
/// [flush] still completes normally — a sync failure never throws into
/// playback, never pauses it, and never changes its playing state.
/// [activitySyncWarningMessage] is reported at most once per unacknowledged
/// failure streak: [_warnedSinceLastSuccess] suppresses every further
/// warning until a checkpoint actually succeeds, since a down endpoint
/// would otherwise re-warn on every ~8-second failed cycle for the entire
/// session (each a fresh, separate `SnackBar`).
///
/// [flush] and [replaceScene] only wait for that *first* attempt to
/// settle (success or failure), never the full retry chain — a user-facing
/// seek or scene load must not stall for up to 7 seconds because the
/// activity endpoint is down. The retry chain, if the first attempt
/// failed, keeps running in the background, still fully serialized behind
/// [_flushTail]. [dispose] is the exception: it waits for the whole chain
/// (it's the last chance to save), bounded by [disposeFlushTimeout] so a
/// dead endpoint can never starve `_engine.dispose()`.
///
/// Every flush (periodic or lifecycle) is serialized through the single
/// [_flushTail] future, so a periodic [tick] landing while a
/// lifecycle-triggered flush is still retrying queues behind it instead of
/// racing it — no two checkpoint requests for this scene are ever
/// in flight at once. [tick] additionally refuses to enqueue a new flush
/// while one is already pending ([_flushPending]) — without this, a
/// checkpoint endpoint that fails every attempt leaves [queuedActive]
/// permanently at or above [_checkpointThreshold], and an unguarded
/// [tick] would enqueue a fresh flush on every wakeup forever, growing the
/// backlog without bound.
///
/// [replaceScene] resets tracking to a clean slate for the new scene as
/// soon as the outgoing scene's *first* checkpoint attempt settles — but a
/// detached retry chain for the outgoing scene can still succeed *after*
/// that reset. [_sceneEpoch] (bumped by every [replaceScene]) lets a late
/// success recognise it's stale and skip mutating [queuedActive] instead of
/// driving it negative (which would have this class report a *negative*
/// `playDuration` for the scene that's current by then) — see [_doFlush]'s
/// own comment for the exact mechanics. As a backstop, the subtraction is
/// also clamped at [Duration.zero] regardless.
///
/// The periodic timer itself only runs while playback is active: it
/// starts on a transition to active and is cancelled on a transition to
/// inactive that goes through [_applyActiveTransition] — pause,
/// buffering, or [dispose] — so a paused scene can never keep retrying
/// (and re-warning) in the background. [replaceScene] is the one
/// exception: it sets `_playing = false` directly rather than routing
/// through [_applyActiveTransition], so a timer already running when a
/// scene swap happens is *not* cancelled there. This is harmless at
/// runtime — [tick] is a no-op once [replaceScene] has also zeroed
/// [_playStartedAt] and [queuedActive], and the same timer simply keeps
/// serving the new scene once it starts playing — but it means the timer
/// is not, in fact, cancelled on *every* transition to inactive as an
/// earlier version of this doc claimed.
///
/// [dispose] cancels the periodic timer first (so it can never fire again,
/// not even mid-teardown) and then performs one last, time-bounded
/// [flush] before completing — matching `PlaybackController`'s own
/// single-dispose-site discipline, this is safe to call more than once.
/// That last flush can still report [activitySyncWarningMessage] if it
/// fails (subject to the same [_warnedSinceLastSuccess] suppression as
/// every other flush) — "no callbacks after teardown" is *not* just about
/// what's initiated post-dispose (every public method already refuses to
/// do anything once [_disposed] is `true`): if [dispose]'s own bounded
/// wait times out while its (or an earlier, still-detached) flush keeps
/// retrying in the background, [_hardStopped] is set and re-checked after
/// every `await` inside [_doFlush], so that detached chain can never call
/// `saveActivity` or `onWarning` again once `PlaybackController` has
/// already moved on to disposing the engine.
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

  /// Bumped by every [replaceScene] call. A flush's snapshot is tagged
  /// with the epoch in effect when it was taken; if the epoch has moved on
  /// by the time that flush (possibly a detached, still-retrying one)
  /// finally succeeds, [queuedActive] has since been reset for a different
  /// scene and must not be touched — see [_doFlush].
  int _sceneEpoch = 0;

  /// Set once and never cleared, when [dispose]'s own bounded wait times
  /// out while a flush (its own, or an earlier detached one) is still
  /// running. Re-checked after every `await` inside [_doFlush] so that
  /// chain can never call `saveActivity`/`onWarning` again once
  /// `PlaybackController` has already moved on — see the class doc.
  bool _hardStopped = false;

  /// Suppresses every warning after the first, until a checkpoint actually
  /// succeeds — see the class doc's "Checkpoints and retries" section.
  bool _warnedSinceLastSuccess = false;

  Timer? _timer;
  bool _disposed = false;

  /// Whether a flush is currently enqueued or executing (including its
  /// own retries). Consulted only by [tick] — see the class doc's
  /// "Checkpoints and retries" section for why an unguarded periodic
  /// tick would otherwise grow the backlog without bound whenever the
  /// checkpoint endpoint is down.
  bool _flushPending = false;

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

  /// Starts the active clock (and the periodic timer) on a transition to
  /// active; on a transition to inactive, folds the just-ended span in and
  /// **stops the timer**, so a paused (or buffering) scene can never keep
  /// silently retrying a failed checkpoint — and re-warning about it — in
  /// the background. [_ensureTimer] restarts it fresh the next time
  /// playback becomes active again.
  void _applyActiveTransition() {
    if (_active) {
      _playStartedAt = _clock();
      _ensureTimer();
    } else {
      _accumulate(resetMarker: true);
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Periodic wakeup — see [_tickWakeupInterval]. Cheaply checks whether
  /// the queued delta *plus* whatever has accrued in the current active
  /// span (without mutating anything) has reached [_checkpointThreshold],
  /// and if so kicks off a [flush] — unless one is already [_flushPending],
  /// in which case this tick does nothing: the already-enqueued flush will
  /// pick up wherever things stand once it's its turn. Below threshold,
  /// this sends nothing.
  void tick() {
    if (_disposed || _flushPending) return;
    if (_queuedActive + _pendingActiveSpan() >= _checkpointThreshold) {
      unawaited(flush());
    }
  }

  Duration _pendingActiveSpan() {
    final startedAt = _playStartedAt;
    if (startedAt == null) return Duration.zero;
    return _clampSpan(_clock().difference(startedAt));
  }

  Duration _clampSpan(Duration elapsed) {
    if (elapsed <= Duration.zero) return Duration.zero;
    return elapsed > _maxSingleActiveSpan ? _maxSingleActiveSpan : elapsed;
  }

  /// Folds `clock() - _playStartedAt` into [_queuedActive] exactly once,
  /// if playback is currently active (a no-op otherwise), clamped per
  /// [_clampSpan]. [resetMarker] controls what happens to the active-span
  /// marker afterwards: `true` (a genuine transition to inactive) clears
  /// it, `false` (a flush that doesn't itself mean playback stopped)
  /// re-marks it to "now" so the next boundary picks up from here rather
  /// than double-counting or losing time.
  void _accumulate({required bool resetMarker}) {
    final startedAt = _playStartedAt;
    if (startedAt == null) return;
    final now = _clock();
    final elapsed = _clampSpan(now.difference(startedAt));
    if (elapsed > Duration.zero) _queuedActive += elapsed;
    _playStartedAt = resetMarker ? null : now;
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(_tickInterval, (_) => tick());
  }

  /// Flushes whatever is queued for the *current* scene to
  /// `StashApi.saveSceneActivity`. Resolves once the first attempt has
  /// settled (success or failure) — never the full [retryDelays] chain,
  /// so a caller (a user-facing seek or scene load) is never stalled
  /// behind a checkpoint retry storm. If the first attempt failed, the
  /// remaining retries continue in the background, still fully serialized
  /// behind [_flushTail], reporting [activitySyncWarningMessage] once (per
  /// [_warnedSinceLastSuccess]) if all four attempts ultimately fail.
  /// Always completes normally — never throws — so a caller never needs
  /// to guard against a sync failure interrupting playback; see the class
  /// doc.
  ///
  /// A no-op (but still serialized behind [_flushTail]) if no scene is
  /// currently tracked (before the first [replaceScene] call).
  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    return _flushAwaitingFirstAttempt();
  }

  Future<void> _flushAwaitingFirstAttempt({
    double? resumeTimeOverride,
    bool requireKnownResumeTime = false,
  }) {
    final firstAttempt = Completer<void>();
    _enqueueFlush(
      resumeTimeOverride: resumeTimeOverride,
      requireKnownResumeTime: requireKnownResumeTime,
      firstAttemptSignal: firstAttempt,
    );
    return firstAttempt.future;
  }

  /// The actual [_flushTail] chaining. [firstAttemptSignal], if given, is
  /// completed by [_doFlush] as soon as its first `saveActivity` attempt
  /// settles — independent of this method's own returned future, which
  /// always represents the *entire* chain (all retries), exactly as
  /// before. [dispose] uses this returned future directly (racing it
  /// against [disposeFlushTimeout]) since it must wait for the whole
  /// thing, not just the first attempt.
  Future<void> _enqueueFlush({
    double? resumeTimeOverride,
    bool requireKnownResumeTime = false,
    Completer<void>? firstAttemptSignal,
  }) {
    _flushPending = true;
    final next = _flushTail.then(
      (_) => _doFlush(
        resumeTimeOverride: resumeTimeOverride,
        requireKnownResumeTime: requireKnownResumeTime,
        firstAttemptSignal: firstAttemptSignal,
      ),
    );
    _flushTail = next;
    return next;
  }

  Future<void> _doFlush({
    double? resumeTimeOverride,
    bool requireKnownResumeTime = false,
    Completer<void>? firstAttemptSignal,
  }) async {
    try {
      if (_hardStopped) {
        _completeFirstAttempt(firstAttemptSignal);
        return;
      }

      // Accumulate before doing anything async — this is the one required
      // accumulation point for a flush that doesn't already come from a
      // transition to inactive (which accumulates via `_applyActiveTransition`
      // instead, still exactly once overall since this is a no-op once
      // `_playStartedAt` is already null).
      _accumulate(resetMarker: false);

      final sceneId = _sceneId;
      if (sceneId == null) {
        _completeFirstAttempt(firstAttemptSignal);
        return;
      }

      // Snapshot now, before any await: active time that accrues while
      // this request (and its retries) are in flight must survive, so only
      // this snapshot — never the live total — is ever subtracted. Tag it
      // with the scene epoch in effect right now: if `replaceScene` moves
      // the epoch on before this flush's eventual success, `queuedActive`
      // belongs to a different scene by then and must not be touched (N1).
      final snapshot = _queuedActive;
      final epochAtSnapshot = _sceneEpoch;

      if (requireKnownResumeTime &&
          resumeTimeOverride == null &&
          snapshot == Duration.zero) {
        // `replaceScene` couldn't establish the outgoing scene's real
        // position (e.g. it was superseded before its own resume seek —
        // or any position event at all — ever landed) and there's no
        // watched time to report either. Sending `resumeTime: 0.0` here
        // would silently wipe that scene's real resume point for nothing
        // (N4) — there's nothing worth telling Stash about, so skip the
        // network call entirely.
        _completeFirstAttempt(firstAttemptSignal);
        return;
      }

      // `resumeTimeOverride` is set by `replaceScene`, which must report
      // the *outgoing* scene's last known position, not whatever the live
      // callback would return once the caller has already moved its own
      // state on to the next scene.
      final resumeTime = resumeTimeOverride ?? _resumePositionSeconds();
      final playDuration =
          snapshot.inMicroseconds / Duration.microsecondsPerSecond;

      var attempt = 1;
      while (true) {
        if (_hardStopped) {
          _completeFirstAttempt(firstAttemptSignal);
          return;
        }
        try {
          await _saveActivity(
            id: sceneId,
            resumeTime: resumeTime,
            playDuration: playDuration,
          );
          if (_hardStopped) {
            _completeFirstAttempt(firstAttemptSignal);
            return;
          }
          if (epochAtSnapshot == _sceneEpoch) {
            final remaining = _queuedActive - snapshot;
            _queuedActive = remaining < Duration.zero
                ? Duration.zero
                : remaining;
          }
          // Else: a `replaceScene` happened since this snapshot was taken
          // (this flush is a detached, once-current-scene chain that
          // finally succeeded) — `queuedActive` now belongs to a
          // different scene and subtracting this snapshot from it would
          // drive it negative, eventually reporting a negative
          // `playDuration` for whatever scene is current by then (N1).
          _warnedSinceLastSuccess = false;
          _completeFirstAttempt(firstAttemptSignal);
          return;
        } catch (_) {
          // Unblock a caller waiting only on the first attempt regardless
          // of outcome — a no-op on the 2nd/3rd/4th attempt, since it's
          // already completed by then.
          _completeFirstAttempt(firstAttemptSignal);
          if (_hardStopped) return;
          if (attempt > retryDelays.length) {
            if (!_warnedSinceLastSuccess) {
              _warnedSinceLastSuccess = true;
              _reportWarning(activitySyncWarningMessage);
            }
            return;
          }
          await _delay(retryDelays[attempt - 1]);
          if (_hardStopped) return;
          attempt++;
        }
      }
    } catch (_) {
      // Belt-and-braces: every branch above already avoids throwing, but
      // nothing here may ever escape into the `_flushTail` chain — doing
      // so would poison every later flush for the lifetime of this
      // ActivitySync (see [_flushTail]'s doc).
      _completeFirstAttempt(firstAttemptSignal);
    } finally {
      _flushPending = false;
    }
  }

  void _completeFirstAttempt(Completer<void>? signal) {
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Reports [message] via the injected `onWarning`. Deliberately *not*
  /// itself guarded by [_disposed]: [dispose]'s own final flush attempt
  /// sets [_disposed] before that attempt even starts (so it can bypass
  /// [flush]'s own disposed-guard — see [_enqueueFlush]'s doc), and its
  /// failure still needs to warn like any other. Post-teardown silence is
  /// instead enforced by [_hardStopped] (for a flush that outlives
  /// [dispose]'s own bounded wait) together with every public method's own
  /// `if (_disposed) return;` guard (for anything that would otherwise be
  /// newly *initiated* after teardown) — see the class doc.
  void _reportWarning(String message) => _onWarning(message);

  /// Flushes whatever is queued for the *old* scene (using its ID, not
  /// [sceneId], and [outgoingResumeSeconds] rather than the live resume
  /// callback — see below) and only then starts tracking [sceneId] from a
  /// clean slate — any leftover delta the old scene's flush couldn't save
  /// is discarded rather than misattributed to the new scene.
  ///
  /// [outgoingResumeSeconds] must be the *outgoing* scene's last known
  /// position, captured by the caller before it resets its own position
  /// state for the new scene. `PlaybackController.loadScene` resets
  /// `PlaybackState.position` to zero as part of building the new scene's
  /// state *before* this method's flush ever runs — if this flush read
  /// the live `resumePositionSeconds` callback instead, it would send
  /// `resumeTime: 0.0` for the scene the user just left, wiping its real
  /// resume point on the server. Pass `null` (the default) when the
  /// caller never established the outgoing scene's real position at all
  /// (e.g. it was replaced again before its own resume seek — or any
  /// position event — ever landed): with nothing queued either, this
  /// flush is then skipped outright rather than reporting a bogus zero
  /// (N4). `PlaybackController.loadScene` calls this before the new scene
  /// otherwise starts driving the engine, so no activity for the new
  /// scene can be recorded before this completes.
  Future<void> replaceScene(
    String sceneId, {
    double? outgoingResumeSeconds,
  }) async {
    if (_disposed) return;
    await _flushAwaitingFirstAttempt(
      resumeTimeOverride: outgoingResumeSeconds,
      requireKnownResumeTime: true,
    );
    _sceneId = sceneId;
    _queuedActive = Duration.zero;
    _playStartedAt = null;
    _playing = false;
    _buffering = false;
    _sceneEpoch++;
  }

  /// Cancels the periodic timer (so it can never fire — and so never call
  /// `saveSceneActivity` — again) and performs one last flush, waiting for
  /// its *entire* retry chain (unlike [flush]/[replaceScene]) since this
  /// is the last chance to save — but bounded by [disposeFlushTimeout] so
  /// a dead checkpoint endpoint can never starve
  /// `PlaybackController.dispose`'s own `_engine.dispose()` call behind
  /// it. If that bound is hit before the flush (this one, or an earlier
  /// still-detached one occupying [_flushTail] ahead of it) actually
  /// settles, [_hardStopped] is set so it can never call `saveActivity` or
  /// `onWarning` again afterwards. Safe to call more than once.
  ///
  /// [resumePositionKnown] mirrors [replaceScene]'s own
  /// `outgoingResumeSeconds` — pass `false` when the caller's live
  /// `resumePositionSeconds` callback doesn't yet reflect a real,
  /// established position for the current scene (e.g. the user navigated
  /// away before a resume seek ever landed). With nothing queued either,
  /// this skips the network call entirely rather than reporting a bogus
  /// `resumeTime: 0.0` that would wipe that scene's real resume point —
  /// the same failure mode [replaceScene] already guards against, just on
  /// this flush boundary instead.
  Future<void> dispose({bool resumePositionKnown = true}) async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    final flushSettled = Completer<void>();
    unawaited(
      _enqueueFlush(requireKnownResumeTime: !resumePositionKnown).then((_) {
        if (!flushSettled.isCompleted) flushSettled.complete();
      }),
    );

    // Deliberately a raw `Timer` here, not `_delay(disposeFlushTimeout)`:
    // `Future.any` never cancels its losing branch, so racing against
    // whatever `_delay` returns (a `Future` with no cancellation handle
    // of its own) left a real ~10s `Timer` pending for the rest of the
    // process's life on the overwhelmingly common path — the flush
    // settles well inside the budget — on *every* scene teardown (final
    // review I5). A `Timer` object gives the winning side something to
    // cancel explicitly. `_delay` itself is untouched — it's still used
    // for the retry backoff inside `_doFlush`.
    final timedOut = Completer<void>();
    final timeoutTimer = Timer(disposeFlushTimeout, () {
      if (!timedOut.isCompleted) timedOut.complete();
    });
    try {
      await Future.any([flushSettled.future, timedOut.future]);
    } catch (_) {
      // Neither branch of the race above is expected to throw, but this
      // is belt-and-braces so a bug there can never strand this dispose
      // call.
    } finally {
      timeoutTimer.cancel();
    }
    if (!flushSettled.isCompleted) {
      // The timeout won: the flush chain (this one, or an earlier
      // detached one ahead of it in `_flushTail`) is still running.
      // Silence it for good rather than letting it call `saveActivity` or
      // `onWarning` at some arbitrary later point after this controller
      // has already moved on to disposing the engine.
      _hardStopped = true;
    }
  }
}
