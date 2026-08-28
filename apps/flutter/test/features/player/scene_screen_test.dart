import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/scene_controller.dart';
import 'package:stash_player_flutter/features/player/scene_screen.dart';
import 'package:stash_player_flutter/services/external_url_launcher.dart';
import 'package:stash_player_flutter/services/stash_api.dart';

import '../../support/fake_playback_engine.dart';
import '../../support/fakes.dart';

const _connection = ConnectionConfig(
  serverUrl: 'https://stash.test',
  apiKey: 'secret-key',
);

Scene _scene({
  String id = 's1',
  String? title,
  String? details,
  String? date,
  int? rating100,
  List<SceneFile> files = const [],
  StudioRef? studio,
  List<PerformerRef> performers = const [],
  String stream = 'stream.mp4',
}) => Scene(
  id: id,
  paths: ScenePaths(stream: stream),
  title: title,
  details: details,
  date: date,
  rating100: rating100,
  files: files,
  studio: studio,
  performers: performers,
);

/// One recorded `findScene` call with its own completer, so a test can
/// resolve or reject requests individually and out of order — mirrors
/// `FakeStashApi`'s own `FindScenesCall` in `test/support/fakes.dart`, but
/// kept local to this file (rather than extending the shared fake) since
/// only `findScene` support is needed here and the brief's own file list
/// scopes this task's test changes to `scene_screen_test.dart` alone.
class _FindSceneCall {
  _FindSceneCall(this.id);
  final String id;
  final Completer<Scene?> completer = Completer<Scene?>();
}

/// A [StashApi] test double supporting a controllable `findScene` (via
/// [calls]) plus harmless no-op successes for the other members —
/// `PlaybackController`'s own `ActivitySync` resolves `stashApiProvider`
/// for `saveSceneActivity` on every flush/dispose, so that member must
/// succeed rather than throw `UnimplementedError` for these widget tests.
class _TestStashApi implements StashApi {
  final List<_FindSceneCall> calls = [];
  final List<Failure> findSceneFailures = [];
  final List<Object> findSceneRawErrors = [];

  @override
  Future<Scene?> findScene(String id) {
    final call = _FindSceneCall(id);
    calls.add(call);
    if (findSceneRawErrors.isNotEmpty) {
      call.completer.completeError(findSceneRawErrors.removeAt(0));
    } else if (findSceneFailures.isNotEmpty) {
      call.completer.completeError(findSceneFailures.removeAt(0));
    }
    return call.completer.future;
  }

  @override
  Future<String> version() async => 'v0.31.0';

  @override
  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  }) async => ScenePage(total: 0, scenes: const []);

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) async {}
}

class _RecordingUrlLauncher implements ExternalUrlLauncher {
  final List<Uri> opened = [];
  bool result = true;

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return result;
  }
}

class _TestHarness {
  _TestHarness({
    required this.container,
    required this.engines,
    required this.api,
    required this.launcher,
  });

  final ProviderContainer container;
  final List<FakePlaybackEngine> engines;
  final _TestStashApi api;
  final _RecordingUrlLauncher launcher;

  FakePlaybackEngine get engine => engines.single;
}

_TestHarness _harness({ConnectionConfig connection = _connection}) {
  final engines = <FakePlaybackEngine>[];
  final api = _TestStashApi();
  final launcher = _RecordingUrlLauncher();
  final container = ProviderContainer(
    overrides: [
      connectionStoreProvider.overrideWithValue(
        FakeConnectionStore(saved: connection),
      ),
      environmentProvider.overrideWithValue(const {}),
      stashApiFactoryProvider.overrideWithValue((config) => api),
      playbackEngineFactoryProvider.overrideWithValue(() {
        final engine = FakePlaybackEngine();
        engines.add(engine);
        return engine;
      }),
      externalUrlLauncherProvider.overrideWithValue(launcher),
    ],
  );
  return _TestHarness(
    container: container,
    engines: engines,
    api: api,
    launcher: launcher,
  );
}

