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
/// next N calls fail instead, and [holdNext] parks a call on a
/// [Completer] the test controls directly (for exercising an in-flight
/// request).
class _RecordingSaveActivity {
  int _failuresRemaining = 0;
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
      await sync.replaceScene('s1');

      // Never told playback is playing at all — just time passing.
      clock.advance(const Duration(seconds: 30));
      await sync.flush();

      expect(save.calls.single.playDuration, 0.0);
      addTearDown(sync.dispose);
    });

    test('buffering wall time contributes zero even while playing', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1');

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
      await sync.replaceScene('s1');

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
  });

  group('periodic tick threshold', () {
    test('a tick before 10 active seconds sends nothing', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1');
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
        await sync.replaceScene('s1');
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
      await sync.replaceScene('s1');
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
        await sync.replaceScene('s1');
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
      await sync.replaceScene('s1');
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
      await sync.replaceScene('s1');
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
      await sync.replaceScene('a');
      save.calls.clear();

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 5));
      await sync.replaceScene('b');

      expect(save.calls, hasLength(1));
      expect(save.calls.single.id, 'a');
      expect(save.calls.single.playDuration, 5.0);
      expect(sync.queuedActive, Duration.zero);
    });

    test(
      'replaceScene does not misattribute discarded time to the new scene',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('a');
        save.calls.clear();
        save.failNext(4); // exhaust all retries for scene 'a'

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 5));
        await sync.replaceScene('b');

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
      await sync.replaceScene('s1');
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
      await sync.replaceScene('s1');
      save.calls.clear();
      save.failNext(4);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();

      expect(save.calls, hasLength(4));
      expect(delay.requested, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('after four total attempts, the delta remains queued and exactly one '
        'warning is emitted', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1');
      save.calls.clear();
      save.failNext(4);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();

      expect(warnings, [activitySyncWarningMessage]);
      expect(sync.queuedActive, const Duration(seconds: 10));
    });

    test(
      'a fully-failed flush completes normally rather than throwing',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('s1');
        save.failNext(4);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));

        await expectLater(sync.flush(), completes);
      },
    );

    test('the next lifecycle flush includes the retained delta and clears it '
        'only on success', () async {
      final sync = buildSync();
      addTearDown(sync.dispose);
      await sync.replaceScene('s1');
      save.calls.clear();
      save.failNext(4);

      sync.playingChanged(true);
      clock.advance(const Duration(seconds: 10));
      await sync.flush();
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
        await sync.replaceScene('s1');
        save.failNext(4);

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));
        await sync.flush();

        // No exception escaped (the await above completing at all proves
        // this), and the delta the failed request tried to save is intact.
        expect(sync.queuedActive, const Duration(seconds: 10));
      },
    );
  });

  group('single-flight serialization', () {
    test(
      'a tick landing mid-flush queues behind it rather than racing',
      () async {
        final sync = buildSync();
        addTearDown(sync.dispose);
        await sync.replaceScene('s1');
        save.calls.clear();

        sync.playingChanged(true);
        clock.advance(const Duration(seconds: 10));
        final held = save.holdNext();
        final flushFuture = sync.flush();
        await pumpEventQueue();
        expect(save.calls, hasLength(1)); // only the first request has landed

        // More activity, then a tick that would otherwise be due immediately.
        clock.advance(const Duration(seconds: 10));
        sync.tick();
        await pumpEventQueue();

        // The tick's own flush must still be queued behind the first — no
        // second call has landed yet.
        expect(save.calls, hasLength(1));

        held.complete();
        await flushFuture;
        await pumpEventQueue();

        // Now the queued tick's flush has had its turn.
        expect(save.calls, hasLength(2));
        expect(save.calls[1].playDuration, 10.0);
      },
    );
  });

  group('teardown', () {
    test(
      'dispose cancels periodic work and emits no callbacks after teardown',
      () async {
        final sync = buildSync();
        await sync.replaceScene('s1');

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
        await sync.replaceScene('s2');
        await pumpEventQueue();

        expect(save.calls, isEmpty);
        expect(warnings, isEmpty);
      },
    );
  });
}
