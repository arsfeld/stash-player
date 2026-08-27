import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/services/authenticated_url.dart';

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
}) => Scene(
  id: id,
  paths: ScenePaths(stream: stream),
  resumeTime: resumeTime,
  files: withFile ? [SceneFile(duration: duration)] : const [],
);

PlaybackController _buildController({
  required FakePlaybackEngine engine,
  ConnectionConfig config = _config,
  Future<void> Function()? onFlushActivity,
  Future<bool> Function(bool fullscreen)? setFullscreenPlatform,
}) => PlaybackController(
  engine: engine,
  resolveConnection: () async => config,
  onFlushActivity: onFlushActivity,
  setFullscreenPlatform: setFullscreenPlatform ?? (value) async => true,
);

void main() {
  group('loadScene resume rule', () {
    test('null resume does not seek', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(duration: 2000));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
      expect(controller.state.phase, PlaybackPhase.ready);
    });

    test('zero resume does not seek', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 0, duration: 2000));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
    });

    test('a middle resume seeks to that exact position', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 500, duration: 2000));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 500),
      );
    });

    test('a resume within the final 10 seconds restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 92, duration: 100));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
    });

    test('a resume at/above 97 percent restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 970, duration: 1000));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
    });

    test('a resume beyond the known duration restarts at zero', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 150, duration: 100));

      expect(engine.commands.whereType<SeekCommand>(), isEmpty);
    });

    test('a positive resume with unknown duration still seeks', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(_sceneWith(resumeTime: 500, withFile: false));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 500),
      );
    });
  });

  group('loadScene ordering and authentication', () {
    test('the stream URL is authenticated before open, and the resume seek '
        'happens after open but before play', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);

      await controller.loadScene(
        _sceneWith(stream: 'video/stream.mp4', resumeTime: 500, duration: 2000),
      );

      expect(engine.commands, hasLength(3));
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
      expect(
        (engine.commands[1] as SeekCommand).position,
        const Duration(seconds: 500),
      );
      expect(engine.commands[2], isA<PlayCommand>());
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

        await controller.loadScene(_sceneWith());

        expect(controller.state.phase, PlaybackPhase.failed);
        expect(controller.state.failure, isNot(contains('super-secret')));
      },
    );
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
        onFlushActivity: () async {
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

    test('omitting onFlushActivity defaults to a no-op', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith(duration: 2000));

      await controller.seekAbsolute(const Duration(seconds: 30));

      expect(
        engine.commands.whereType<SeekCommand>().single.position,
        const Duration(seconds: 30),
      );
    });
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

    test('exitFullscreen action does nothing when not fullscreen', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_sceneWith());

      await controller.handleAction(PlayerAction.exitFullscreen);

      expect(controller.state.fullscreen, isFalse);
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

    test(
      'a stream event from a superseded generation does not land on the new scene',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith(id: 'a', duration: 2000));

        final future = controller.loadScene(
          _sceneWith(id: 'b', duration: 2000),
        );
        engine.emitPosition(const Duration(seconds: 999));
        await future;

        expect(controller.state.position, isNot(const Duration(seconds: 999)));
      },
    );
  });

  group('disposal', () {
    test(
      'flushes activity before disposing the engine, exactly once',
      () async {
        final engine = FakePlaybackEngine();
        var flushCalls = 0;
        final controller = _buildController(
          engine: engine,
          onFlushActivity: () async {
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

    test(
      'omitting onFlushActivity defaults to a no-op that does not throw',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith());

        await controller.dispose();

        expect(engine.isDisposed, isTrue);
      },
    );

    test(
      'commands issued after dispose are no-ops, never reaching the engine',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_sceneWith(duration: 2000));
        await controller.dispose();

        // None of these may throw, and none may reach the (disposed) fake
        // engine, which would itself throw a StateError if they did.
        await controller.playPause();
        await controller.seekAbsolute(const Duration(seconds: 10));
        await controller.seekRelative(const Duration(seconds: 10));
        await controller.setVolume(0.2);
        await controller.toggleMute();
        await controller.setFullscreen(true);
        await controller.loadScene(_sceneWith(id: 'late'));
      },
    );
  });

  group('playbackControllerProvider', () {
    ProviderContainer buildContainer({
      ConnectionConfig saved = _config,
      required FakePlaybackEngine engine,
    }) {
      final container = ProviderContainer(
        overrides: [
          connectionStoreProvider.overrideWithValue(
            FakeConnectionStore(saved: saved),
          ),
          environmentProvider.overrideWithValue(const {}),
          playbackEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the provided controller resolves the connection through the '
        'deferred effectiveConnectionProvider', () async {
      final engine = FakePlaybackEngine();
      final container = buildContainer(engine: engine);

      final controller = container.read(playbackControllerProvider.notifier);
      await controller.loadScene(_sceneWith());

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(engine.commands, isNotEmpty);
    });

    test('bumping connectionGenerationProvider yields a fresh controller, '
        'discarding the old one and disposing its engine', () async {
      final engine = FakePlaybackEngine();
      final container = buildContainer(engine: engine);

      final firstController = container.read(
        playbackControllerProvider.notifier,
      );
      await firstController.loadScene(_sceneWith());
      expect(firstController.state.phase, PlaybackPhase.ready);

      container.read(connectionGenerationProvider.notifier).state++;

      final secondController = container.read(
        playbackControllerProvider.notifier,
      );

      expect(identical(firstController, secondController), isFalse);
      expect(secondController.state.phase, PlaybackPhase.initial);
      expect(secondController.state.generation, 0);
      // The old controller's dispose() (triggered by the provider
      // rebuild) is fire-and-forget from Riverpod's perspective; give its
      // async teardown a chance to run before asserting on it.
      await Future<void>.delayed(Duration.zero);
      expect(engine.isDisposed, isTrue);
    });
  });
}