Widget _app(ProviderContainer container, String sceneId) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: SceneScreen(sceneId: sceneId)),
    );

Future<void> _pumpReadyScene(
  WidgetTester tester,
  _TestHarness harness,
  Scene scene, {
  bool play = true,
}) async {
  await tester.pumpWidget(_app(harness.container, scene.id));
  await tester.pump();
  harness.api.calls.single.completer.complete(scene);
  await tester.pumpAndSettle();
  if (play) {
    harness.engine.emitPlaying(true);
    // Two pumps: one to flush the broadcast stream's microtask delivery
    // into `PlaybackController`'s own state (and `notifyListeners()`),
    // and one more for the resulting rebuild — chaining through
    // `ref.listen`'s activity-registration callback — to actually land.
    await tester.pump();
    await tester.pump();
  }
}

/// Stops the engine's own `playing` stream at the *end* of a test that
/// left it active — `addTearDown` runs too late for this: Flutter's own
/// end-of-test `!timersPending` invariant check happens before any
/// `addTearDown` callback, so `harness.container.dispose()` alone can
/// never stop `ActivitySync`'s periodic timer (started by
/// `PlaybackController` while `playing && !buffering`) in time. Disposing
/// the whole `PlaybackController` would cancel it too, but that disposal
/// chain is itself documented (Task 10) as unable to complete inside a
/// widget test's implicit `fakeAsync` zone — cancelling activity the
/// *ordinary* way (a genuine pause, exactly like a real user's) is both
/// simpler and closer to what a real app does before a scene closes.
Future<void> _stopPlayback(WidgetTester tester, _TestHarness harness) async {
  harness.engine.emitPlaying(false);
  await tester.pump();
}

/// The controls overlay's current opacity — `1.0` fully visible, `0.0`
/// auto-hidden. The overlay hides via `AnimatedOpacity` (plus
/// `IgnorePointer`), never by removing the widget from the tree, so
/// `find.byTooltip(...)` alone can't distinguish "visible" from
/// "auto-hidden but still present" — this reads the actual opacity value
/// instead.
double _controlsOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.byKey(const Key('scene-controls-overlay')))
    .opacity;

