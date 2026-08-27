import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/activity_sync.dart';

import '../../support/fake_clock.dart';

class _SaveCall {
  _SaveCall({
    required this.id,
    required this.resumeTime,
    required this.playDuration,
  });

  final String id;
  final double resumeTime;
  final double playDuration;
}

/// A [SaveSceneActivity] test double. Every call is recorded in [calls].
/// By default a call resolves immediately (success); [failNext] makes the
/// next N calls fail instead, [alwaysFail] makes every call fail until
/// reset (for the real-timer storm tests, where "N failures" isn't a
/// meaningful count), and [holdNext] parks a call on a [Completer] the
/// test controls directly (for exercising an in-flight request).
class _RecordingSaveActivity {
  int _failuresRemaining = 0;
  bool alwaysFail = false;
  Completer<void>? _pendingHold;

  final List<_SaveCall> calls = [];

  void failNext(int count) => _failuresRemaining += count;

  /// The next call parks on a completer this returns, instead of
  /// resolving immediately. The test completes (or fails) it directly.
  Completer<void> holdNext() {
    final completer = Completer<void>();
    _pendingHold = completer;
    return completer;
  }

  Future<void> call({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) {
    calls.add(
      _SaveCall(id: id, resumeTime: resumeTime, playDuration: playDuration),
    );
    if (_pendingHold case final Completer<void> held) {
      _pendingHold = null;
      return held.future;
    }
    if (alwaysFail) return Future<void>.error(StateError('save failed'));
    if (_failuresRemaining > 0) {
      _failuresRemaining--;
      return Future<void>.error(StateError('save failed'));
    }
    return Future<void>.value();
  }
}

void main() {
  late FakeClock clock;
  late RecordingDelay delay;
  late _RecordingSaveActivity save;
  late List<String> warnings;
  late double position;

  ActivitySync buildSync() => ActivitySync(
    resumePositionSeconds: () => position,
    saveActivity: save.call,
    onWarning: warnings.add,
    clock: clock.now,
    delay: delay.call,
  );

  setUp(() {
    clock = FakeClock();
    delay = RecordingDelay();
    save = _RecordingSaveActivity();
    warnings = [];
    position = 0;
  });

  group('accounting', () {
    test('paused wall time contributes zero', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);

      // Never told playback is playing at all — just time passing.
      clock.advance(const Duration(seconds: 30));
      await sync.flush();

      expect(save.calls.single.playDuration, 0.0);
      addTearDown(sync.dispose);
    });

    test('buffering wall time contributes zero even while playing', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);

      sync.playingChanged(true);
      sync.bufferingChanged(true);
      clock.advance(const Duration(seconds: 30));
      sync.bufferingChanged(false);
      // Immediately pause so nothing further accrues past this point.
      sync.playingChanged(false);
      await sync.flush();

      expect(save.calls.last.playDuration, 0.0);
    });

    test('exactly the active interval contributes to playDuration', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 4));
      sync.bufferingChanged(true); // stop counting
      clock.advance(const Duration(seconds: 30)); // must not count
      sync.bufferingChanged(false); // resume counting
      clock.advance(const Duration(seconds: 3));
      sync.playingChanged(false); // pause -> flush (fire-and-forget)
      await pumpEventQueue();

      expect(save.calls.single.playDuration, 7.0);
    });

    test(
      'a huge gap between accumulate calls (e.g. a suspended laptop) is '
      'capped, not billed in full (I2: DateTime.now is not monotonic)',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('s1', outgoingResumeSeconds: position);

        sync.playingChanged(true);
        // A multi-hour gap with no intervening buffering event — e.g. the
        // machine slept with the engine still reporting `playing == true`.
        clock.advance(const Duration(hours: 8));
        sync.playingChanged(false); // pause -> flush
        await pumpEventQueue();

        expect(save.calls.single.playDuration, lessThanOrEqualTo(30.0));
        expect(save.calls.single.playDuration, greaterThan(0.0));
      },
    );
  });

  group('periodic tick threshold', () {
    test('a tick before 10 active seconds sends nothing', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 9));
      sync.tick();
      await pumpEventQueue();

      expect(save.calls, isEmpty);
    });

    test(
      'a tick at 10 active seconds sends resume position plus delta',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        position = 12.5;
        await sync.replaceScene('s1', outgoingResumeSeconds: position);
        save.calls.clear();

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));
        sync.tick();
        await pumpEventQueue();

        expect(save.calls, hasLength(1));
        final call = save.calls.single;
        expect(call.id, 's1');
        expect(call.resumeTime, 12.5);
        expect(call.playDuration, 10.0);
      },
    );
  });

  group('successful checkpoint semantics', () {
    test('resets only the acknowledged delta', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();
      expect(save.calls.single.playDuration, 10.0);
      expect(sync.queuedActive, Duration.zero);

      // More activity after the successful checkpoint must be tracked
      // fresh, not lost or double-counted against the first snapshot.
      clock.advance(const Duration(seconds: 3));
      sync.playingChanged(false);
      await pumpEventQueue();

      expect(save.calls, hasLength(2));
      expect(save.calls.last.playDuration, 3.0);
    });

    test(
      'active time accrued during an in-flight request remains queued',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('s1', outgoingResumeSeconds: position);
        save.calls.clear();

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));
        final held = save.holdNext();
        final flushFuture = sync.flush();
        await pumpEventQueue();

        // The request is in flight; more activity accrues while it waits.
        clock.advance(const Duration(seconds: 4));

        held.complete();
        await flushFuture;

        expect(save.calls, hasLength(1));
        expect(save.calls.single.playDuration, 10.0);

        // The 4 seconds that accrued mid-flight were never part of that
        // request's snapshot. Proof they survive: a subsequent pause still
        // reports exactly that 4 seconds, not zero and not 14 (the whole
        // in-flight request's snapshot was already acknowledged above).
        sync.playingChanged(false);
        await pumpEventQueue();
        expect(save.calls, hasLength(2));
        expect(save.calls.last.playDuration, 4.0);
      },
    );
  });

  group('lifecycle flush boundaries', () {
    test('pause flushes', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 2));
      sync.playingChanged(false);
      await pumpEventQueue();

      expect(save.calls, hasLength(1));
      expect(save.calls.single.playDuration, 2.0);
    });

    test('an explicit flush (the controller\'s seek boundary) sends', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 2));
      await sync.flush();

      expect(save.calls, hasLength(1));
      expect(save.calls.single.playDuration, 2.0);
    });

    test('scene replacement flushes the old scene under its own ID', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('a', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 5));
      await sync.replaceScene('b', outgoingResumeSeconds: position);

      expect(save.calls, hasLength(1));
      expect(save.calls.single.id, 'a');
      expect(save.calls.single.playDuration, 5.0);
      expect(sync.queuedActive, Duration.zero);
    });

    test(
      'replaceScene sends the explicitly provided outgoing resume position, '
      'never the live resumePositionSeconds callback (C1: a caller like '
      'PlaybackController.loadScene may have already reset its own live '
      'position for the *new* scene by the time this flush actually runs)',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        position = 0;
        await sync.replaceScene('a', outgoingResumeSeconds: position);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 5));
        // Simulate the caller having already moved its own live position
        // on to the incoming scene *before* this flush for the outgoing
        // scene ('a') actually runs.
        position = 42;
        await sync.replaceScene('b', outgoingResumeSeconds: 1200);

        expect(save.calls.last.id, 'a');
        expect(save.calls.last.resumeTime, 1200.0);
        expect(save.calls.last.resumeTime, isNot(42.0));
      },
    );

    test(
      'replaceScene does not misattribute discarded time to the new scene',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('a', outgoingResumeSeconds: position);
        save.calls.clear();
        save.failNext(4); // exhaust all retries for scene 'a'

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 5));
        await sync.replaceScene('b', outgoingResumeSeconds: position);
        // replaceScene only awaits the first attempt (C3); the remaining
        // retries (and the resulting warning) settle in the background.
        await pumpEventQueue();

        expect(warnings, hasLength(1));
        // 'a's failed delta must not resurface attributed to 'b'. replaceScene
        // resets the playing flag too, so a fresh true->false transition is
        // needed to generate scene 'b's own activity.
        save.calls.clear();
        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 1));
        sync.playingChanged(false);
        await pumpEventQueue();
        expect(save.calls.single.id, 'b');
        expect(save.calls.single.playDuration, 1.0);
      },
    );

    test('dispose flushes once', () async {
      final sync = buildSync();
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 6));
      await sync.dispose();

      expect(save.calls, hasLength(1));
      expect(save.calls.single.playDuration, 6.0);

      // Idempotent.
      await sync.dispose();
      expect(save.calls, hasLength(1));
    });
  });

  group('retries', () {
    test('failed attempts occur immediately, then after 1s, 2s, 4s', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();
      save.failNext(4);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();
      // flush() only awaits the first attempt (C3); let the remaining
      // three retries settle in the background before asserting on them.
      await pumpEventQueue();

      expect(save.calls, hasLength(4));
      expect(delay.requested, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('flush resolves once the first attempt settles, not the full retry '
        'chain (C3: a user-facing seek or scene load must not stall behind '
        'up to 7 seconds of retry backoff)', () async {
      // A delay that never resolves on its own — if flush() waited for
      // the retry chain (which needs this to resolve before a second
      // attempt can even happen), the `await sync.flush()` below would
      // hang forever. Completing at all is the proof it doesn't; the
      // test releases this itself afterwards so its own teardown can
      // proceed normally.
      final heldDelay = Completer<void>();
      var delayRequested = false;
      final sync = ActivitySync(
        resumePositionSeconds: () => position,
        saveActivity: save.call,
        onWarning: warnings.add,
        clock: clock.now,
        delay: (duration) {
          delayRequested = true;
          return heldDelay.future;
        },
      );
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();
      save.failNext(1); // only the first attempt fails

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();

      // Only the first attempt has run, and flush() did not need the
      // (still-pending) retry delay to resolve in order to return.
      expect(save.calls, hasLength(1));
      expect(delayRequested, isTrue);

      // Release the backgrounded retry (which now succeeds, since only
      // one failure was configured) so dispose can proceed cleanly.
      heldDelay.complete();
      await pumpEventQueue();
      expect(save.calls, hasLength(2));
      await sync.dispose();
    });

    test('after four total attempts, the delta remains queued and exactly one '
        'warning is emitted', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();
      save.failNext(4);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();
      await pumpEventQueue(); // let the backgrounded retries run to exhaustion

      expect(warnings, [activitySyncWarningMessage]);
      expect(sync.queuedActive, const Duration(seconds: 10));
    });

    test(
      'a fully-failed flush completes normally rather than throwing',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('s1', outgoingResumeSeconds: position);
        save.failNext(4);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));

        await expectLater(sync.flush(), completes);
        await pumpEventQueue(); // the backgrounded retries must not throw either
      },
    );

    test('the next lifecycle flush includes the retained delta and clears it '
        'only on success', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();
      save.failNext(4);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();
      await pumpEventQueue(); // let the backgrounded retries run to exhaustion
      expect(warnings, hasLength(1));
      expect(sync.queuedActive, const Duration(seconds: 10));

      // A further 2 seconds of play, then pause: the retained 10s must
      // still be included, and clears only because this one succeeds.
      clock.advance(const Duration(seconds: 2));
      save.calls.clear();
      sync.playingChanged(false);
      await pumpEventQueue();

      expect(save.calls, hasLength(1));
      expect(save.calls.single.playDuration, 12.0);
      expect(sync.queuedActive, Duration.zero);
      expect(warnings, hasLength(1)); // still exactly one, not a second
    });

    test(
      'a sync failure leaves the queued delta untouched and never throws',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('s1', outgoingResumeSeconds: position);
        save.failNext(4);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));
        await sync.flush();
        await pumpEventQueue(); // let the backgrounded retries run to exhaustion

        // No exception escaped (the await above completing at all proves
        // this), and the delta the failed request tried to save is intact.
        expect(sync.queuedActive, const Duration(seconds: 10));
      },
    );
  });

  group('single-flight serialization', () {
    test('a tick landing while a flush is pending does not enqueue a duplicate '
        '(C2 leg 1: an unguarded tick would otherwise grow the backlog '
        'without bound whenever the checkpoint endpoint is down)', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1', outgoingResumeSeconds: position);
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      final held = save.holdNext();
      final flushFuture = sync.flush();
      await pumpEventQueue();
      expect(save.calls, hasLength(1)); // only the first request has landed

      // More activity, then ticks that would otherwise be due immediately
      // — must not enqueue additional flushes while one is still pending.
      clock.advance(const Duration(seconds: 10));
      sync.tick();
      sync.tick();
      sync.tick();
      await pumpEventQueue();
      expect(save.calls, hasLength(1)); // still just the one in-flight call

      held.complete();
      await flushFuture;
      await pumpEventQueue();

      // Resolving the pending flush alone must not retroactively enqueue
      // a second one — only a fresh tick (or other boundary) can.
      expect(save.calls, hasLength(1));

      sync.tick();
      await pumpEventQueue();

      // Now that the first has resolved, a fresh tick correctly captures
      // exactly the 10s that elapsed since the first flush's own
      // accumulate step re-marked the active span.
      expect(save.calls, hasLength(2));
      expect(save.calls[1].playDuration, 10.0);
    });
  });

  group('dispose is bounded (C2 leg 3)', () {
    test(
      'dispose does not wait forever for a checkpoint that never resolves',
      () async {
        final sync = buildSync();
        await sync.replaceScene('s1', outgoingResumeSeconds: position);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 6));
        save.holdNext(); // never completed — a checkpoint that hangs forever

        // The outer timeout is a safety net only: if disposeFlushTimeout's
        // race were broken, this would hang instead of failing fast, so a
        // generous real bound here just prevents that from wedging the
        // whole suite. On the passing path this resolves almost instantly
        // — the injected delay (RecordingDelay) settles the race, not a
        // real wait.
        await sync.dispose().timeout(const Duration(seconds: 5));

        expect(delay.requested, contains(disposeFlushTimeout));
      },
    );
  });

  group('the real periodic timer (C2 legs 2/3, I3: fakeAsync is not available '
      'in this project, so cancellation is proven with short, deliberate '
      'real waits rather than tick() called directly)', () {
    test('fires while active and stops for good once dispose cancels it — '
        'not just guarded against by _disposed', () async {
      save.alwaysFail = true; // keep queuedActive permanently over threshold
      final sync = ActivitySync(
        resumePositionSeconds: () => position,
        saveActivity: save.call,
        onWarning: warnings.add,
        clock: clock.now,
        delay: delay.call,
        tickInterval: const Duration(milliseconds: 5),
      );
      await sync.replaceScene('s1', outgoingResumeSeconds: position);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10)); // cross the threshold

      await Future<void>.delayed(const Duration(milliseconds: 100));
      final callsBeforeDispose = save.calls.length;
      expect(callsBeforeDispose, greaterThan(0));

      await sync.dispose();
      // With every delay in this test instantly-resolving (including
      // disposeFlushTimeout's own race — see disposeFlushTimeout's
      // doc), a flush that was already mid-chain when dispose() ran
      // can "lose" that race on hop-count alone and still be settling
      // as a harmless background continuation (warnings are already
      // suppressed post-dispose — see _reportWarning) even though
      // dispose() itself has returned. Draining the microtask queue
      // (no real time, unlike the timer waits around it) lets that
      // settle before taking the snapshot the real assertion below
      // depends on: no *further* calls once the real timer is gone.
      await pumpEventQueue();
      final callsAtDispose = save.calls.length;

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(save.calls.length, callsAtDispose);
    });

    test(
      'stops once playback goes inactive, not only on dispose (C2 leg 2: '
      'without this, a paused scene with a down checkpoint endpoint '
      'keeps retrying — and re-warning — in the background forever)',
      () async {
        save.alwaysFail = true; // keep queuedActive permanently over threshold
        final sync = ActivitySync(
          resumePositionSeconds: () => position,
          saveActivity: save.call,
          onWarning: warnings.add,
          clock: clock.now,
          delay: delay.call,
          tickInterval: const Duration(milliseconds: 5),
        );
        addTearDown(sync.dispose);
        await sync.replaceScene('s1', outgoingResumeSeconds: position);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(save.calls, isNotEmpty);

        sync.playingChanged(false); // pause -> stops the real timer
        await pumpEventQueue();
        final callsAtPause = save.calls.length;

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(save.calls.length, callsAtPause);
      },
    );
  });

  group('teardown', () {
    test(
      'dispose cancels periodic work and emits no callbacks after teardown',
      () async {
        final sync = buildSync();
        await sync.replaceScene('s1', outgoingResumeSeconds: position);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 6));
        await sync.dispose();
        save.calls.clear();
        warnings.clear();

        // Simulate every input a leaked timer or stream subscription could
        // still deliver post-teardown: none of them may reach the network
        // or emit a warning.
        sync.tick();
        sync.playingChanged(false);
        sync.bufferingChanged(true);
        await sync.flush();
        await sync.replaceScene('s2', outgoingResumeSeconds: position);
        await pumpEventQueue();

        expect(save.calls, isEmpty);
        expect(warnings, isEmpty);
      },
    );
  });
}
