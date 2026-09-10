import 'dart:async';

import 'package:flutter/widgets.dart' show Key, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/services/socks_forward_proxy.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_stream.dart';
import 'package:stash_player_flutter/features/player/activity_sync.dart';
import 'package:stash_player_flutter/features/player/load_diagnostics.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_engine.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/services/authenticated_url.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fakes.dart';

const _config = ConnectionConfig(
  serverUrl: 'https://stash.test',
  apiKey: 'secret-key',
);

Scene _sceneWith({
  String id = 's1',
  String stream = 'stream.mp4',
  double? resumeTime,
  double? duration,
  bool withFile = true,
  List<SceneStream> streams = const [],
}) => Scene(
  id: id,
  paths: ScenePaths(stream: stream),
  resumeTime: resumeTime,
  files: withFile ? [SceneFile(duration: duration)] : const [],
  streams: streams,
);

/// Builds a [PlaybackController] wired to a fully-controllable
/// [ActivitySync] instead of a real one: [activityDelay] defaults to a
/// fake that never actually waits (so a test exercising a failing
/// [saveActivity]'s full 1s/2s/4s retry schedule costs nothing in real
/// test run time — only `activity_sync_test.dart` needs to assert the
/// schedule itself), while [saveActivity]/[activityClock]/[onActivityWarning]
/// default to the same no-ops [ActivitySync] itself falls back to.
PlaybackController _buildController({
  required PlaybackEngine engine,
  ConnectionConfig config = _config,
  SaveSceneActivity? saveActivity,
  DateTime Function()? activityClock,
  Future<void> Function(Duration)? activityDelay,
  void Function(String message)? onActivityWarning,
  Future<bool> Function(bool fullscreen)? setFullscreenPlatform,
  void Function(String message)? log,
  StallTimerFactory? stallTimerFactory,
}) {
  final controller = PlaybackController(
    engine: engine,
    resolveConnection: () async => config,
    setFullscreenPlatform: setFullscreenPlatform ?? (value) async => true,
    log: log,
    stallTimerFactory: stallTimerFactory,
    activitySyncFactory: ({required resumePositionSeconds}) => ActivitySync(
      resumePositionSeconds: resumePositionSeconds,
      saveActivity: saveActivity,
      clock: activityClock,
      delay: activityDelay ?? (_) async {},
      onWarning: onActivityWarning,
    ),
  );
  // Every controller built through this helper is disposed at the end of
  // its own test, regardless of whether the test body disposes it itself
  // (`PlaybackController.dispose` is idempotent). Undisposed controllers
  // that reach active playback start a genuine `Timer.periodic` against
  // the real 1s production `tickInterval` and a real `DateTime.now`
  // clock (no `activityClock`/`tickInterval` override here) — left
  // running, that timer keeps ticking into later, unrelated tests for
  // the rest of the suite's real wall-clock runtime, a live flake vector
  // rather than a benign leak (final review §3b).
  addTearDown(controller.dispose);
  return controller;
}

/// Records every `onData` callback ever registered via [listen], in
/// order, instead of delivering through a real broadcast controller —
/// and hands back a subscription whose [StreamSubscription.cancel] is a
/// deliberate no-op.
///
/// Exists to test [PlaybackController]'s per-generation guards on its
/// bound stream callbacks (I4). A plain `StreamController.broadcast()`
/// cancels a subscription's delivery *synchronously* the moment
/// `.cancel()` is called — verified directly against the Dart SDK
/// (`lib/async/stream_impl.dart`: `cancel()` sets `_STATE_CANCELED` and
/// flips the pending-events state so an already-scheduled delivery
/// microtask early-returns; `_add` also short-circuits on
/// `_isCanceled`), and empirically (`controller.add(x); sub.cancel();`
/// with no `await` in between still leaves the listener never invoked,
/// even racing a `scheduleMicrotask` in between, and even when the
/// controller's `onCancel` callback is deliberately left pending
/// forever). That guarantee holds for *every* [PlaybackEngine]
/// implementation that exists in this codebase today — not just
/// `FakePlaybackEngine`, but the real `MediaKitPlaybackEngine` too: it
/// doesn't forward `package:media_kit`'s own streams directly, it
/// re-emits through its own five `StreamController.broadcast()`s (see
/// `media_kit_playback_engine.dart`), so `PlaybackController` is always
/// cancelling a subscription to a plain Dart broadcast controller,
/// regardless of which concrete engine backs it. There is, correctly,
/// no real race to reproduce against either one.
///
/// So this exists for a different reason than "simulate a race that can
/// happen": the abstract [PlaybackEngine] *contract* doesn't require
/// synchronous-cancel semantics — nothing stops a future implementation
/// from delivering a queued event after a Dart-side `cancel()`, e.g. one
/// that doesn't route through a plain `StreamController` at all. This
/// double stands in for that hypothetical, contractually-permitted
/// implementation so the generation guard's *closure behavior* — does it
/// correctly ignore a stale-generation callback if one ever fires — is
/// pinned by a real, passing/failing test, rather than left as an
/// unverified assumption resting on every engine's cancellation being
/// well-behaved.
class _RecordingStream<T> extends Stream<T> {
  final List<void Function(T)> callbacks = [];

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (onData != null) callbacks.add(onData);
    return _NoopSubscription<T>();
  }
}

class _NoopSubscription<T> implements StreamSubscription<T> {
  @override
  Future<void> cancel() async {}

  @override
  void onData(void Function(T data)? handleData) {}

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Completer<E>().future;
}

/// A [PlaybackEngine] wrapping a [FakePlaybackEngine] whose five streams
/// are [_RecordingStream]s — see that class for why. Every command
/// forwards to [inner] unchanged.
class _RecordingEngine implements PlaybackEngine {
  _RecordingEngine(this.inner);

  final FakePlaybackEngine inner;

  final playingRecorder = _RecordingStream<bool>();
  final bufferingRecorder = _RecordingStream<bool>();
  final bufferedRecorder = _RecordingStream<Duration>();
  final positionRecorder = _RecordingStream<Duration>();
  final durationRecorder = _RecordingStream<Duration>();
  final errorsRecorder = _RecordingStream<String>();

  @override
  Stream<bool> get playing => playingRecorder;

  @override
  Stream<bool> get buffering => bufferingRecorder;

  @override
  Stream<Duration> get buffered => bufferedRecorder;

  @override
  Stream<Duration> get position => positionRecorder;

  @override
  Stream<Duration> get duration => durationRecorder;

  @override
  Stream<String> get errors => errorsRecorder;

  @override
  Widget buildVideoSurface({Key? key}) => inner.buildVideoSurface(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false, Duration? startAt}) =>
      inner.open(uri, play: play, startAt: startAt);

  @override
  Future<void> play() => inner.play();

  @override
  Future<void> pause() => inner.pause();

  @override
  Future<void> seek(Duration position) => inner.seek(position);

  @override
  Future<void> setVolume(double zeroToOne) => inner.setVolume(zeroToOne);

  @override
  Future<void> setMuted(bool muted) => inner.setMuted(muted);

  @override
  Future<void> dispose() => inner.dispose();
}

/// A [PlaybackEngine] wrapping a [FakePlaybackEngine] whose command
/// methods can be individually configured to throw — used to test that a
/// thrown engine error surfaces into `state.failure` rather than
/// escaping as an unhandled `Future` error (I5/I6).
class _FaultyEngine implements PlaybackEngine {
  _FaultyEngine(
    this.inner, {
    this.seekThrows = false,
    this.volumeThrows = false,
    this.mutedThrows = false,
    this.pauseThrows = false,
    this.openThrows = false,
    this.errorMessage,
  });

  final FakePlaybackEngine inner;
  final bool seekThrows;
  final bool volumeThrows;
  final bool mutedThrows;
  final bool pauseThrows;
  final bool openThrows;

  /// Overrides every throw site's default generic message below — lets a
  /// test embed a literal secret (e.g. a real API key) into the thrown
  /// error to verify it gets redacted, rather than only ever exercising
  /// the pattern-based `ApiKey: ...` regex (final review I6).
  final String? errorMessage;

  @override
  Stream<bool> get playing => inner.playing;

  @override
  Stream<bool> get buffering => inner.buffering;

  @override
  Stream<Duration> get buffered => inner.buffered;

  @override
  Stream<Duration> get position => inner.position;

  @override
  Stream<Duration> get duration => inner.duration;

  @override
  Stream<String> get errors => inner.errors;

  @override
  Widget buildVideoSurface({Key? key}) => inner.buildVideoSurface(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false, Duration? startAt}) async {
    if (openThrows) throw StateError(errorMessage ?? 'engine open() failed');
    return inner.open(uri, play: play, startAt: startAt);
  }

  @override
  Future<void> play() => inner.play();

  @override
  Future<void> pause() async {
    if (pauseThrows) throw StateError(errorMessage ?? 'engine pause() failed');
    return inner.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (seekThrows) throw StateError(errorMessage ?? 'engine seek() failed');
    return inner.seek(position);
  }

  @override
  Future<void> setVolume(double zeroToOne) async {
    if (volumeThrows) {
      throw StateError(errorMessage ?? 'engine setVolume() failed');
    }
    return inner.setVolume(zeroToOne);
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (mutedThrows) {
      throw StateError(errorMessage ?? 'engine setMuted() failed');
    }
    return inner.setMuted(muted);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

/// Records every command *invocation* by name, independent of whether
/// [inner] would itself throw for it.
///
/// This is what actually makes a missing/removed `_disposed` guard on a
/// `PlaybackController` command method observable (fix round 2, item 1):
/// `FakePlaybackEngine` checks its own disposed flag and throws *before*
/// ever appending to `commands`, so a post-dispose call that reaches it
/// leaves no trace there for a test to see — and `_runEngineCommand`'s
/// catch swallows that thrown `StateError` just as readily as any other
/// engine failure, so "the call didn't throw" is no longer a reliable
/// signal either. Counting invocations directly, ahead of anything
/// [inner] itself might do, sidesteps both.
/// Holds `open` pending on a [Completer] so a test can observe
/// `PlaybackController`'s state *during* a load stage rather than only
/// after the whole chain has finished. Nothing else about the load can be
/// paused from outside: every other stage boundary is an `await` on a
/// future the controller itself creates.
class _GatedEngine implements PlaybackEngine {
  _GatedEngine(this.inner);

  final FakePlaybackEngine inner;
  final Completer<void> openGate = Completer<void>();

  @override
  Stream<bool> get playing => inner.playing;

  @override
  Stream<bool> get buffering => inner.buffering;

  @override
  Stream<Duration> get buffered => inner.buffered;

  @override
  Stream<Duration> get position => inner.position;

  @override
  Stream<Duration> get duration => inner.duration;

  @override
  Stream<String> get errors => inner.errors;

  @override
  Widget buildVideoSurface({Key? key}) => inner.buildVideoSurface(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false, Duration? startAt}) async {
    await openGate.future;
    await inner.open(uri, play: play, startAt: startAt);
  }

  @override
  Future<void> play() => inner.play();

  @override
  Future<void> pause() => inner.pause();

  @override
  Future<void> seek(Duration position) => inner.seek(position);

  @override
  Future<void> setVolume(double zeroToOne) => inner.setVolume(zeroToOne);

  @override
  Future<void> setMuted(bool muted) => inner.setMuted(muted);

  @override
  Future<void> dispose() => inner.dispose();
}