void main() {
  group('resolveStashSceneUrl', () {
    test('resolves /scenes/<id> against the configured server', () {
      final uri = resolveStashSceneUrl('https://stash.test', '123');
      expect(uri.toString(), 'https://stash.test/scenes/123');
    });

    test('percent-encodes a scene id with special characters', () {
      final uri = resolveStashSceneUrl('https://stash.test', 'a b/c');
      expect(uri.pathSegments, ['scenes', 'a b/c']);
      expect(uri.toString(), isNot(contains(' ')));
    });

    test('strips any apikey already embedded in the base URL', () {
      final uri = resolveStashSceneUrl(
        'https://stash.test?apikey=leaked-secret',
        '123',
      );
      expect(uri.toString(), isNot(contains('apikey')));
      expect(uri.toString(), isNot(contains('leaked-secret')));
      expect(uri.pathSegments, ['scenes', '123']);
    });

    test('preserves a base URL with an existing path prefix', () {
      final uri = resolveStashSceneUrl('https://stash.test/app', '123');
      expect(uri.pathSegments, ['app', 'scenes', '123']);
    });
  });

  group('SceneController', () {
    test('initial state is initial with no scene', () {
      final controller = _makeSceneController();
      expect(controller.state.phase, ScenePhase.initial);
      expect(controller.state.scene, isNull);
      expect(controller.state.generation, 0);
    });

    test(
      'load: loading then ready, and hands the scene to PlaybackController',
      () async {
        final calls = <String>[];
        final scene = _scene(stream: 'the-stream.mp4');
        final built = _makeSceneControllerWithEngine(
          findScene: (id) async {
            calls.add(id);
            return scene;
          },
        );

        final future = built.controller.load('s1');
        expect(built.controller.state.phase, ScenePhase.loading);
        await future;
        // `loadScene` is fired-and-forget (SceneController's own `ready`
        // transition doesn't wait for playback) — let it settle.
        await pumpEventQueue();

        expect(built.controller.state.phase, ScenePhase.ready);
        expect(built.controller.state.scene, scene);
        expect(calls, ['s1']);
        // Proof the scene was actually handed to PlaybackController: it
        // opened the stream URL derived from *this* scene.
        expect(
          built.engine.commands.whereType<OpenCommand>().single.uri.toString(),
          contains('the-stream.mp4'),
        );
      },
    );

    test('load: a null result maps to NotFoundFailure', () async {
      final controller = _makeSceneController(findScene: (id) async => null);

      await controller.load('missing');

      expect(controller.state.phase, ScenePhase.notFound);
      expect(controller.state.failure, isA<NotFoundFailure>());
      expect(controller.state.sceneId, 'missing');
    });

    test('load: a thrown Failure is surfaced as failed', () async {
      final controller = _makeSceneController(
        findScene: (id) async => throw const TransportFailure('down'),
      );

      await controller.load('s1');

      expect(controller.state.phase, ScenePhase.failed);
      expect(controller.state.failure, isA<TransportFailure>());
    });

    test('load: a bare non-Failure error also surfaces as failed', () async {
      final controller = _makeSceneController(
        findScene: (id) async => throw StateError('boom'),
      );

      await controller.load('s1');

      expect(controller.state.phase, ScenePhase.failed);
      expect(controller.state.failure, isA<TransportFailure>());
    });

    test('retry repeats the same id', () async {
      final calls = <String>[];
      var succeed = false;
      final scene = _scene(id: 'x');
      final controller = _makeSceneController(
        findScene: (id) async {
          calls.add(id);
          if (!succeed) throw const TransportFailure();
          return scene;
        },
      );

      await controller.load('x');
      expect(controller.state.phase, ScenePhase.failed);

      succeed = true;
      await controller.retry();

      expect(controller.state.phase, ScenePhase.ready);
      expect(calls, ['x', 'x']);
    });

    test('retry is a no-op when not failed/notFound', () async {
      final calls = <String>[];
      final controller = _makeSceneController(
        findScene: (id) async {
          calls.add(id);
          return _scene(id: id);
        },
      );

      await controller.load('a');
      expect(controller.state.phase, ScenePhase.ready);

      await controller.retry();

      expect(calls, ['a']); // not called again
    });

    test(
      'late result rejected: a superseded load cannot clobber a newer one',
      () async {
        final completers = <String, Completer<Scene?>>{
          'a': Completer<Scene?>(),
          'b': Completer<Scene?>(),
        };
        final controller = _makeSceneController(
          findScene: (id) => completers[id]!.future,
        );

        final firstLoad = controller.load('a');
        final secondLoad = controller.load('b');

        // Resolve the *older* request after the newer one has already been
        // issued — its generation must no longer match.
        completers['a']!.complete(_scene(id: 'a'));
        await firstLoad;
        expect(controller.state.phase, ScenePhase.loading);
        expect(controller.state.sceneId, 'b');

        completers['b']!.complete(_scene(id: 'b'));
        await secondLoad;

        expect(controller.state.phase, ScenePhase.ready);
        expect(controller.state.scene!.id, 'b');
      },
    );

    test(
      'back-to-back load calls (no await between them) each claim a distinct '
      'generation',
      () async {
        final completers = <String, Completer<Scene?>>{
          'a': Completer<Scene?>(),
          'b': Completer<Scene?>(),
        };
        final controller = _makeSceneController(
          findScene: (id) => completers[id]!.future,
        );

        // No `await` between these two calls — both synchronous prefixes
        // run before either suspends at its first `await`.
        final firstLoad = controller.load('a');
        final secondLoad = controller.load('b');
        expect(controller.state.generation, 2);

        completers['b']!.complete(_scene(id: 'b'));
        completers['a']!.complete(_scene(id: 'a'));
        await Future.wait([firstLoad, secondLoad]);

        expect(controller.state.scene!.id, 'b');
      },
    );

    test('dispose calls the injected releasePlayback hook exactly once', () {
      var releaseCalls = 0;
      final controller = _makeSceneController(
        releasePlayback: () => releaseCalls++,
      );

      controller.dispose();
      controller.dispose();

      expect(releaseCalls, 1);
    });

    test('a load response landing after dispose does not throw and does not '
        'apply', () async {
      final completer = Completer<Scene?>();
      final controller = _makeSceneController(
        findScene: (id) => completer.future,
      );

      final future = controller.load('a');
      controller.dispose();
      completer.complete(_scene(id: 'a'));

      await future; // must not throw
      expect(controller.state.phase, ScenePhase.loading); // unapplied
    });
  });

  group('SceneScreen: metadata drawer does not resize the video', () {
    for (final size in [const Size(1400, 900), const Size(500, 700)]) {
      testWidgets('at ${size.width}x${size.height}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);

        final beforeSize = tester.getSize(
          find.byKey(const Key('player-video')),
        );

        await tester.tap(find.byTooltip('Show details'));
        await tester.pumpAndSettle();

        final afterSize = tester.getSize(find.byKey(const Key('player-video')));

        expect(afterSize, beforeSize);
        await _stopPlayback(tester, harness);
      });
    }
  });

  group('SceneScreen: metadata fallbacks', () {
    testWidgets('safe fallbacks render when every optional field is absent', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene(files: const []);
      await _pumpReadyScene(tester, harness, scene);

      await tester.tap(find.byTooltip('Show details'));
      await tester.pumpAndSettle();

      expect(find.text('No description available.'), findsOneWidget);
      expect(find.text('Unknown date'), findsOneWidget);
      expect(find.textContaining('Unknown'), findsWidgets);
      await _stopPlayback(tester, harness);
    });

    testWidgets('populated fields render their real values', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene(
        title: 'A Real Title',
        details: 'Some details.',
        date: '2024-01-02',
        studio: const StudioRef(id: 'st1', name: 'Acme Studio'),
        performers: const [PerformerRef(id: 'p1', name: 'Jane Doe')],
        files: const [
          SceneFile(
            duration: 125,
            width: 1920,
            height: 1080,
            videoCodec: 'h264',
            frameRate: 30,
          ),
        ],
      );
      await _pumpReadyScene(tester, harness, scene);

      await tester.tap(find.byTooltip('Show details'));
      await tester.pumpAndSettle();

      expect(find.text('A Real Title'), findsWidgets);
      expect(find.text('Some details.'), findsOneWidget);
      expect(find.text('2024-01-02'), findsOneWidget);
      expect(find.text('Acme Studio'), findsOneWidget);
      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.textContaining('1920'), findsOneWidget);
      expect(find.textContaining('h264'), findsOneWidget);
      expect(find.textContaining('30'), findsOneWidget);
      await _stopPlayback(tester, harness);
    });
  });

  group('SceneScreen: transport controls', () {
    testWidgets('exposes play/pause, seek, volume, mute, fullscreen, and '
        'metadata controls with tooltips', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byKey(const Key('scene-seek-bar')), findsOneWidget);
      expect(find.byKey(const Key('scene-volume-slider')), findsOneWidget);
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(find.byTooltip('Fullscreen'), findsOneWidget);
      expect(find.byTooltip('Show details'), findsOneWidget);
    });

    testWidgets('play/pause button toggles playback via the controller', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();

      expect(harness.engine.commands.whereType<PlayCommand>(), isNotEmpty);
    });
  });

  group('SceneScreen: auto-hide', () {
    testWidgets('controls stay visible while paused', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      await tester.pump(const Duration(seconds: 5));

      expect(_controlsOpacity(tester), 1.0);
    });

    testWidgets('controls stay visible while buffering', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);
      harness.engine.emitBuffering(true);
      await tester.pump();

      await tester.pump(const Duration(seconds: 5));

      expect(_controlsOpacity(tester), 1.0);
    });

    testWidgets(
      'controls auto-hide after 3 seconds while playing with no activity',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);

        expect(_controlsOpacity(tester), 1.0);

        await tester.pump(const Duration(seconds: 4));

        expect(_controlsOpacity(tester), 0.0);
        await _stopPlayback(tester, harness);
      },
    );

    testWidgets('pointer movement resets the auto-hide timer', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);

      await tester.pump(const Duration(seconds: 2));
      expect(_controlsOpacity(tester), 1.0);

      // Move the mouse over the video surface — should reset the timer.
      // The pointer is removed again immediately afterward so later pumps
      // in this test can't keep re-triggering `onHover` from a mouse that
      // never left.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('player-video'))),
      );
      await tester.pump();
      await gesture.removePointer();
      await tester.pump();

      await tester.pump(const Duration(seconds: 2));
      // Only 2s have elapsed since the reset — still visible.
      expect(_controlsOpacity(tester), 1.0);

      await tester.pump(const Duration(seconds: 2));
      expect(_controlsOpacity(tester), 0.0);
      await _stopPlayback(tester, harness);
    });

    testWidgets('a keyboard action reveals controls and resets the timer', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);

      await tester.pump(const Duration(seconds: 4));
      expect(_controlsOpacity(tester), 0.0);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();

      expect(_controlsOpacity(tester), 1.0);
      expect(find.byTooltip('Unmute'), findsOneWidget);
      await _stopPlayback(tester, harness);
    });

    testWidgets('metadata being open suppresses auto-hide', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);

      await tester.tap(find.byTooltip('Show details'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 5));

      expect(_controlsOpacity(tester), 1.0);
      await _stopPlayback(tester, harness);
    });
  });

  group('SceneScreen: playback failure recovery', () {
    testWidgets(
      'a playback failure before the video ever played keeps metadata '
      'reachable and shows Retry and Open in Stash',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await tester.pumpWidget(_app(harness.container, scene.id));
        await tester.pump();
        harness.api.calls.single.completer.complete(scene);
        await tester.pump();
        await tester.pump();

        harness.engine.emitError('stream unavailable');
        await tester.pump();
        await tester.pump();

        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Open in Stash'), findsWidgets);
        // Metadata is still reachable over the black surface.
        expect(find.byTooltip('Show details'), findsOneWidget);
      },
    );

    testWidgets('Retry re-loads the scene', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await tester.pumpWidget(_app(harness.container, scene.id));
      await tester.pump();
      harness.api.calls.single.completer.complete(scene);
      await tester.pump();
      await tester.pump();
      harness.engine.emitError('stream unavailable');
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(harness.api.calls, hasLength(2));
    });

    testWidgets(
      'Open in Stash resolves /scenes/<id> against the configured server '
      'with no apikey, and never opens an authenticated URL',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene(id: 'scene 42');
        await tester.pumpWidget(_app(harness.container, scene.id));
        await tester.pump();
        harness.api.calls.single.completer.complete(scene);
        await tester.pump();
        await tester.pump();
        harness.engine.emitError('stream unavailable');
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Open in Stash').first);
        await tester.pump();
        await tester.pump();

        expect(harness.launcher.opened, hasLength(1));
        final uri = harness.launcher.opened.single;
        // `pathSegments` auto-decodes, so this is robust to exactly which
        // percent-encoding scheme was used for the embedded space.
        expect(uri.pathSegments, ['scenes', 'scene 42']);
        expect(uri.toString(), isNot(contains('apikey')));
        expect(uri.host, 'stash.test');
      },
    );

    testWidgets(
      'a transient failure after the video already played does not cover '
      'the video with a full error state',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);
        harness.engine.emitDuration(const Duration(seconds: 120));
        await tester.pump();

        // Simulate a failed volume nudge: the engine reports an error while
        // duration (and thus a once-successful open) is already known.
        harness.engine.emitError('setVolume failed');
        await tester.pump();
        await tester.pump();

        // The video surface and transport controls are still there — no
        // full-screen failure overlay took over.
        expect(find.byKey(const Key('player-video')), findsOneWidget);
        expect(find.byTooltip('Pause'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        // The failure is still surfaced, just non-modally.
        final notice = harness.container.read(globalNoticeProvider);
        expect(notice, isNotNull);
        expect(notice!.severity, AppNoticeSeverity.warning);
        await _stopPlayback(tester, harness);
      },
    );
  });

  group('SceneScreen: fullscreen shortcut', () {
    testWidgets('Escape exits fullscreen', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);

      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.byTooltip('Fullscreen'), findsOneWidget);
      await _stopPlayback(tester, harness);
    });

    testWidgets('space toggles play/pause the same as the button', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(harness.engine.commands.whereType<PlayCommand>(), isNotEmpty);
    });
  });

  group('PlayerActionShortcuts: text-entry propagation (I7)', () {
    // `engine`/`controller` are deliberately constructed *inside* each
    // `testWidgets` body below, never in a shared `setUp()`. `setUp()`
    // runs outside `testWidgets`' own `FakeAsync` zone (that zone is
    // entered only once the test body callback itself starts), so a
    // `PlaybackController` — and the real `ActivitySync` it builds
    // internally, whose `_flushTail` starts life as a `Future<void>.value()`
    // — built in `setUp()` has that future's completion scheduled against
    // the *real* zone's microtask queue. `loadScene`'s `await
    // _activitySync.replaceScene(...)` chains onto that same future from
    // *inside* the test body's `FakeAsync` zone, which never yields back
    // to the real event loop while its own synchronous callback is still
    // running — a genuine cross-zone deadlock, verified empirically (a
    // minimal repro hangs forever at exactly that `await`, while the
    // identical construction done inline in the test body does not).
    _TextEntryHarness makeHarness() {
      final engine = FakePlaybackEngine();
      final controller = PlaybackController(
        engine: engine,
        resolveConnection: () async => _connection,
        setFullscreenPlatform: (value) async => true,
      );
      return _TextEntryHarness(engine, controller, TextEditingController());
    }

    Future<void> pumpTextField(
      WidgetTester tester,
      _TextEntryHarness harness,
    ) async {
      await harness.controller.loadScene(_scene());
      final fieldFocusNode = FocusNode();
      addTearDown(fieldFocusNode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerActionShortcuts(
              controller: harness.controller,
              child: Center(
                child: TextField(
                  controller: harness.textController,
                  focusNode: fieldFocusNode,
                ),
              ),
            ),
          ),
        ),
      );
      // No `autofocus` on either the field or `PlayerActionShortcuts`'
      // own wrapping `Focus` here — two competing autofocus requests in
      // the same frame is exactly the setup this test exists to probe,
      // and requesting focus explicitly, one frame at a time, keeps that
      // variable out of the result.
      fieldFocusNode.requestFocus();
      await tester.pump();
      harness.engine.commands.clear();
    }

    testWidgets(
      'j/k/l/m/f do not fire player actions while a text field has focus, '
      'and the field still accepts normal text entry',
      (tester) async {
        final harness = makeHarness();
        await pumpTextField(tester, harness);

        // Empirical finding (this is the actual settling of Task 9's I7
        // question, not just reasoning about it): `tester.sendKeyEvent`
        // with a `character:` never inserts a character into a focused
        // `TextField` in this headless test environment at all — checked
        // independently of any gating, real key-simulated character
        // entry goes through the platform's separate `TextInputClient`/
        // IME channel, not raw hardware `KeyEvent`s. So the meaningful,
        // checkable property for J/K/L/M/F is that the *player action*
        // never fires while a text field is focused — proven directly
        // against `engine.commands` below — not that a character
        // "shows up", which `sendKeyEvent` can't demonstrate either way.
        for (final key in [
          LogicalKeyboardKey.keyJ,
          LogicalKeyboardKey.keyK,
          LogicalKeyboardKey.keyL,
          LogicalKeyboardKey.keyM,
          LogicalKeyboardKey.keyF,
        ]) {
          await tester.sendKeyEvent(key, character: key.keyLabel.toLowerCase());
          await tester.pump();
        }
        expect(harness.engine.commands, isEmpty);

        // Sanity check that `PlayerActionShortcuts` hasn't broken normal
        // text entry outright: `enterText` drives the real
        // `TextInputClient` channel (the same path a real IME commit
        // uses), independent of `Shortcuts`/`KeyEvent` entirely.
        await tester.enterText(find.byType(TextField), 'jklmf');
        expect(harness.textController.text, 'jklmf');
      },
    );

    testWidgets('arrows/Home/End move the caret rather than seeking', (
      tester,
    ) async {
      final harness = makeHarness();
      await pumpTextField(tester, harness);
      harness.textController.text = 'hello';
      await tester.pump();
      harness.textController.selection = const TextSelection.collapsed(
        offset: 5,
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();

      expect(harness.engine.commands.whereType<SeekCommand>(), isEmpty);
      // Comparing just `.baseOffset` (not the whole `TextSelection`,
      // whose `affinity` a caret move to the very end of the text sets
      // to `upstream` rather than the `downstream` a bare
      // `TextSelection.collapsed(...)` literal defaults to) — the
      // property this test cares about is *where* the caret landed, not
      // which way it's leaning.
      expect(harness.textController.selection.baseOffset, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();

      expect(harness.engine.commands.whereType<SeekCommand>(), isEmpty);
      expect(harness.textController.selection.baseOffset, 5);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(harness.engine.commands.whereType<SeekCommand>(), isEmpty);
      expect(harness.textController.selection.baseOffset, 4);
    });

    testWidgets('space does not toggle play/pause while a text field has '
        'focus', (tester) async {
      final harness = makeHarness();
      await pumpTextField(tester, harness);

      await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.pump();

      // Same `sendKeyEvent` character-insertion caveat as the J/K/L/M/F
      // test above applies here too — this asserts the property that's
      // actually checkable: space's bound action (`togglePlayPause`)
      // never reaches the engine while a text field is focused.
      expect(harness.engine.commands.whereType<PlayCommand>(), isEmpty);
      expect(harness.engine.commands.whereType<PauseCommand>(), isEmpty);
    });
  });
}

class _TextEntryHarness {
  _TextEntryHarness(this.engine, this.controller, this.textController);
  final FakePlaybackEngine engine;
  final PlaybackController controller;
  final TextEditingController textController;
}

SceneController _makeSceneController({
  FindScene? findScene,
  VoidCallback? releasePlayback,
}) => _makeSceneControllerWithEngine(
  findScene: findScene,
  releasePlayback: releasePlayback,
).controller;

class _SceneControllerAndEngine {
  _SceneControllerAndEngine(this.controller, this.engine);
  final SceneController controller;
  final FakePlaybackEngine engine;
}

_SceneControllerAndEngine _makeSceneControllerWithEngine({
  FindScene? findScene,
  VoidCallback? releasePlayback,
}) {
  final engine = FakePlaybackEngine();
  final playback = PlaybackController(
    engine: engine,
    resolveConnection: () async => _connection,
    setFullscreenPlatform: (value) async => true,
  );
  final controller = SceneController(
    findScene: findScene ?? (id) async => _scene(id: id),
    playback: playback,
    releasePlayback: releasePlayback ?? () {},
  );
  return _SceneControllerAndEngine(controller, engine);
}