/// A [Timer] a test fires by hand. Keeps the eight-second stall deadline
/// out of real time, and keeps the test binding's "a Timer is still
/// pending" check satisfied, since nothing is ever actually scheduled.
class _ManualTimer implements Timer {
  _ManualTimer(this._onFire);

  final void Function() _onFire;
  bool _cancelled = false;

  void fire() {
    if (_cancelled) return;
    _cancelled = true;
    _onFire();
  }

  @override
  void cancel() => _cancelled = true;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;
}

/// Hands out [_ManualTimer]s and remembers the most recent one.
class _ManualTimers {
  final List<_ManualTimer> created = [];

  Timer call(Duration duration, void Function() callback) {
    final timer = _ManualTimer(callback);
    created.add(timer);
    return timer;
  }

  _ManualTimer get latest => created.last;
}

class _CallCountingEngine implements PlaybackEngine {
  _CallCountingEngine(this.inner);

  final FakePlaybackEngine inner;
  final List<String> invocations = [];

  @override
  Stream<bool> get playing => inner.playing;

  @override
  Stream<bool> get buffering => inner.buffering;

  @override
  Stream<Duration> get buffered => inner.buffered;

  @override
  Stream<Duration> get position => inner.position;

  @override
  Stream<Duration> get duration => inner.duration;

  @override
  Stream<String> get errors => inner.errors;

  @override
  Widget buildVideoSurface({Key? key}) => inner.buildVideoSurface(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false, Duration? startAt}) {
    invocations.add('open');
    return inner.open(uri, play: play, startAt: startAt);
  }

  @override
  Future<void> play() {
    invocations.add('play');
    return inner.play();
  }

  @override
  Future<void> pause() {
    invocations.add('pause');
    return inner.pause();
  }

  @override
  Future<void> seek(Duration position) {
    invocations.add('seek');
    return inner.seek(position);
  }

  @override
  Future<void> setVolume(double zeroToOne) {
    invocations.add('setVolume');
    return inner.setVolume(zeroToOne);
  }

  @override
  Future<void> setMuted(bool muted) {
    invocations.add('setMuted');
    return inner.setMuted(muted);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

void main() {
  group('loadScene resume rule', () {
    test('null resume does not seek', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(duration: 2000));

      expect(engine.commands.whereType<OpenCommand>().single.startAt, isNull);
      expect(controller.state.phase, PlaybackPhase.ready);
    });

    test('zero resume does not seek', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 0, duration: 2000));

      expect(engine.commands.whereType<OpenCommand>().single.startAt, isNull);
    });

    test('a middle resume opens at that exact position', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 500, duration: 2000));

      expect(
        engine.commands.whereType<OpenCommand>().single.startAt,
        const Duration(seconds: 500),
      );
    });

    test('a resume within the final 10 seconds restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 92, duration: 100));

      expect(engine.commands.whereType<OpenCommand>().single.startAt, isNull);
    });

    test('a resume at/above 97 percent restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 970, duration: 1000));

      expect(engine.commands.whereType<OpenCommand>().single.startAt, isNull);
    });

    test('a resume beyond the known duration restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 150, duration: 100));

      expect(engine.commands.whereType<OpenCommand>().single.startAt, isNull);
    });

    test('a positive resume with unknown duration still opens there', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 500, withFile: false));

      expect(
        engine.commands.whereType<OpenCommand>().single.startAt,
        const Duration(seconds: 500),
      );
    });
  });

  group('loadScene ordering and authentication', () {
    test('the stream URL is authenticated, and the resume position rides on '
        'the open rather than following it as a seek', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(
        _sceneWith(stream: 'video/stream.mp4', resumeTime: 500, duration: 2000),
      );

      expect(engine.commands, hasLength(2));
      final open = engine.commands[0] as OpenCommand;
      expect(
        open.uri,
        authenticatedUrl(
          Uri.parse(_config.serverUrl),
          'video/stream.mp4',
          _config.apiKey,
        ),
      );
      expect(open.play, isFalse);
      expect(open.startAt, const Duration(seconds: 500));
      expect(engine.commands[1], isA<PlayCommand>());
    });

    test(
      'a scene with no stream URL fails without opening the engine',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);

        await controller.loadScene(
          Scene(id: 'no-stream', paths: const ScenePaths()),
        );

        expect(engine.commands, isEmpty);
        expect(controller.state.phase, PlaybackPhase.failed);
        expect(controller.state.failure, isNotNull);
      },
    );

    test(
      'an error resolving the connection lands in failed, redacted',
      () async {
        final engine = FakePlaybackEngine();
        final controller = PlaybackController(
          engine: engine,
          resolveConnection: () => Future<ConnectionConfig>.error(
            Exception('token ApiKey: super-secret failed'),
          ),
          setFullscreenPlatform: (value) async => true,
        );
        addTearDown(controller.dispose);

        await controller.loadScene(_sceneWith());

        expect(controller.state.phase, PlaybackPhase.failed);
        expect(controller.state.failure, isNot(contains('super-secret')));
      },
    );

    test('redacts the real API key from an error thrown after the connection '
        'already resolved (final review I6 — `config` must not fall out of '
        'scope by the time the catch runs)', () async {
      final engine = _FaultyEngine(
        FakePlaybackEngine(),
        openThrows: true,
        errorMessage: 'engine open() failed: key=${_config.apiKey}',
      );
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith());

      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.state.failure, isNot(contains(_config.apiKey)));
    });
  });

  group('seekAbsolute', () {
    test('clamps a negative target to zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 2000));
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: -20));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        Duration.zero,
      );
      expect(controller.state.position, Duration.zero);
    });

    test('clamps to the known duration', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      engine.emitDuration(const Duration(seconds: 2000));
      // The duration stream delivers asynchronously (a broadcast
      // controller schedules delivery as a microtask) — let it land
      // before relying on `state.duration` below.
      await pumpEventQueue();
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: 5000));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 2000),
      );
    });

    test('does not clamp the upper bound while duration is unknown', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: 999999));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 999999),
      );
    });

    test('flushes activity strictly before issuing the engine seek', () async {
      final engine = FakePlaybackEngine();
      var flushCalls = 0;
      final controller = _buildController(
        engine: engine,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async {
              flushCalls++;
              expect(
                engine.commands.whereType<SeekCommand>(),
                isEmpty,
                reason: 'flush must run before the engine seek is issued',
              );
            },
      );
      await controller.loadScene(_sceneWith(duration: 2000));

      await controller.seekAbsolute(const Duration(seconds: 30));

      expect(flushCalls, 1);
      expect(engine.commands.whereType<SeekCommand>(), hasLength(1));
    });

    test('omitting activity-sync overrides defaults to a no-op', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 2000));

      await controller.seekAbsolute(const Duration(seconds: 30));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 30),
      );
    });

    test(
      'a throwing flush does not abort the engine seek, and does not '
      'escape as an unhandled error (I5) — it still reports a warning',
      () async {
        final engine = FakePlaybackEngine();
        final warnings = <String>[];
        final controller = _buildController(
          engine: engine,
          saveActivity:
              ({
                required id,
                required resumeTime,
                required playDuration,
              }) async => throw StateError('network down'),
          onActivityWarning: warnings.add,
        );
        await controller.loadScene(_sceneWith(duration: 2000));

        await controller.seekAbsolute(const Duration(seconds: 30));

        expect(
          engine.commands.whereType<SeekCommand>().single.position,
          const Duration(seconds: 30),
        );
        expect(controller.state.position, const Duration(seconds: 30));
        // flush() only awaits the first attempt (C3); let the backgrounded
        // retries run to exhaustion before checking the resulting warning.
        await pumpEventQueue();
        expect(warnings, [activitySyncWarningMessage]);
      },
    );

    test('a throwing engine seek surfaces as state.controlFailure rather '
        'than an unhandled error (I6), without touching phase/failure '
        '(fix round 1, item 5: a control-command failure is not the same '
        'as an unplayable scene)', () async {
      final inner = FakePlaybackEngine();
      final engine = _FaultyEngine(inner, seekThrows: true);
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 2000));

      await controller.seekAbsolute(const Duration(seconds: 30));

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.failure, isNull);
      expect(controller.state.controlFailure, isNotNull);
      expect(controller.state.controlFailureSequence, 1);
      expect(controller.state.position, isNot(const Duration(seconds: 30)));
    });

    test(
      'a retrying activity sync does not stall the seek behind its backoff '
      '(C3: the checkpoint is best-effort and must not gate a user action)',
      () async {
        final engine = FakePlaybackEngine();
        // A retry delay that never resolves on its own: if seekAbsolute
        // ever waited for the full retry chain (rather than just the
        // first failed attempt), this would hang forever instead of
        // completing. Completing at all is the proof.
        final heldRetryDelay = Completer<void>();
        final controller = _buildController(
          engine: engine,
          saveActivity:
              ({
                required id,
                required resumeTime,
                required playDuration,
              }) async => throw StateError('activity endpoint down'),
          activityDelay: (_) => heldRetryDelay.future,
        );
        await controller.loadScene(_sceneWith(duration: 2000));

        await controller.seekAbsolute(const Duration(seconds: 30));

        expect(
          engine.commands.whereType<SeekCommand>().single.position,
          const Duration(seconds: 30),
        );
        expect(controller.state.position, const Duration(seconds: 30));

        heldRetryDelay.complete(); // let the backgrounded retry settle
      },
    );
  });

  group('seekRelative', () {
    test(
      'accumulates from the controller\'s accepted position, not a stale engine query',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith(duration: 2000));
        engine.commands.clear();

        await controller.seekRelative(const Duration(seconds: 10));
        await controller.seekRelative(const Duration(seconds: 10));

        final positions = engine.commands
            .whereType<SeekCommand>()
            .map((c) => c.position)
            .toList();
        expect(positions, [
          const Duration(seconds: 10),
          const Duration(seconds: 20),
        ]);
      },
    );

    test('clamps at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 2000));
      engine.commands.clear();

      await controller.seekRelative(const Duration(seconds: -5));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        Duration.zero,
      );
    });

    test('clamps at the known duration', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(resumeTime: 195, duration: 199));
      // resumeTime 195/199 is within the final-10s window, so it restarts
      // at zero; seek explicitly to a known position near the end first.
      await controller.seekAbsolute(const Duration(seconds: 195));
      engine.emitDuration(const Duration(seconds: 199));
      await pumpEventQueue();
      engine.commands.clear();

      await controller.seekRelative(const Duration(seconds: 10));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 199),
      );
    });
  });

  group('handleAction: seek magnitudes', () {
    // Restores the coverage `player_shortcuts_test.dart`'s deleted
    // key-dispatch loop used to provide for these six arms (final review
    // re-review): that loop routed through the since-deleted
    // `dispatchPlayerKeyEvent`, but the magnitudes it asserted
    // (`playback_controller.dart`'s `handleAction`) are still live and
    // still worth pinning independent of any key-binding layer.
    const cases = <(PlayerAction, Duration)>[
      (PlayerAction.seekBackward5, Duration(seconds: -5)),
      (PlayerAction.seekForward5, Duration(seconds: 5)),
      (PlayerAction.seekBackward10, Duration(seconds: -10)),
      (PlayerAction.seekForward10, Duration(seconds: 10)),
      (PlayerAction.seekBackward60, Duration(seconds: -60)),
      (PlayerAction.seekForward60, Duration(seconds: 60)),
    ];

    for (final (action, delta) in cases) {
      test(
        '${action.name} seeks by exactly $delta from the current position',
        () async {
          final engine = FakePlaybackEngine();
          final controller = _buildController(engine: engine);
          await controller.loadScene(_sceneWith(duration: 1000));
          // Start from a non-zero position: seekRelative clamps at zero,
          // so starting there would make every backward case
          // indistinguishable from a clamp rather than a pinned
          // magnitude.
          await controller.seekAbsolute(const Duration(seconds: 100));
          engine.commands.clear();

          await controller.handleAction(action);

          expect(
            engine.commands.whereType<SeekCommand>().single.position,
            const Duration(seconds: 100) + delta,
          );
        },
      );
    }
  });

  group('handleAction: Home/End', () {
    test('seekToStart seeks to zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(resumeTime: 500, duration: 2000));
      engine.commands.clear();

      await controller.handleAction(PlayerAction.seekToStart);

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        Duration.zero,
      );
    });

    test('seekToEnd seeks to the known duration', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      engine.emitDuration(const Duration(seconds: 2000));
      await pumpEventQueue();
      engine.commands.clear();

      await controller.handleAction(PlayerAction.seekToEnd);

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 2000),
      );
    });

    test('seekToEnd is a no-op while duration is unknown, rather than seeking '
        'to zero and then wiping the resume point (final review I7)', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      // No `engine.emitDuration(...)` — `state.duration` stays
      // `Duration.zero`, the documented "unknown" sentinel.
      await controller.loadScene(_sceneWith());
      engine.commands.clear();

      await controller.handleAction(PlayerAction.seekToEnd);

      expect(engine.commands, isEmpty);
      expect(controller.state.position, Duration.zero);
    });
  });

  group('playPause', () {
    test('plays when paused, pauses when playing', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      engine.commands.clear();

      await controller.playPause();
      expect(engine.commands.single, isA<PlayCommand>());

      engine.emitPlaying(true);
      await pumpEventQueue();
      engine.commands.clear();

      await controller.playPause();
      expect(engine.commands.single, isA<PauseCommand>());
    });

    test('a throwing engine pause() surfaces as state.controlFailure rather '
        'than an unhandled error (I6), without touching phase/failure — the '
        'scene is genuinely ready and playing throughout, exactly the '
        '"otherwise fully working scene" scenario 3 is about', () async {
      final inner = FakePlaybackEngine();
      final engine = _FaultyEngine(inner, pauseThrows: true);
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      expect(controller.state.phase, PlaybackPhase.ready);
      inner.emitPlaying(true);
      await pumpEventQueue();
      expect(controller.state.playing, isTrue);

      await controller.playPause();

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.failure, isNull);
      expect(controller.state.controlFailure, isNotNull);
      expect(controller.state.controlFailureSequence, 1);
    });

    test('two consecutive control-command failures each bump '
        'controlFailureSequence — a scene is never "stuck" absorbing every '
        'failure after the first the way a terminal phase would (fix round '
        '1, item 5, scenario 2)', () async {
      final inner = FakePlaybackEngine();
      final engine = _FaultyEngine(inner, pauseThrows: true);
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      inner.emitPlaying(true);
      await pumpEventQueue();

      await controller.playPause();
      expect(controller.state.controlFailureSequence, 1);
      expect(controller.state.phase, PlaybackPhase.ready);

      // A second, independent failure — with the old terminal-phase
      // design this second occurrence would have been silently
      // absorbed (phase was already `failed`, so nothing "newly"
      // failed). The sequence counter still increments. `_state.playing`
      // is still `true` (the failed `pause()` call never actually
      // stopped playback), so this second attempt again resolves to
      // `pause()`, which fails again.
      await controller.playPause();
      expect(controller.state.controlFailureSequence, 2);
      expect(controller.state.phase, PlaybackPhase.ready);
    });
  });

  group('volume', () {
    test('setVolume clamps to [0,1]', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      await controller.setVolume(1.5);
      expect(controller.state.volume, 1.0);

      await controller.setVolume(-0.5);
      expect(controller.state.volume, 0.0);
    });

    test('volume shortcuts change by exactly 0.05, clamped', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      await controller.setVolume(0.5);

      await controller.handleAction(PlayerAction.volumeDown);
      expect(controller.state.volume, closeTo(0.45, 1e-9));

      await controller.handleAction(PlayerAction.volumeUp);
      await controller.handleAction(PlayerAction.volumeUp);
      expect(controller.state.volume, closeTo(0.55, 1e-9));

      await controller.setVolume(0.99);
      await controller.handleAction(PlayerAction.volumeUp);
      expect(controller.state.volume, 1.0);

      await controller.setVolume(0.01);
      await controller.handleAction(PlayerAction.volumeDown);
      expect(controller.state.volume, 0.0);
    });

    test('a throwing engine setVolume surfaces as state.controlFailure '
        'rather than an unhandled error (I6), without touching '
        'phase/failure — the exact scenario 3 regression (fix round 1, '
        'item 5): a cosmetic volume-nudge failure must never strand the '
        'scene in a terminal phase', () async {
      final inner = FakePlaybackEngine();
      final engine = _FaultyEngine(inner, volumeThrows: true);
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      await controller.setVolume(0.5);

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.failure, isNull);
      expect(controller.state.controlFailure, isNotNull);
      expect(controller.state.controlFailureSequence, 1);
      expect(controller.state.volume, isNot(0.5));
    });

    test(
      'redacts the real API key out of a controlFailure message too '
      '(final review I6 — `_runEngineCommand` has no `config` of its own '
      'in scope, so it must read the cached key instead of an empty one)',
      () async {
        final inner = FakePlaybackEngine();
        final engine = _FaultyEngine(
          inner,
          volumeThrows: true,
          errorMessage: 'setVolume failed: key=${_config.apiKey}',
        );
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith());

        await controller.setVolume(0.5);

        expect(controller.state.controlFailure, isNotNull);
        expect(
          controller.state.controlFailure,
          isNot(contains(_config.apiKey)),
        );
      },
    );
  });

  group('mute', () {
    test('toggleMute flips state and calls the engine', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      await controller.toggleMute();
      expect(controller.state.muted, isTrue);
      expect((engine.commands.last as SetMutedCommand).muted, isTrue);

      await controller.toggleMute();
      expect(controller.state.muted, isFalse);
      expect((engine.commands.last as SetMutedCommand).muted, isFalse);
    });

    test('a throwing engine setMuted surfaces as state.controlFailure '
        'rather than an unhandled error (I6), without touching '
        'phase/failure', () async {
      final inner = FakePlaybackEngine();
      final engine = _FaultyEngine(inner, mutedThrows: true);
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      await controller.toggleMute();

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.failure, isNull);
      expect(controller.state.controlFailure, isNotNull);
      expect(controller.state.controlFailureSequence, 1);
      expect(controller.state.muted, isFalse);
    });
  });

  group('fullscreen', () {
    test(
      'setFullscreen(true) updates state once the platform call succeeds',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith());

        await controller.setFullscreen(true);

        expect(controller.state.fullscreen, isTrue);
      },
    );

    test('a platform call returning false leaves state unchanged', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(
        engine: engine,
        setFullscreenPlatform: (value) async => false,
      );
      await controller.loadScene(_sceneWith());

      await controller.setFullscreen(true);

      expect(controller.state.fullscreen, isFalse);
    });

    test('a platform call that throws leaves state unchanged', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(
        engine: engine,
        setFullscreenPlatform: (value) async => throw StateError('nope'),
      );
      await controller.loadScene(_sceneWith());

      await controller.setFullscreen(true);

      expect(controller.state.fullscreen, isFalse);
    });

    test('exitFullscreen action does nothing when not fullscreen — and never '
        'even calls the FullscreenRequester (final review §3b: '
        '`fullscreen isFalse` alone was already true before the action ran '
        'and could never fail)', () async {
      final engine = FakePlaybackEngine();
      var requesterCalls = 0;
      final controller = _buildController(
        engine: engine,
        setFullscreenPlatform: (value) async {
          requesterCalls++;
          return true;
        },
      );
      await controller.loadScene(_sceneWith());

      await controller.handleAction(PlayerAction.exitFullscreen);

      expect(controller.state.fullscreen, isFalse);
      expect(requesterCalls, 0);
    });

    test('exitFullscreen action exits when fullscreen', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      await controller.setFullscreen(true);

      await controller.handleAction(PlayerAction.exitFullscreen);

      expect(controller.state.fullscreen, isFalse);
    });

    test('toggleFullscreen action flips state', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      await controller.handleAction(PlayerAction.toggleFullscreen);
      expect(controller.state.fullscreen, isTrue);

      await controller.handleAction(PlayerAction.toggleFullscreen);
      expect(controller.state.fullscreen, isFalse);
    });
  });

  group('scene replacement', () {
    test('loading a new scene never disposes the shared engine', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(id: 'a'));
      await controller.loadScene(_sceneWith(id: 'b'));

      expect(engine.isDisposed, isFalse);
      expect(controller.state.scene?.id, 'b');
      expect(controller.state.generation, 2);
    });

    test(
      'loading a new scene does not stall behind the outgoing scene\'s '
      'retrying activity checkpoint (C3: opening a scene must not wait on '
      'up to 7 seconds of retry backoff before the engine is even touched)',
      () async {
        final engine = FakePlaybackEngine();
        // Never resolves on its own — if loadScene's call to
        // ActivitySync.replaceScene ever waited for the full retry chain,
        // this second loadScene would hang forever instead of completing.
        final heldRetryDelay = Completer<void>();
        final controller = _buildController(
          engine: engine,
          saveActivity:
              ({
                required id,
                required resumeTime,
                required playDuration,
              }) async => throw StateError('activity endpoint down'),
          activityDelay: (_) => heldRetryDelay.future,
        );
        await controller.loadScene(_sceneWith(id: 'a', duration: 2000));
        engine.emitPlaying(true);
        await pumpEventQueue();

        await controller.loadScene(_sceneWith(id: 'b', duration: 2000));

        expect(controller.state.scene?.id, 'b');
        expect(controller.state.phase, PlaybackPhase.ready);

        heldRetryDelay.complete(); // let the backgrounded retry settle
      },
    );

    test("back-to-back loadScene calls do not wipe a never-watched scene's "
        'resume point with a bogus zero (N4: loadScene(c) starting while '
        "loadScene(b) is still parked before b's own resume-seek decision "
        "must not report resumeTime: 0.0, playDuration: 0.0 for b)", () async {
      final engine = FakePlaybackEngine();
      final calls = <({String id, double resumeTime, double playDuration})>[];
      final completers = <Completer<ConnectionConfig>>[];
      final controller = PlaybackController(
        engine: engine,
        resolveConnection: () {
          final completer = Completer<ConnectionConfig>();
          completers.add(completer);
          return completer.future;
        },
        setFullscreenPlatform: (value) async => true,
        activitySyncFactory: ({required resumePositionSeconds}) => ActivitySync(
          resumePositionSeconds: resumePositionSeconds,
          saveActivity:
              ({
                required id,
                required resumeTime,
                required playDuration,
              }) async {
                calls.add((
                  id: id,
                  resumeTime: resumeTime,
                  playDuration: playDuration,
                ));
              },
          delay: (_) async {},
        ),
      );
      addTearDown(controller.dispose);

      // Scene A loads fully, establishing a real (zero, but established)
      // position.
      final futureA = controller.loadScene(
        _sceneWith(id: 'a', stream: 'a.mp4', duration: 2000),
      );
      await pumpEventQueue();
      expect(completers, hasLength(1));
      completers[0].complete(_config);
      await futureA;
      expect(controller.state.phase, PlaybackPhase.ready);
      calls.clear();

      // Scene B starts loading but is parked before its own resume-seek
      // decision point (still awaiting resolveConnection) — the user
      // never watches a frame of it.
      final futureB = controller.loadScene(
        _sceneWith(id: 'b', stream: 'b.mp4', duration: 2000),
      );
      await pumpEventQueue();
      expect(completers, hasLength(2));

      // Scene C supersedes B before B ever reaches open()/its resume
      // decision.
      final futureC = controller.loadScene(
        _sceneWith(id: 'c', stream: 'c.mp4', duration: 2000),
      );
      await pumpEventQueue();
      expect(completers, hasLength(3));

      completers[1].complete(_config); // B's (now stale) connection
      completers[2].complete(_config); // C's
      await Future.wait([futureB, futureC]);

      expect(controller.state.scene?.id, 'c');
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(
        calls.where((c) => c.id == 'b'),
        isEmpty,
        reason:
            "b's position was never established and nothing was ever "
            'queued for it either — there is nothing genuine to report, '
            'so no saveSceneActivity call for b should happen at all',
      );
    });

    test(
      'a stale loadScene continuation cannot clobber a newer scene',
      () async {
        final engine = FakePlaybackEngine();
        final completers = <Completer<ConnectionConfig>>[];
        final controller = PlaybackController(
          engine: engine,
          resolveConnection: () {
            final completer = Completer<ConnectionConfig>();
            completers.add(completer);
            return completer.future;
          },
          setFullscreenPlatform: (value) async => true,
        );
        addTearDown(controller.dispose);

        // Scene A must actually reach `resolveConnection` (and so be
        // parked on its own completer) *before* scene B starts — loadScene
        // claims its generation synchronously, so if B were started first
        // (or immediately after, before A's post-cancellation generation
        // check ran), A would already be recognized as superseded and
        // bail before ever calling `resolveConnection` at all. That's
        // correct behavior, but it tests a different thing than this test
        // is after: a continuation stale *after* resolveConnection.
        final futureA = controller.loadScene(
          _sceneWith(id: 'a', stream: 'a.mp4'),
        );
        await pumpEventQueue();
        expect(completers, hasLength(1));

        final futureB = controller.loadScene(
          _sceneWith(id: 'b', stream: 'b.mp4'),
        );
        await pumpEventQueue();
        expect(completers, hasLength(2));

        completers[1].complete(_config);
        await futureB;

        expect(controller.state.scene?.id, 'b');
        expect(controller.state.phase, PlaybackPhase.ready);
        final commandsAfterB = List<PlaybackCommand>.of(engine.commands);

        completers[0].complete(_config);
        await futureA;

        expect(controller.state.scene?.id, 'b');
        expect(controller.state.phase, PlaybackPhase.ready);
        expect(engine.commands, commandsAfterB);
      },
    );

    test('a stream event from a superseded generation does not land on the new '
        'scene (weak: FakePlaybackEngine cancels synchronously, so this '
        'passes even without the guard — see the _RecordingEngine test below '
        'for a real proof)', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(id: 'a', duration: 2000));

      final future = controller.loadScene(_sceneWith(id: 'b', duration: 2000));
      engine.emitPosition(const Duration(seconds: 999));
      await future;

      expect(controller.state.position, isNot(const Duration(seconds: 999)));
    });

    test('two loadScene calls issued back-to-back within one microtask claim '
        'distinct generations (I2 regression: fails if the generation is '
        'claimed after any await instead of synchronously up front)', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      final a = controller.loadScene(_sceneWith(id: 'a', stream: 'a.mp4'));
      final b = controller.loadScene(_sceneWith(id: 'b', stream: 'b.mp4'));
      await Future.wait([a, b]);

      expect(engine.commands.whereType<OpenCommand>(), hasLength(1));
      expect(engine.commands.whereType<PlayCommand>(), hasLength(1));
      expect(controller.state.scene?.id, 'b');
      expect(controller.state.generation, 2);
    });

    test('a stale generation-1 position callback cannot update state once '
        'generation 2 is current (I4: proves the guard using a stream double '
        'whose subscriptions cannot be cancelled, since a plain '
        'FakePlaybackEngine cancels synchronously and so can never actually '
        'race this)', () async {
      final inner = FakePlaybackEngine();
      final engine = _RecordingEngine(inner);
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(id: 'a', duration: 2000));
      await controller.loadScene(_sceneWith(id: 'b', duration: 2000));
      expect(controller.state.generation, 2);
      expect(engine.positionRecorder.callbacks, hasLength(2));

      final before = controller.state.position;
      // Invoke generation 1's captured callback directly — standing in
      // for a contractually-permitted (if hypothetical) PlaybackEngine
      // implementation whose cancellation isn't airtight the way every
      // real StreamController-backed one in this codebase is; see
      // _RecordingStream's own doc for why this isn't reproducing an
      // actual race against a real engine.
      engine.positionRecorder.callbacks[0](const Duration(seconds: 999));

      expect(controller.state.position, before);
      expect(controller.state.position, isNot(const Duration(seconds: 999)));
    });

    test(
      'a stale generation-1 errors callback cannot fail the current scene '
      '(I4, same technique applied to the errors/phase-setting callback)',
      () async {
        final inner = FakePlaybackEngine();
        final engine = _RecordingEngine(inner);
        final controller = _buildController(engine: engine);

        await controller.loadScene(_sceneWith(id: 'a'));
        await controller.loadScene(_sceneWith(id: 'b'));
        expect(controller.state.generation, 2);
        expect(engine.errorsRecorder.callbacks, hasLength(2));

        engine.errorsRecorder.callbacks[0]('scene a blew up');

        expect(controller.state.phase, isNot(PlaybackPhase.failed));
        expect(controller.state.failure, isNull);
      },
    );

    test('a stale generation-1 playing callback cannot update state once '
        'generation 2 is current (I4, completing coverage: the playing '
        'guard)', () async {
      final inner = FakePlaybackEngine();
      final engine = _RecordingEngine(inner);
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(id: 'a'));
      await controller.loadScene(_sceneWith(id: 'b'));
      expect(controller.state.generation, 2);
      expect(engine.playingRecorder.callbacks, hasLength(2));

      final before = controller.state.playing;
      engine.playingRecorder.callbacks[0](true);

      expect(controller.state.playing, before);
    });

    test('a stale generation-1 buffering callback cannot update state once '
        'generation 2 is current (I4, completing coverage: the buffering '
        'guard)', () async {
      final inner = FakePlaybackEngine();
      final engine = _RecordingEngine(inner);
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(id: 'a'));
      await controller.loadScene(_sceneWith(id: 'b'));
      expect(controller.state.generation, 2);
      expect(engine.bufferingRecorder.callbacks, hasLength(2));

      final before = controller.state.buffering;
      engine.bufferingRecorder.callbacks[0](true);

      expect(controller.state.buffering, before);
    });

    test('a stale generation-1 duration callback cannot update state once '
        'generation 2 is current (I4, completing coverage: the duration '
        'guard)', () async {
      final inner = FakePlaybackEngine();
      final engine = _RecordingEngine(inner);
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(id: 'a', duration: 2000));
      await controller.loadScene(_sceneWith(id: 'b', duration: 2000));
      expect(controller.state.generation, 2);
      expect(engine.durationRecorder.callbacks, hasLength(2));

      final before = controller.state.duration;
      engine.durationRecorder.callbacks[0](const Duration(seconds: 999));

      expect(controller.state.duration, before);
      expect(controller.state.duration, isNot(const Duration(seconds: 999)));
    });
  });

  group('disposal', () {
    test("disposing while a scene is still loading (before its own resume "
        "seek ever landed) does not wipe that scene's real resume point "
        'with a bogus zero (Item 1: N4 threaded into the dispose boundary, '
        "not just replaceScene — dispose's own flush must respect "
        '_positionEstablished too)', () async {
      final engine = FakePlaybackEngine();
      final calls = <({String id, double resumeTime, double playDuration})>[];
      final connectionCompleter = Completer<ConnectionConfig>();
      final controller = PlaybackController(
        engine: engine,
        resolveConnection: () => connectionCompleter.future,
        setFullscreenPlatform: (value) async => true,
        activitySyncFactory: ({required resumePositionSeconds}) => ActivitySync(
          resumePositionSeconds: resumePositionSeconds,
          saveActivity:
              ({
                required id,
                required resumeTime,
                required playDuration,
              }) async {
                calls.add((
                  id: id,
                  resumeTime: resumeTime,
                  playDuration: playDuration,
                ));
              },
          delay: (_) async {},
        ),
      );
      addTearDown(controller.dispose);

      // Scene b starts loading but never reaches its own resume-seek
      // decision point — parked awaiting resolveConnection, well
      // before `_engine.open`/`seek`. The user never watches a frame
      // of it.
      final loadFuture = controller.loadScene(
        _sceneWith(id: 'b', duration: 2000),
      );
      await pumpEventQueue();

      // The user navigates away (closes the window) before b ever
      // finishes loading.
      await controller.dispose();

      expect(
        calls.where((c) => c.id == 'b'),
        isEmpty,
        reason:
            "b's position was never established and nothing was ever "
            'queued for it either — there is nothing genuine to '
            'report, so dispose must not send resumeTime: 0.0, '
            'playDuration: 0.0 for it',
      );

      // Let the parked loadScene settle harmlessly (it bails out on
      // its own post-dispose generation/disposed guard).
      connectionCompleter.complete(_config);
      await loadFuture;
    });

    test(
      'flushes activity before disposing the engine, exactly once',
      () async {
        final engine = FakePlaybackEngine();
        var flushCalls = 0;
        final controller = _buildController(
          engine: engine,
          saveActivity:
              ({
                required id,
                required resumeTime,
                required playDuration,
              }) async {
                flushCalls++;
                expect(
                  engine.isDisposed,
                  isFalse,
                  reason: 'flush must run before the engine is disposed',
                );
              },
        );
        await controller.loadScene(_sceneWith());

        await controller.dispose();

        expect(flushCalls, 1);
        expect(engine.isDisposed, isTrue);
        expect(engine.commands.whereType<DisposeCommand>(), hasLength(1));
        expect(controller.state.phase, PlaybackPhase.disposed);

        // Idempotent: a second dispose call must not re-flush or re-dispose.
        await controller.dispose();
        expect(flushCalls, 1);
        expect(engine.commands.whereType<DisposeCommand>(), hasLength(1));
      },
    );

    test('pauses the engine before the activity flush, so a hung checkpoint '
        'endpoint cannot leave it rendering audio for the duration of '
        "ActivitySync's own bounded wait (N3)", () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(
        engine: engine,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async {
              // Still mid-flush when this runs — the pause must already
              // have landed, strictly before this (potentially slow)
              // call even started.
              expect(engine.commands.whereType<PauseCommand>(), hasLength(1));
              expect(engine.commands.whereType<DisposeCommand>(), isEmpty);
            },
      );
      await controller.loadScene(_sceneWith());
      engine.commands.clear();

      await controller.dispose();

      expect(engine.commands.whereType<PauseCommand>(), hasLength(1));
      final pauseIndex = engine.commands.indexWhere((c) => c is PauseCommand);
      final disposeIndex = engine.commands.indexWhere(
        (c) => c is DisposeCommand,
      );
      expect(pauseIndex, greaterThanOrEqualTo(0));
      expect(disposeIndex, greaterThan(pauseIndex));
    });

    test('a throwing pause does not block the activity flush or the engine '
        'dispose that follow it', () async {
      final inner = FakePlaybackEngine();
      final engine = _FaultyEngine(inner, pauseThrows: true);
      var flushCalls = 0;
      final controller = _buildController(
        engine: engine,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async {
              flushCalls++;
            },
      );
      await controller.loadScene(_sceneWith());

      await controller.dispose();

      expect(flushCalls, 1);
      expect(inner.isDisposed, isTrue);
    });

    test(
      'omitting activity-sync overrides defaults to a no-op that does not throw',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith());

        await controller.dispose();

        expect(engine.isDisposed, isTrue);
      },
    );

    test('a throwing flush does not strand the engine undisposed, and does '
        'not escape as an unhandled error (I5) — it still reports a '
        'warning, and the engine still gets disposed, once the flush chain '
        'settles', () async {
      // This is a wiring test, not a timing one: it proves the
      // controller correctly disposes the engine and forwards
      // ActivitySync's warning through its own `onActivityWarning`,
      // regardless of how long the underlying flush chain takes to
      // settle. Whether a fully-failing dispose flush *genuinely*
      // manages to warn within the real disposeFlushTimeout budget is
      // a question about ActivitySync's own timing, proved directly —
      // with fake_async and the real retry/timeout durations, no
      // PlaybackController involved — by
      // "a fully-failing dispose flush warns within the real
      // disposeFlushTimeout budget" in activity_sync_test.dart.
      // Reproducing that same proof here isn't possible: fake_async
      // does not reliably drive a broadcast StreamController
      // subscription's `.cancel()` future (a well-known limitation —
      // verified directly: it resolves on the real event loop after
      // the fakeAsync zone's callback returns, not during any
      // elapse()/flushMicrotasks() call within it), and
      // `_cancelSubscriptions()` in `PlaybackController.dispose()`
      // depends on exactly that. So this test keeps the instant-delay
      // style used everywhere else in this file — disposeFlushTimeout
      // specifically never resolves, letting the flush's own
      // (instantly-retried) 4-attempt cycle genuinely finish and warn,
      // which is all this test needs to prove the wiring.
      final engine = FakePlaybackEngine();
      final warnings = <String>[];
      final controller = _buildController(
        engine: engine,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async =>
                throw StateError('network down'),
        onActivityWarning: warnings.add,
        activityDelay: (duration) => duration == disposeFlushTimeout
            ? Completer<void>().future
            : Future<void>.value(),
      );
      await controller.loadScene(_sceneWith());

      await controller.dispose();

      expect(engine.isDisposed, isTrue);
      expect(engine.commands.whereType<DisposeCommand>(), hasLength(1));
      expect(warnings, [activitySyncWarningMessage]);
    });

    test(
      'commands issued after dispose are no-ops, never reaching the engine',
      () async {
        final inner = FakePlaybackEngine();
        final engine = _CallCountingEngine(inner);
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith(duration: 2000));
        await controller.dispose();
        engine.invocations.clear();

        // None of these may throw. It is not enough that they don't
        // throw, though: `_runEngineCommand`'s own catch would silently
        // swallow the fake's post-dispose StateError just as readily as
        // a real failure — and `FakePlaybackEngine` itself throws
        // *before* recording anything to `commands`, so that log can't
        // reveal a missed guard either. `_CallCountingEngine.invocations`
        // is the only thing that actually proves none of these reached
        // the engine at all.
        await controller.playPause();
        await controller.seekAbsolute(const Duration(seconds: 10));
        await controller.seekRelative(const Duration(seconds: 10));
        await controller.setVolume(0.2);
        await controller.toggleMute();
        await controller.setFullscreen(true);
        await controller.loadScene(_sceneWith(id: 'late'));

        expect(engine.invocations, isEmpty);
      },
    );
  });

  group('activity sync wiring', () {
    test('an accepted playing transition to false flushes activity for the '
        'current scene', () async {
      final engine = FakePlaybackEngine();
      final clock = FakeClock();
      final calls = <({String id, double resumeTime, double playDuration})>[];
      final controller = _buildController(
        engine: engine,
        activityClock: clock.now,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async {
              calls.add((
                id: id,
                resumeTime: resumeTime,
                playDuration: playDuration,
              ));
            },
      );
      await controller.loadScene(_sceneWith(id: 'a', duration: 2000));
      calls.clear();

      engine.emitPlaying(true);
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 5));
      engine.emitPlaying(false);
      await pumpEventQueue();

      expect(calls, hasLength(1));
      expect(calls.single.id, 'a');
      expect(calls.single.playDuration, 5.0);
    });

    test("loading a new scene flushes the old scene's activity, under its own "
        'ID, before the new scene starts tracking', () async {
      final engine = FakePlaybackEngine();
      final clock = FakeClock();
      final calls = <({String id, double resumeTime, double playDuration})>[];
      final controller = _buildController(
        engine: engine,
        activityClock: clock.now,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async {
              calls.add((
                id: id,
                resumeTime: resumeTime,
                playDuration: playDuration,
              ));
            },
      );
      await controller.loadScene(_sceneWith(id: 'a', duration: 2000));
      calls.clear();
      engine.emitPlaying(true);
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 5));
      // Scene a's actual last known position — must be what gets reported
      // as its resumeTime, not scene b's zeroed starting position (C1).
      engine.emitPosition(const Duration(seconds: 1200));
      await pumpEventQueue();

      await controller.loadScene(_sceneWith(id: 'b', duration: 2000));

      expect(calls, hasLength(1));
      expect(calls.single.id, 'a');
      expect(calls.single.playDuration, 5.0);
      expect(
        calls.single.resumeTime,
        1200.0,
        reason:
            'C1: loadScene builds the new scene\'s PlaybackState (position '
            'reset to zero) before ActivitySync.replaceScene ever runs its '
            "flush — the outgoing scene's resumeTime must be captured "
            "before that reset, not read live from the (by-then zeroed) "
            'state.',
      );
    });

    test("a superseded generation's playing event is never recorded as "
        'activity — the generation guard runs before ActivitySync is ever '
        'reached', () async {
      final inner = FakePlaybackEngine();
      final engine = _RecordingEngine(inner);
      final clock = FakeClock();
      final calls = <({String id, double resumeTime, double playDuration})>[];
      final controller = _buildController(
        engine: engine,
        activityClock: clock.now,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async {
              calls.add((
                id: id,
                resumeTime: resumeTime,
                playDuration: playDuration,
              ));
            },
      );

      await controller.loadScene(_sceneWith(id: 'a', duration: 2000));
      await controller.loadScene(_sceneWith(id: 'b', duration: 2000));
      calls.clear();

      engine.playingRecorder.callbacks[0](true);
      clock.advance(const Duration(seconds: 5));
      engine.playingRecorder.callbacks[0](false);
      await pumpEventQueue();

      expect(calls, isEmpty);
    });

    test('a failing activity sync reports a warning but neither marks the '
        'controller failed nor blocks subsequent playback commands', () async {
      final engine = FakePlaybackEngine();
      final warnings = <String>[];
      final controller = _buildController(
        engine: engine,
        saveActivity:
            ({required id, required resumeTime, required playDuration}) async =>
                throw StateError('down'),
        onActivityWarning: warnings.add,
      );
      await controller.loadScene(_sceneWith());

      engine.emitPlaying(true);
      await pumpEventQueue();
      engine.emitPlaying(false); // triggers a failing, fire-and-forget flush
      await pumpEventQueue();

      expect(warnings, [activitySyncWarningMessage]);
      expect(controller.state.phase, isNot(PlaybackPhase.failed));

      engine.commands.clear();
      await controller.playPause();
      expect(engine.commands.single, isA<PlayCommand>());
    });
  });

  group('playbackControllerProvider', () {
    // Overrides `playbackEngineFactoryProvider` — never
    // `playbackEngineProvider` itself. `playbackEngineProvider`'s own
    // body (specifically its `ref.watch(connectionGenerationProvider)`
    // call, the C1 fix) is left genuinely exercised this way: a Riverpod
    // `overrideWith` replaces a provider's body entirely, so overriding
    // `playbackEngineProvider` directly would test a test-authored
    // reimplementation of the fix rather than the real one.
    ProviderContainer buildContainer({
      ConnectionConfig saved = _config,
      required List<FakePlaybackEngine> engines,
      FakeStashApi? stashApi,
      SocksForwardProxy? socksProxy,
      List<String?>? recordProxyUrls,
    }) {
      final proxyUrls = recordProxyUrls ?? <String?>[];
      final container = ProviderContainer(
        overrides: [
          socksForwardProxyProvider.overrideWithValue(socksProxy),
          connectionStoreProvider.overrideWithValue(
            FakeConnectionStore(saved: saved),
          ),
          environmentProvider.overrideWithValue(const {}),
          // Real production wiring routes ActivitySync's saveActivity
          // through stashApiProvider — without this override, disposing a
          // controller that ever loaded a scene would attempt a real
          // network call (and its full 1s/2s/4s retry schedule on
          // failure) against `_config`'s fake server URL.
          stashApiFactoryProvider.overrideWithValue(
            (config) => stashApi ?? FakeStashApi(),
          ),
          playbackEngineFactoryProvider.overrideWithValue(({httpProxyUrl}) {
            final engine = FakePlaybackEngine();
            proxyUrls.add(httpProxyUrl);
            engines.add(engine);
            return engine;
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'builds the engine with the loopback proxy URL when one is set',
      () async {
        final proxy = await SocksForwardProxy.bind();
        addTearDown(proxy.close);
        proxy.endpoint = const SocksEndpoint(host: '127.0.0.1', port: 1055);
        final proxyUrls = <String?>[];
        final container = buildContainer(
          engines: <FakePlaybackEngine>[],
          socksProxy: proxy,
          recordProxyUrls: proxyUrls,
        );

        container.read(playbackEngineProvider);

        expect(proxyUrls.single, 'http://127.0.0.1:${proxy.port}');
      },
    );

    test(
      'builds the engine with no proxy URL when none is configured',
      () async {
        final proxyUrls = <String?>[];
        final container = buildContainer(
          engines: <FakePlaybackEngine>[],
          recordProxyUrls: proxyUrls,
        );

        container.read(playbackEngineProvider);

        expect(proxyUrls.single, isNull);
      },
    );

    test('the provided controller resolves the connection through the '
        'deferred effectiveConnectionProvider', () async {
      final engines = <FakePlaybackEngine>[];
      final container = buildContainer(engines: engines);

      final controller = container.read(playbackControllerProvider.notifier);
      await controller.loadScene(_sceneWith());

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(engines.single.commands, isNotEmpty);
    });

    test("a superseded controller's final activity checkpoint still targets "
        'its own generation\'s StashApi, never whatever server/key is '
        'current by the time the flush actually runs (I1: stashApiProvider '
        'must be captured once at construction, not re-resolved lazily '
        'inside the saveActivity closure)', () async {
      final engines = <FakePlaybackEngine>[];
      final oldApi = FakeStashApi();
      final newApi = FakeStashApi();
      const newConfig = ConnectionConfig(
        serverUrl: 'https://new-stash.test',
        apiKey: 'new-key',
      );
      final store = FakeConnectionStore(saved: _config);
      final container = ProviderContainer(
        overrides: [
          connectionStoreProvider.overrideWithValue(store),
          environmentProvider.overrideWithValue(const {}),
          stashApiFactoryProvider.overrideWithValue(
            (config) => config.serverUrl == _config.serverUrl ? oldApi : newApi,
          ),
          playbackEngineFactoryProvider.overrideWithValue(({httpProxyUrl}) {
            final engine = FakePlaybackEngine();
            engines.add(engine);
            return engine;
          }),
        ],
      );
      addTearDown(container.dispose);

      final firstController = container.read(
        playbackControllerProvider.notifier,
      );
      await firstController.loadScene(_sceneWith(id: 'a'));
      engines.single.emitPlaying(true);
      await pumpEventQueue();

      // Reconnect to a different server/key entirely.
      store.saved = newConfig;
      container.read(connectionGenerationProvider.notifier).state++;

      // Reading the provider again rebuilds it — a fresh controller —
      // while the *old* controller's dispose() (and so its
      // ActivitySync's final checkpoint flush) runs as fire-and-forget
      // teardown from Riverpod's perspective.
      container.read(playbackControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      await pumpEventQueue();

      expect(oldApi.saveActivityCalls, isNotEmpty);
      expect(oldApi.saveActivityCalls.single.id, 'a');
      expect(newApi.saveActivityCalls, isEmpty);
    });

    test('bumping connectionGenerationProvider yields a fresh controller AND '
        'a fresh engine, discarding the old (now-disposed) one — the C1 '
        'regression: a loadScene on the second controller must not throw '
        'the disposed FakePlaybackEngine\'s post-dispose StateError', () async {
      final engines = <FakePlaybackEngine>[];
      final container = buildContainer(engines: engines);

      final firstController = container.read(
        playbackControllerProvider.notifier,
      );
      await firstController.loadScene(_sceneWith());
      expect(firstController.state.phase, PlaybackPhase.ready);
      expect(engines, hasLength(1));

      container.read(connectionGenerationProvider.notifier).state++;

      final secondController = container.read(
        playbackControllerProvider.notifier,
      );

      expect(identical(firstController, secondController), isFalse);
      expect(secondController.state.phase, PlaybackPhase.initial);
      expect(secondController.state.generation, 0);
      // The old controller's dispose() (triggered by the provider
      // rebuild) is fire-and-forget from Riverpod's perspective; give
      // its async teardown a chance to run before asserting on it.
      await Future<void>.delayed(Duration.zero);
      expect(engines, hasLength(2));
      expect(engines[0].isDisposed, isTrue);
      expect(engines[1].isDisposed, isFalse);

      // The critical regression check: the second controller got a
      // fresh, non-disposed engine, so loading a scene on it must
      // complete normally rather than surfacing the first (disposed)
      // engine's StateError as a caught `phase: failed`.
      await secondController.loadScene(_sceneWith(id: 'after-reconnect'));

      expect(secondController.state.phase, PlaybackPhase.ready);
      expect(engines[1].commands, isNotEmpty);
    });
  });

  group('load stages', () {
    test(
      'reports the connecting stage while the connection is resolving',
      () async {
        final engine = FakePlaybackEngine();
        final connection = Completer<ConnectionConfig>();
        final controller = PlaybackController(
          engine: engine,
          resolveConnection: () => connection.future,
          setFullscreenPlatform: (_) async => true,
          activitySyncFactory: ({required resumePositionSeconds}) =>
              ActivitySync(resumePositionSeconds: resumePositionSeconds),
        );
        addTearDown(controller.dispose);

        final load = controller.loadScene(_sceneWith());
        await pumpEventQueue();

        expect(controller.state.loadStage, LoadStage.connecting);

        connection.complete(_config);
        await load;
      },
    );

    test(
      'reports the opening stage while the engine is opening the stream',
      () async {
        final engine = _GatedEngine(FakePlaybackEngine());
        final controller = _buildController(engine: engine);

        final load = controller.loadScene(_sceneWith());
        await pumpEventQueue();

        expect(controller.state.loadStage, LoadStage.opening);

        engine.openGate.complete();
        await load;
      },
    );

    test('never issues a bare seek for the resume, which the real engine '
        'rejected outright when it arrived before the file was open', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 500, duration: 2000));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
      expect(
        engine.commands.whereType<OpenCommand>().single.startAt,
        const Duration(seconds: 500),
      );
    });

    test('clears the stage once the scene is ready', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith());

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.loadStage, isNull);
    });

    test('clears the stage when the load fails, rather than leaving it '
        'stuck on whichever stage threw', () async {
      final engine = _FaultyEngine(FakePlaybackEngine(), openThrows: true);
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith());

      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.state.loadStage, isNull);
    });
  });

  group('load diagnostics logging', () {
    test(
      'logs a stage report naming the scene once a load completes',
      () async {
        final logs = <String>[];
        final controller = _buildController(
          engine: FakePlaybackEngine(),
          log: logs.add,
        );

        await controller.loadScene(_sceneWith(id: 's7'));

        expect(logs, contains(allOf(contains('scene s7'), contains('open'))));
      },
    );

    test('logs the stage report for a load that failed, not only one that '
        'succeeded', () async {
      final logs = <String>[];
      final controller = _buildController(
        engine: _FaultyEngine(FakePlaybackEngine(), openThrows: true),
        log: logs.add,
      );

      await controller.loadScene(_sceneWith(id: 's8'));

      expect(logs, contains(contains('scene s8')));
    });

    test('describes the file being loaded so a slow load can be read '
        'against what caused it', () async {
      final logs = <String>[];
      final controller = _buildController(
        engine: FakePlaybackEngine(),
        log: logs.add,
      );

      await controller.loadScene(
        Scene(
          id: 's9',
          paths: const ScenePaths(stream: 'stream.mkv'),
          files: const [
            SceneFile(videoCodec: 'h265', audioCodec: 'aac', format: 'mkv'),
          ],
        ),
      );

      expect(logs, contains(contains('h265/aac mkv')));
    });

    test('times the buffering stall, which is the wait the viewer actually '
        'sits through when every load stage closed in milliseconds', () async {
      final logs = <String>[];
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine, log: logs.add);
      await controller.loadScene(_sceneWith(id: 's10'));
      logs.clear();

      engine.emitBuffering(true);
      await pumpEventQueue();
      engine.emitBuffered(const Duration(seconds: 12));
      engine.emitBuffering(false);
      await pumpEventQueue();

      expect(
        logs,
        contains(allOf(contains('scene s10'), contains('first stall lasted'))),
      );
    });

    test('reports the cache the stall recovered with, so a stall that was '
        'making progress is distinguishable from a stuck one', () async {
      final logs = <String>[];
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine, log: logs.add);
      await controller.loadScene(_sceneWith());
      engine.emitBuffering(true);
      await pumpEventQueue();
      engine.emitBuffered(const Duration(seconds: 12));
      await pumpEventQueue();
      logs.clear();

      engine.emitBuffering(false);
      await pumpEventQueue();

      expect(logs, contains(contains('12s cached')));
    });

    test('a repeated buffering signal does not report a stall twice', () async {
      final logs = <String>[];
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine, log: logs.add);
      await controller.loadScene(_sceneWith());
      logs.clear();

      engine.emitBuffering(true);
      engine.emitBuffering(false);
      engine.emitBuffering(false);
      await pumpEventQueue();

      expect(logs.where((line) => line.contains('stall')), hasLength(1));
    });

    test('does not log a position advance, which fires before there is any '
        'video and made a 65-second load read as instant', () async {
      final logs = <String>[];
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine, log: logs.add);
      await controller.loadScene(_sceneWith());
      logs.clear();

      engine.emitPosition(const Duration(seconds: 1));
      engine.emitPosition(const Duration(seconds: 2));
      await pumpEventQueue();

      expect(logs, isEmpty);
    });
    test('a new scene gets its own milestones rather than staying silent '
        'because the previous scene already reported them', () async {
      final logs = <String>[];
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine, log: logs.add);
      await controller.loadScene(_sceneWith(id: 'first'));
      engine.emitPlaying(true);
      await pumpEventQueue();

      await controller.loadScene(_sceneWith(id: 'second'));
      logs.clear();
      engine.emitPlaying(true);
      await pumpEventQueue();

      expect(logs, contains(contains('scene second: engine unpaused')));
    });
  });

  group('buffered-ahead reporting', () {
    test('records how far ahead the engine has buffered', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      engine.emitBuffered(const Duration(seconds: 8));
      await pumpEventQueue();

      expect(controller.state.buffered, const Duration(seconds: 8));
    });

    test('a new scene starts from zero rather than inheriting the previous '
        "scene's buffer", () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());
      engine.emitBuffered(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(controller.state.buffered, const Duration(seconds: 30));

      await controller.loadScene(_sceneWith(id: 'next'));

      expect(controller.state.buffered, Duration.zero);
    });
  });

  group('falling back to the transcode when the direct stream stalls', () {
    // A minority of mp4s are written with one `mdat` box per chunk, and
    // libmpv walks every one of them before playing: measured at 63
    // seconds and 70 MB of discarded header reads for a 331 MB file that
    // the platform player opens instantly. Nothing client-side stops the
    // walk without breaking seeking, so the player waits out a stall that
    // is going nowhere and asks Stash for its transcode instead.
    /// A scene whose stream URL looks like Stash's real direct route,
    /// which has no file extension. The shared helper's default does, and
    /// `transcodedStreamUrl` correctly refuses to append twice.
    Scene directScene({String id = 's1'}) =>
        _sceneWith(id: id, stream: 'scene/$id/stream');

    /// Stalls the engine and lets the deadline arrive, the way eight
    /// seconds of nothing would.
    Future<void> stall(FakePlaybackEngine engine, _ManualTimers timers) async {
      engine.emitBuffering(true);
      await pumpEventQueue();
      timers.latest.fire();
      await pumpEventQueue();
    }

    test('reopens on the transcoded URL when a stall goes nowhere', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.commands.clear();

      await stall(engine, timers);
      await pumpEventQueue();

      final opens = engine.commands.whereType<OpenCommand>();
      expect(opens, hasLength(1));
      expect(opens.single.uri.path, endsWith('/stream.mp4'));
      expect(controller.state.streams!.hasSwitched, isTrue);
    });

    test('leaves a stall that is actually buffering alone, since the direct '
        'stream is the better one when it works', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.commands.clear();

      engine.emitBuffering(true);
      engine.emitBuffered(const Duration(seconds: 4));
      await pumpEventQueue();
      await pumpEventQueue();

      expect(engine.commands.whereType<OpenCommand>(), isEmpty);
      expect(controller.state.streams!.hasSwitched, isFalse);
    });

    test('leaves a stall that recovers on its own alone', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.commands.clear();

      engine.emitBuffering(true);
      await pumpEventQueue();
      engine.emitBuffering(false);
      await pumpEventQueue();
      // The deadline is cancelled the moment the stall ends, so firing it
      // afterwards must do nothing.
      timers.latest.fire();
      await pumpEventQueue();

      expect(engine.commands.whereType<OpenCommand>(), isEmpty);
      expect(timers.latest.isActive, isFalse);
    });

    test('switches at most once, so a transcode that also stalls cannot '
        'loop', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      await stall(engine, timers);
      await pumpEventQueue();
      engine.commands.clear();

      engine.emitBuffering(false);
      await pumpEventQueue();
      await stall(engine, timers);
      await pumpEventQueue();

      expect(engine.commands.whereType<OpenCommand>(), isEmpty);
    });

    test(
      'resumes where the viewer had got to, not from the beginning',
      () async {
        final engine = FakePlaybackEngine();
        final timers = _ManualTimers();
        final controller = _buildController(
          engine: engine,
          stallTimerFactory: timers.call,
        );
        await controller.loadScene(directScene());
        engine.emitPosition(const Duration(seconds: 210));
        await pumpEventQueue();
        engine.commands.clear();

        await stall(engine, timers);
        await pumpEventQueue();

        // The position travels in the URL, not as an engine-level start:
        // the transcode has no timeline to seek within. See the
        // "seeking on the transcode" group.
        expect(
          engine.commands
              .whereType<OpenCommand>()
              .single
              .uri
              .queryParameters['start'],
          '210',
        );
        expect(controller.state.position, const Duration(seconds: 210));
      },
    );

    test('a new scene starts on the direct stream again, rather than '
        'inheriting the previous one\'s fallback', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene(id: 'first'));
      await stall(engine, timers);
      await pumpEventQueue();
      expect(controller.state.streams!.hasSwitched, isTrue);
      engine.commands.clear();

      await controller.loadScene(directScene(id: 'second'));

      expect(controller.state.streams!.hasSwitched, isFalse);
      expect(
        engine.commands.whereType<OpenCommand>().single.uri.path,
        isNot(endsWith('.mp4')),
      );
    });

    test('says in the log that it gave up on the direct stream', () async {
      final logs = <String>[];
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        log: logs.add,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene(id: 's12'));
      logs.clear();

      await stall(engine, timers);
      await pumpEventQueue();

      expect(logs, contains(contains('Direct stream stalled')));
      expect(logs, contains(contains('retrying on MP4')));
    });

    test('does not switch after the controller is disposed', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.emitBuffering(true);
      await pumpEventQueue();

      await controller.dispose();
      timers.latest.fire();
      await pumpEventQueue();

      expect(controller.state.streams!.hasSwitched, isFalse);
      // Teardown cancels the pending deadline rather than leaving a real
      // eight-second timer alive past the controller.
      expect(timers.latest.isActive, isFalse);
    });
  });

  group('duration comes from the server, not the stream', () {
    // A transcode is generated as it is sent, so libmpv can only report
    // the duration of what has arrived so far, and that number climbs for
    // the whole scene. Stash already scanned the real duration of the
    // original file, so that is what the transport shows.
    test('reports the scanned duration as soon as the scene loads, without '
        'waiting for the engine to say anything', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(duration: 1800));

      expect(controller.state.duration, const Duration(seconds: 1800));
    });

    test('ignores a growing engine duration, which is what a transcode '
        'reports while it is still being produced', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 1800));

      engine.emitDuration(const Duration(seconds: 12));
      await pumpEventQueue();
      engine.emitDuration(const Duration(seconds: 47));
      await pumpEventQueue();

      expect(controller.state.duration, const Duration(seconds: 1800));
    });

    test('still takes the engine duration when the server scanned none, '
        'rather than showing no duration at all', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(withFile: false));

      engine.emitDuration(const Duration(seconds: 640));
      await pumpEventQueue();

      expect(controller.state.duration, const Duration(seconds: 640));
    });

    test('seekToEnd uses the scanned duration, so it works on a transcode '
        'whose reported duration is still climbing', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 1800));
      engine.emitDuration(const Duration(seconds: 12));
      await pumpEventQueue();
      engine.commands.clear();

      await controller.handleAction(PlayerAction.seekToEnd);

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 1800),
      );
    });
  });

  group('seeking on the transcode', () {
    Scene directScene({String id = 's1', double? duration = 1800}) =>
        _sceneWith(id: id, stream: 'scene/$id/stream', duration: duration);

    test('bakes the position into the URL rather than asking the engine to '
        'seek inside a stream that has no timeline', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.emitPosition(const Duration(seconds: 210));
      await pumpEventQueue();
      engine.commands.clear();

      engine.emitBuffering(true);
      await pumpEventQueue();
      timers.latest.fire();
      await pumpEventQueue();

      final open = engine.commands.whereType<OpenCommand>().single;
      expect(open.uri.queryParameters['start'], '210');
      expect(open.startAt, isNull);
    });

    test('reports positions in the scene\'s own timeline, not the '
        'transcode\'s, which restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.emitPosition(const Duration(seconds: 600));
      await pumpEventQueue();
      engine.emitBuffering(true);
      await pumpEventQueue();
      timers.latest.fire();
      await pumpEventQueue();

      // The transcode begins at 600s, so its own clock reads 5s here.
      engine.emitPosition(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(controller.state.position, const Duration(seconds: 605));
    });

    test('a seek reopens the transcode at the target instead of failing, '
        'which is what "it says it cannot seek" was', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(directScene());
      engine.emitBuffering(true);
      await pumpEventQueue();
      timers.latest.fire();
      await pumpEventQueue();
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: 900));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
      final open = engine.commands.whereType<OpenCommand>().single;
      expect(open.uri.queryParameters['start'], '900');
      expect(controller.state.position, const Duration(seconds: 900));
      expect(controller.state.controlFailure, isNull);
    });

    test('a seek on a healthy direct stream still seeks the engine, which is '
        'far cheaper than reopening', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(directScene());
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: 900));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 900),
      );
      expect(engine.commands.whereType<OpenCommand>(), isEmpty);
    });

    test(
      'a new scene clears the offset, so its positions are its own',
      () async {
        final engine = FakePlaybackEngine();
        final timers = _ManualTimers();
        final controller = _buildController(
          engine: engine,
          stallTimerFactory: timers.call,
        );
        await controller.loadScene(directScene());
        engine.emitPosition(const Duration(seconds: 600));
        await pumpEventQueue();
        engine.emitBuffering(true);
        await pumpEventQueue();
        timers.latest.fire();
        await pumpEventQueue();

        await controller.loadScene(directScene(id: 'next'));
        engine.emitPosition(const Duration(seconds: 5));
        await pumpEventQueue();

        expect(controller.state.position, const Duration(seconds: 5));
      },
    );
  });

  group('seeking and duration by stream kind', () {
    // Local to the group, so no leading underscore: flutter_lints enables
    // no_leading_underscores_for_local_identifiers and the gate runs
    // analyze --fatal-infos.
    SceneStream endpoint(String url, String label) =>
        SceneStream.fromEndpoint(url: url, label: label);

    Scene hlsScene() => _sceneWith(
      stream: 'scene/s1/stream',
      duration: 2000,
      streams: [
        endpoint('https://stash.example/scene/s1/stream', 'Direct stream'),
        endpoint(
          'https://stash.example/scene/s1/stream.m3u8?resolution=ORIGINAL',
          'HLS',
        ),
        endpoint(
          'https://stash.example/scene/s1/stream.mp4?resolution=ORIGINAL',
          'MP4',
        ),
      ],
    );

    Future<void> stall(FakePlaybackEngine engine, _ManualTimers timers) async {
      engine.emitBuffering(true);
      await pumpEventQueue();
      timers.latest.fire();
      await pumpEventQueue();
    }

    test('a stall falls to HLS rather than the progressive MP4, so the '
        'picture survives a container problem', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(hlsScene());
      engine.commands.clear();

      await stall(engine, timers);

      final opened = engine.commands.whereType<OpenCommand>().single;
      expect(opened.uri.path, endsWith('/stream.m3u8'));
      expect(controller.state.streams!.current.kind, StreamKind.hls);
    });

    test('seeking on HLS is a seek, not a reopen: the manifest enumerates '
        'every segment, so there is a timeline to move within', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(hlsScene());
      await stall(engine, timers);
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: 600));

      expect(engine.commands.whereType<OpenCommand>(), isEmpty);
      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 600),
      );
      expect(controller.state.position, const Duration(seconds: 600));
    });

    test('HLS positions are reported as they arrive, with no offset to add '
        'back', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(hlsScene());
      engine.emitPosition(const Duration(seconds: 300));
      await pumpEventQueue();
      await stall(engine, timers);

      engine.emitPosition(const Duration(seconds: 305));
      await pumpEventQueue();

      expect(controller.state.position, const Duration(seconds: 305));
    });

    test('seeking on a progressive transcode still reopens, because there '
        'is nothing to seek within', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      // No endpoint list, so the synthesized direct/MP4 pair applies and
      // the ladder's only rung is the progressive transcode.
      await controller.loadScene(
        _sceneWith(stream: 'scene/s1/stream', duration: 2000),
      );
      await stall(engine, timers);
      engine.commands.clear();

      await controller.seekAbsolute(const Duration(seconds: 600));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
      final reopened = engine.commands.whereType<OpenCommand>().single;
      expect(reopened.uri.queryParameters['start'], '600');
    });

    test('a progressive transcode\'s climbing duration is ignored even when '
        'Stash scanned no duration of its own', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(
        _sceneWith(stream: 'scene/s1/stream', withFile: false),
      );
      await stall(engine, timers);

      engine.emitDuration(const Duration(seconds: 12));
      await pumpEventQueue();

      expect(controller.state.duration, Duration.zero);
    });

    test('an HLS duration is believed when Stash scanned none, because the '
        'manifest covers the whole file', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(
        _sceneWith(
          stream: 'scene/s1/stream',
          withFile: false,
          streams: [
            endpoint('https://stash.example/scene/s1/stream', 'Direct stream'),
            endpoint(
              'https://stash.example/scene/s1/stream.m3u8?resolution=ORIGINAL',
              'HLS',
            ),
          ],
        ),
      );
      await stall(engine, timers);

      engine.emitDuration(const Duration(seconds: 1800));
      await pumpEventQueue();

      expect(controller.state.duration, const Duration(seconds: 1800));
    });
  });

  group('a stream that refuses to open', () {
    // Local to the group, so no leading underscore: flutter_lints enables
    // no_leading_underscores_for_local_identifiers and the gate runs
    // analyze --fatal-infos.
    SceneStream endpoint(String url, String label) =>
        SceneStream.fromEndpoint(url: url, label: label);

    Scene fullScene() => _sceneWith(
      stream: 'scene/s1/stream',
      duration: 2000,
      streams: [
        endpoint('https://stash.example/scene/s1/stream', 'Direct stream'),
        endpoint(
          'https://stash.example/scene/s1/stream.m3u8?resolution=ORIGINAL',
          'HLS',
        ),
        endpoint(
          'https://stash.example/scene/s1/stream.mp4?resolution=ORIGINAL',
          'MP4',
        ),
      ],
    );

    Future<void> stall(FakePlaybackEngine engine, _ManualTimers timers) async {
      engine.emitBuffering(true);
      await pumpEventQueue();
      timers.latest.fire();
      await pumpEventQueue();
    }

    test('falls onward to MP4 when the advertised HLS is refused, because a '
        'listing is not a promise', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(fullScene());
      engine.commands.clear();
      engine.failNextOpens.add(StateError('503 Live transcoding disabled'));

      await stall(engine, timers);
      await pumpEventQueue();

      final opens = engine.commands.whereType<OpenCommand>().toList();
      expect(opens, hasLength(2));
      expect(opens.first.uri.path, endsWith('/stream.m3u8'));
      expect(opens.last.uri.path, endsWith('/stream.mp4'));
      expect(controller.state.streams!.current.kind, StreamKind.mp4);
      expect(controller.state.phase, PlaybackPhase.ready);
    });

    test('gives up once the ladder is spent, rather than cycling', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(fullScene());
      engine.commands.clear();
      engine.failNextOpens.addAll([
        StateError('503 Live transcoding disabled'),
        StateError('500 transcode failed'),
      ]);

      await stall(engine, timers);
      await pumpEventQueue();

      expect(engine.commands.whereType<OpenCommand>(), hasLength(2));
      expect(controller.state.phase, PlaybackPhase.failed);
    });

    test('keeps the API key out of the surfaced failure', () async {
      final engine = FakePlaybackEngine();
      final timers = _ManualTimers();
      final controller = _buildController(
        engine: engine,
        stallTimerFactory: timers.call,
      );
      await controller.loadScene(
        _sceneWith(stream: 'scene/s1/stream', duration: 2000),
      );
      engine.failNextOpens.add(StateError('refused ${_config.apiKey}'));

      await stall(engine, timers);
      await pumpEventQueue();

      expect(controller.state.failure, isNot(contains(_config.apiKey)));
      expect(controller.state.failure, contains('***'));
    });
  });
}
