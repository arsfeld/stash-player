import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/browse_context.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_engine.dart';
import 'package:stash_player_flutter/features/player/player_icon_button.dart';
import 'package:stash_player_flutter/features/player/scene_controller.dart';
import 'package:stash_player_flutter/features/player/scene_metadata_drawer.dart';
import 'package:stash_player_flutter/features/player/scene_screen.dart';
import 'package:stash_player_flutter/services/external_url_launcher.dart';
import 'package:stash_player_flutter/services/stash_api.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';

import '../../support/contrast.dart';
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
  int? oCounter,
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
  oCounter: oCounter,
);

/// One recorded `findScene` call with its own completer, so a test can
/// resolve or reject requests individually and out of order. Mirrors
/// `FakeStashApi`'s own `FindScenesCall` in `test/support/fakes.dart`,
/// but kept local to this file rather than extending the shared fake:
/// only `findScene` support is needed here.
class _FindSceneCall {
  _FindSceneCall(this.id);
  final String id;
  final Completer<Scene?> completer = Completer<Scene?>();
}

/// A [StashApi] test double supporting a controllable `findScene` (via
/// [calls]) and `findScenes` (via [pages]/[findScenesCalls]) plus
/// harmless no-op successes for the other members:
/// `PlaybackController`'s own `ActivitySync` resolves `stashApiProvider`
/// for `saveSceneActivity` on every flush/dispose, so that member must
/// succeed rather than throw `UnimplementedError` for these widget tests.
class _TestStashApi implements StashApi {
  final List<_FindSceneCall> calls = [];
  final List<Failure> findSceneFailures = [];
  final List<Object> findSceneRawErrors = [];

  /// `findScenes` results consumed in call order, for the prev/next page
  /// fetches `SceneController._step` issues. Mirrors `findScene`'s own
  /// "no landmine" default this class already documents above: a call
  /// made with nothing queued never settles rather than throwing, so a
  /// test that doesn't need paging never has to stub it.
  final List<ScenePage> pages = [];
  final List<Failure> pageFailures = [];
  final List<FindScenesCall> findScenesCalls = [];

  List<int> get requestedPages =>
      findScenesCalls.map((call) => call.page).toList();

  /// Deliberately always manual, unlike `FakeStashApi.findScenes`
  /// (`test/support/fakes.dart`), which defaults to failing loudly on a
  /// drained queue: **every** success in this file resolves a specific
  /// `_FindSceneCall.completer` from [calls] directly (e.g.
  /// `_pumpReadyScene`'s `harness.api.calls.single.completer.complete
  /// (scene)`), so there is no "queue" mode here to accidentally drain —
  /// [findSceneFailures]/[findSceneRawErrors] only cover the failure
  /// path. A call made with neither queued intentionally returns a never
  /// -settling future for the caller to complete; that is this class's
  /// only mode, not a landmine (final review §3b).
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
  }) {
    final call = FindScenesCall(filter: filter, page: page, perPage: perPage);
    findScenesCalls.add(call);
    if (pageFailures.isNotEmpty) {
      call.completer.completeError(pageFailures.removeAt(0));
    } else if (pages.isNotEmpty) {
      call.completer.complete(pages.removeAt(0));
    }
    return call.completer.future;
  }

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) async {}

  @override
  Future<int> incrementO(String id) async => 0;

  @override
  Future<int> resetO(String id) async => 0;
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

/// Wraps a [FakePlaybackEngine] but always throws from `setVolume` —
/// fix round 1, item 5's mutation check that a control-command failure
/// genuinely goes through `_runEngineCommand`'s new `controlFailure`
/// channel end-to-end (through the real provider graph, not just
/// `PlaybackController` in isolation, which `playback_controller_test.dart`
/// already covers directly).
class _ThrowingSetVolumeEngine implements PlaybackEngine {
  _ThrowingSetVolumeEngine(this._inner);
  final FakePlaybackEngine _inner;

  @override
  Stream<bool> get playing => _inner.playing;
  @override
  Stream<bool> get buffering => _inner.buffering;
  @override
  Stream<Duration> get position => _inner.position;
  @override
  Stream<Duration> get duration => _inner.duration;
  @override
  Stream<String> get errors => _inner.errors;
  @override
  Widget buildVideoSurface({Key? key}) => _inner.buildVideoSurface(key: key);
  @override
  Future<void> open(Uri uri, {bool play = false}) =>
      _inner.open(uri, play: play);
  @override
  Future<void> play() => _inner.play();
  @override
  Future<void> pause() => _inner.pause();
  @override
  Future<void> seek(Duration position) => _inner.seek(position);
  @override
  Future<void> setVolume(double zeroToOne) async =>
      throw StateError('setVolume failed');
  @override
  Future<void> setMuted(bool muted) => _inner.setMuted(muted);
  @override
  Future<void> dispose() => _inner.dispose();
}

_TestHarness _harness({
  ConnectionConfig connection = _connection,
  PlaybackEngine Function(FakePlaybackEngine inner)? wrapEngine,
}) {
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
      playbackEngineFactoryProvider.overrideWithValue(({httpProxyUrl}) {
        final engine = FakePlaybackEngine();
        engines.add(engine);
        return wrapEngine == null ? engine : wrapEngine(engine);
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

/// The scene screen under the app's own theme.
///
/// Not a bare `MaterialApp`: this file exercises the scene screen, the
/// player bar, the top bar and the metadata drawer, and Flutter's
/// default `ThemeData` is a theme the app never ships, so anything it
/// showed about their appearance would be about the wrong theme. It also
/// carries no `AppTokens`, which every widget under `lib/ui/` needs.
///
/// Light rather than dark because light is the case that breaks: the
/// drawer's panel is always dark, so light is where text taken from the
/// app theme lands on a surface that ignores it. Both brightnesses are
/// covered directly in `scene_metadata_drawer_test.dart`.
Widget _app(
  ProviderContainer container,
  String sceneId, {
  BrowseContext? browse,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: SceneScreen(sceneId: sceneId, browse: browse),
  ),
);

Future<void> _pumpReadyScene(
  WidgetTester tester,
  _TestHarness harness,
  Scene scene, {
  bool play = true,
  BrowseContext? browse,
}) async {
  await tester.pumpWidget(_app(harness.container, scene.id, browse: browse));
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

/// Genuinely tears the scene down at the end of a test that left playback
/// active, instead of the former `_stopPlayback` workaround (a bare
/// `engine.emitPlaying(false)` that stopped the periodic activity timer
/// but never exercised real disposal at all).
///
/// Unmounting `SceneScreen` — replacing it with a plain `SizedBox` inside
/// the *same* `UncontrolledProviderScope`/`harness.container` — is the
/// real production trigger for `sceneControllerProvider`'s `.autoDispose`:
/// the last watcher (`SceneScreen`'s own `ref.watch`) goes away, so
/// Riverpod tears the controller down exactly as it does on a real route
/// pop, driving the full chain end to end: `SceneController.dispose` ->
/// `releasePlayback` -> invalidating `playbackControllerProvider` ->
/// `PlaybackController.dispose` -> pause -> `ActivitySync.dispose` (its
/// own last flush) -> engine dispose. (Disposing `harness.container`
/// itself, tried first, is the wrong simulation — it also tears down the
/// container's own scheduler, which makes `ref.invalidate` calls
/// triggered mid-teardown silently no-op instead of behaving as they do
/// in the real single-provider-at-a-time autoDispose path.)
///
/// `_stopPlayback` existed because `ActivitySync.dispose`'s old
/// `Future.any([flushSettled.future, _delay(disposeFlushTimeout)])` never
/// cancelled its losing branch: letting a real disposal run to completion
/// inside a widget test left a genuine ~10s `Timer` pending, and Flutter's
/// own end-of-test "a Timer is still pending" check runs *before* any
/// `addTearDown` callback — so relying only on `addTearDown` could never
/// clean that up in time. That is exactly why the real pause -> flush ->
/// engine-dispose path had almost no widget-level coverage (final review
/// I5). Now that `ActivitySync.dispose` cancels its own timeout `Timer`
/// the moment its flush settles (see `activity_sync.dart`), real
/// disposal is safe to exercise here.
///
/// The `tester.runAsync` call is load-bearing, not decoration:
/// `PlaybackController.dispose()` starts as fire-and-forget (Riverpod
/// calls a `ChangeNotifier`'s plain `void dispose()`; this override just
/// happens to return a `Future` a caller *can* await — see that method's
/// own doc), and empirically its `Future.wait([...cancel()...])` and
/// later awaits never resume under `AutomatedTestWidgetsFlutterBinding`'s
/// fake time from `tester.pump()` alone, no matter how many times it's
/// called — `pump()` only drives microtasks tied to the widget frame
/// lifecycle, not an unrelated detached Future chain. Stepping into the
/// *real* zone via `runAsync` (even for a `Duration.zero` delay) lets the
/// chain's own microtasks actually run to completion; the `pump()` calls
/// around it then let the widget tree observe the resulting state.
Future<void> _tearDownScene(WidgetTester tester, _TestHarness harness) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: const SizedBox.shrink(),
    ),
  );
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  expect(
    harness.engine.isDisposed,
    isTrue,
    reason:
        'a real scene teardown must reach PlaybackController.dispose -> '
        'ActivitySync.dispose -> engine.dispose, not just stop the engine '
        'from playing (final review I5)',
  );
}

/// Reduces an [AnimationStatus] to the `1.0`/`0.0` reading
/// [_controlsOpacity] and [_playerBarOpacity] report, matching what
/// `AnimatedOpacity.opacity` (the plain target double this suite read
/// before the two bars shared one `AnimationController`) always gave: the
/// *target* the fade is driving toward, flipped synchronously the instant
/// `AnimationController.forward()`/`.reverse()` is called, not the live
/// interpolated value partway through a still-running transition.
/// `forward`/`reverse` are set synchronously by those calls themselves
/// (confirmed empirically: printing `.status` immediately after calling
/// `.reverse()` already reads `AnimationStatus.reverse`, before any ticker
/// has run a single frame), so this needs no `pumpAndSettle` and no change
/// to any of this suite's pre-existing `expect(_controlsOpacity(tester),
/// 1.0/0.0)` call sites.
double _fadeTargetOpacity(AnimationStatus status) => switch (status) {
  AnimationStatus.forward || AnimationStatus.completed => 1.0,
  AnimationStatus.reverse || AnimationStatus.dismissed => 0.0,
};

/// The top bar's current fade target: `1.0` fully visible, `0.0`
/// auto-hidden. The overlay hides via a `FadeTransition` (plus
/// `IgnorePointer`), never by removing the widget from the tree, so
/// `find.byTooltip(...)` alone can't distinguish "visible" from
/// "auto-hidden but still present"; this reads the fade state instead.
///
/// Both the top bar's and the player bar's `FadeTransition`s read the
/// *same* `AnimationController` (`scene_screen.dart`'s own
/// `_controlsFadeController`), so this value is exactly [_playerBarOpacity]
/// at every point in time by construction, not merely by coincidence of
/// matching inputs. See the "both chrome bars fade from the same
/// animation" test below, which is the one place that structural
/// guarantee is actually asserted (by identity, not just by agreement)
/// rather than assumed.
double _controlsOpacity(WidgetTester tester) => _fadeTargetOpacity(
  tester
      .widget<FadeTransition>(find.byKey(const Key('scene-controls-overlay')))
      .opacity
      .status,
);

/// The player bar's own fade key: distinct from [_controlsOpacity]'s key
/// so a test can tell the two `FadeTransition`s apart, even though both
/// read the same `AnimationController` and so always agree; see
/// [_controlsOpacity]'s own doc.
double _playerBarOpacity(WidgetTester tester) => _fadeTargetOpacity(
  tester
      .widget<FadeTransition>(
        find.byKey(const Key('scene-controls-overlay-player-bar')),
      )
      .opacity
      .status,
);

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

    test('strips HTTP basic-auth credentials embedded in the base URL '
        '(final review I4)', () {
      final uri = resolveStashSceneUrl('https://user:pass@stash.test', '123');
      expect(uri.userInfo, isEmpty);
      expect(uri.toString(), isNot(contains('user')));
      expect(uri.toString(), isNot(contains('pass')));
      expect(uri.toString(), 'https://stash.test/scenes/123');
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

    test('retry after the very first load fails restores the browse context, '
        'not just the scene', () async {
      // The very first `load` for a scene never reaches its own ready
      // branch when it fails, so `browse` was never applied to
      // `SceneState` in the first place (see `load`'s own doc). A
      // retry that drops it here leaves prev/next dead for the rest
      // of the visit, even once the scene loads.
      var succeed = false;
      final controller = _makeSceneController(
        findScene: (id) async {
          if (!succeed) throw const TransportFailure();
          return _scene(id: id);
        },
      );
      const browse = BrowseContext(filter: SceneFilter(), index: 42, total: 90);

      await controller.load('s5', browse: browse);
      expect(controller.state.phase, ScenePhase.failed);
      expect(controller.state.browse, isNull);

      succeed = true;
      await controller.retry(browse: browse);

      expect(controller.state.phase, ScenePhase.ready);
      expect(controller.state.browse, browse);
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

    test('goNext fetches page index + 2 with one scene per page', () async {
      // Stash pages are 1-indexed, so the scene at index N is page N + 1.
      // Stepping from index 7 therefore reads page 9.
      final pages = <int>[];
      final perPages = <int>[];
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async {
          pages.add(page);
          perPages.add(perPage);
          return ScenePage(total: 412, scenes: [_scene(id: 's-$page')]);
        },
      );

      await controller.load(
        's1',
        browse: const BrowseContext(
          filter: SceneFilter(),
          index: 7,
          total: 412,
        ),
      );
      await controller.goNext();

      expect(pages, [9]);
      expect(perPages, [1]);
      expect(controller.state.scene!.id, 's-9');
      expect(controller.state.browse!.index, 8);
    });

    test('a step adopts the fresher total the same response reported, not the '
        'context it started from', () async {
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async =>
            // The ordering shrank to 300 since the browse context below
            // was built with 412 -- the exact shape of an O-counter
            // mutation dropping scenes out of the filter underneath an
            // in-progress browse.
            ScenePage(total: 300, scenes: [_scene(id: 's-$page')]),
      );

      await controller.load(
        's1',
        browse: const BrowseContext(
          filter: SceneFilter(),
          index: 7,
          total: 412,
        ),
      );
      await controller.goNext();

      expect(controller.state.browse!.total, 300);
    });

    test('goPrevious refuses at the start of the ordering', () async {
      var fetches = 0;
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async {
          fetches++;
          return ScenePage(total: 5, scenes: [_scene()]);
        },
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );
      await controller.goPrevious();

      expect(fetches, 0);
    });

    test('a scene reached with no context can step neither way', () async {
      var fetches = 0;
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async {
          fetches++;
          return ScenePage(total: 5, scenes: [_scene()]);
        },
      );

      await controller.load('s1');
      await controller.goNext();
      await controller.goPrevious();

      expect(fetches, 0);
    });

    test('an empty page leaves the current scene in place', () async {
      // The library changed underneath, or total was stale. Staying on a
      // scene that works beats blanking the screen.
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
        findScenes: (filter, {required page, required perPage}) async =>
            ScenePage(total: 5, scenes: const []),
        mutateO: (id, mutation) async => 9,
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );
      // Bumped past the scene's own reported count of 3, so what
      // `_abandonStep` restores can only be the value the controller was
      // actually showing, not a re-read of `scene.oCounter` (which would
      // silently undo this bump).
      await controller.incrementO();
      expect(controller.state.oCount, 9);

      await controller.goNext();

      expect(controller.state.scene!.id, 's1');
      expect(controller.state.browse!.index, 0);
      expect(controller.state.phase, ScenePhase.ready);
      expect(controller.state.navigating, isFalse);
      expect(controller.state.browseFailureSequence, 1);
      expect(controller.state.oCount, 9);
      // An empty page means the library's ordering changed, not that
      // anything actually failed -- the screen must not report this the
      // same way it would report a network outage.
      expect(controller.state.browseFailure, isNull);
    });

    test('oCount is seeded from the loaded scene', () async {
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
      );

      await controller.load('s1');

      expect(controller.state.oCount, 3);
    });

    test('a scene with no reported count still offers a zero', () async {
      // "Loaded but never counted" has to be actionable: incrementing is
      // how it stops being zero.
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
      );

      await controller.load('s1');

      expect(controller.state.oCount, 0);
    });

    test('incrementO shows the server count, never a local guess', () async {
      final calls = <(String, OMutation)>[];
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
        mutateO: (id, mutation) async {
          calls.add((id, mutation));
          // Deliberately not 4: whatever the server says wins, and
          // asserting a value the caller could have guessed would not
          // prove that.
          return 9;
        },
      );

      await controller.load('s1');
      await controller.incrementO();

      expect(calls, [('s1', OMutation.increment)]);
      expect(controller.state.oCount, 9);
    });

    test('resetO resets through the server', () async {
      final calls = <(String, OMutation)>[];
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
        mutateO: (id, mutation) async {
          calls.add((id, mutation));
          return 0;
        },
      );

      await controller.load('s1');
      await controller.resetO();

      expect(calls, [('s1', OMutation.reset)]);
      expect(controller.state.oCount, 0);
    });

    test('a failed bump leaves the displayed count untouched', () async {
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
        mutateO: (id, mutation) async => throw const TransportFailure('down'),
      );

      await controller.load('s1');
      await controller.incrementO();

      expect(controller.state.oCount, 3);
      expect(controller.state.oFailureSequence, 1);
    });

    test('two failed bumps are two observable events', () async {
      // A flag or a message string would collapse a repeat with the same
      // cause into one, and the second failure would look like success.
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
        mutateO: (id, mutation) async => throw const TransportFailure('down'),
      );

      await controller.load('s1');
      await controller.incrementO();
      await controller.incrementO();

      expect(controller.state.oFailureSequence, 2);
    });

    test('two rapid increments: only the later call is ever applied, '
        'regardless of which response lands first', () async {
      final responses = [Completer<int>(), Completer<int>()];
      var mutationCalls = 0;
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id, oCounter: 3),
        mutateO: (id, mutation) => responses[mutationCalls++].future,
      );

      await controller.load('s1');

      final first = controller.incrementO();
      final second = controller.incrementO();

      // The first call's own response lands, but the second call
      // already claimed a newer generation the instant it started
      // (before its own response ever arrived) -- without that claim,
      // both calls would share the same generation and this response
      // would be accepted.
      responses[0].complete(10);
      await first;
      expect(controller.state.oCount, 3);

      responses[1].complete(20);
      await second;
      expect(controller.state.oCount, 20);
    });

    test('a step in flight keeps the outgoing scene mapped while the target '
        'scene metadata is still loading', () async {
      // `_step` delegates to `load` for the target scene, and `load`'s
      // own top-of-function reset would otherwise null out `scene` for
      // the whole round trip, tearing down the video-first stack (see
      // `scene_screen.dart`'s `scene == null` gate) for exactly the
      // window `navigating` exists to cover.
      var findSceneCalls = 0;
      final findScenePending = Completer<Scene?>();
      final controller = _makeSceneController(
        findScene: (id) async {
          findSceneCalls++;
          if (findSceneCalls == 1) return _scene(id: id);
          return findScenePending.future;
        },
        findScenes: (filter, {required page, required perPage}) async =>
            ScenePage(total: 5, scenes: [_scene(id: 's2')]),
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );

      final navigation = controller.goNext();
      // Lets the already-resolved `findScenes` call and the nested
      // `load`'s own synchronous prefix run, up to where it suspends
      // on the still-pending `findScene` call.
      await pumpEventQueue();

      expect(controller.state.navigating, isTrue);
      expect(controller.state.scene!.id, 's1');

      findScenePending.complete(_scene(id: 's2'));
      await navigation;

      expect(controller.state.navigating, isFalse);
      expect(controller.state.scene!.id, 's2');
    });

    test(
      'a step whose target scene is gone reverts to the outgoing scene',
      () async {
        // `_step`'s nested `load` call sets the new (bad) sceneId and
        // browse position before that call discovers the target scene no
        // longer exists. Reverting has to undo all of that together, not
        // just `navigating`, or the controller ends up with `sceneId`
        // pointing at a scene it never actually reached while `scene`
        // still shows the one before it, a mix no other state in this
        // controller ever produces.
        final controller = _makeSceneController(
          findScene: (id) async => id == 's1' ? _scene(id: id) : null,
          findScenes: (filter, {required page, required perPage}) async =>
              ScenePage(total: 5, scenes: [_scene(id: 's2')]),
        );

        await controller.load(
          's1',
          browse: const BrowseContext(
            filter: SceneFilter(),
            index: 0,
            total: 5,
          ),
        );
        await controller.goNext();

        expect(controller.state.phase, ScenePhase.ready);
        expect(controller.state.sceneId, 's1');
        expect(controller.state.scene!.id, 's1');
        expect(controller.state.browse!.index, 0);
        expect(controller.state.navigating, isFalse);
        expect(controller.state.browseFailureSequence, 1);
        // The target scene being gone is the same "ordering changed"
        // story as an empty page, not a genuine failure -- it must not
        // be reported as a network outage.
        expect(controller.state.browseFailure, isNull);
      },
    );

    test('a step whose target scene lookup throws reverts to the outgoing '
        'scene, carrying the real failure rather than reporting a library '
        'change', () async {
      // Same coherence requirement as the since-deleted case above, for
      // the other way a nested `load` can fail to reach `ready` -- plus
      // the failure this abandonment must actually carry (M1): a network
      // outage is not "there is no scene there any more."
      final controller = _makeSceneController(
        findScene: (id) async {
          if (id == 's1') return _scene(id: id);
          throw const TransportFailure('down');
        },
        findScenes: (filter, {required page, required perPage}) async =>
            ScenePage(total: 5, scenes: [_scene(id: 's2')]),
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );
      await controller.goNext();

      expect(controller.state.phase, ScenePhase.ready);
      expect(controller.state.sceneId, 's1');
      expect(controller.state.scene!.id, 's1');
      expect(controller.state.browse!.index, 0);
      expect(controller.state.navigating, isFalse);
      expect(controller.state.browseFailureSequence, 1);
      expect(controller.state.browseFailure, isA<TransportFailure>());
    });

    test("_findScenes itself throwing carries that failure into the "
        'abandonment too', () async {
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async =>
            throw const TransportFailure('down'),
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );
      await controller.goNext();

      expect(controller.state.scene!.id, 's1');
      expect(controller.state.navigating, isFalse);
      expect(controller.state.browseFailureSequence, 1);
      expect(controller.state.browseFailure, isA<TransportFailure>());
    });

    test('_findScenes throwing a bare, non-Failure error still carries a '
        'usable failure into the abandonment', () async {
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async =>
            throw StateError('boom'),
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );
      await controller.goNext();

      expect(controller.state.browseFailureSequence, 1);
      expect(controller.state.browseFailure, isA<TransportFailure>());
    });

    test(
      'mid-navigation the O-counter is unavailable and cannot be bumped',
      () async {
        // state.scene still holds the outgoing scene for the whole
        // navigation window, which is what keeps the video mapped. Acting
        // on it would count the scene the user just left.
        final pending = Completer<ScenePage>();
        var mutations = 0;
        final controller = _makeSceneController(
          findScene: (id) async => _scene(id: id, oCounter: 3),
          findScenes: (filter, {required page, required perPage}) =>
              pending.future,
          mutateO: (id, mutation) async {
            mutations++;
            return 1;
          },
        );

        await controller.load(
          's1',
          browse: const BrowseContext(
            filter: SceneFilter(),
            index: 0,
            total: 5,
          ),
        );

        final navigation = controller.goNext();
        expect(controller.state.navigating, isTrue);
        expect(controller.state.oCount, isNull);

        await controller.incrementO();
        expect(mutations, 0);

        pending.complete(ScenePage(total: 5, scenes: [_scene(id: 's2')]));
        await navigation;

        expect(controller.state.navigating, isFalse);
        expect(controller.state.scene!.id, 's2');
      },
    );

    test('a step already in flight refuses a second one', () async {
      // A held-down next button would otherwise issue a fetch per frame,
      // each stepping from the same stale index.
      final pending = Completer<ScenePage>();
      var fetches = 0;
      final controller = _makeSceneController(
        findScene: (id) async => _scene(id: id),
        findScenes: (filter, {required page, required perPage}) {
          fetches++;
          return pending.future;
        },
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );

      final first = controller.goNext();
      await controller.goNext();

      expect(fetches, 1);

      pending.complete(ScenePage(total: 5, scenes: [_scene(id: 's2')]));
      await first;
    });

    test(
      'a superseded step cannot clobber the load that followed it',
      () async {
        final pending = Completer<ScenePage>();
        final controller = _makeSceneController(
          findScene: (id) async => _scene(id: id),
          findScenes: (filter, {required page, required perPage}) =>
              pending.future,
        );

        await controller.load(
          's1',
          browse: const BrowseContext(
            filter: SceneFilter(),
            index: 0,
            total: 5,
          ),
        );

        final step = controller.goNext();
        await controller.load('s9');

        pending.complete(ScenePage(total: 5, scenes: [_scene(id: 's2')]));
        await step;

        expect(controller.state.scene!.id, 's9');
      },
    );

    test("a load issued directly for the outgoing scene while a step's nested "
        "load is already in flight does not inherit the step's already-"
        'advanced browse position', () async {
      // Reproduces `scene_screen.dart`'s reachable retry-during-step
      // path: the transient playback-failure banner sits outside the
      // controls' `IgnorePointer`, deliberately, so its Retry stays
      // tappable while `navigating` is true, and Retry calls `load`
      // for whatever scene is still on screen -- which, mid-step, is
      // the *outgoing* scene, since `navigating` keeps `scene`
      // pointing at it.
      final nestedLoadPending = Completer<Scene?>();
      final controller = _makeSceneController(
        findScene: (id) async =>
            id == 's2' ? nestedLoadPending.future : _scene(id: id),
        findScenes: (filter, {required page, required perPage}) async =>
            ScenePage(total: 5, scenes: [_scene(id: 's2')]),
      );

      await controller.load(
        's1',
        browse: const BrowseContext(filter: SceneFilter(), index: 0, total: 5),
      );

      final step = controller.goNext();
      // Lets `_step`'s own `findScenes` resolve and the nested `load`'s
      // synchronous top-of-function reset run, leaving that nested
      // `load` suspended on `findScene('s2')`.
      await pumpEventQueue();
      expect(controller.state.navigating, isTrue);

      await controller.load('s1'); // the banner's Retry, same id

      // Must still carry "s1"'s own position (0), not the in-flight
      // step's already-advanced target index (1).
      expect(controller.state.scene!.id, 's1');
      expect(controller.state.browse!.index, 0);

      // The now-superseded step must not clobber the retry's result
      // once its own nested load finally resolves.
      nestedLoadPending.complete(_scene(id: 's2'));
      await step;
      expect(controller.state.scene!.id, 's1');
      expect(controller.state.browse!.index, 0);
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
        await _tearDownScene(tester, harness);
      });
    }
  });

  group('SceneScreen: metadata drawer scrim (fix round 1, item 1)', () {
    testWidgets(
      'shows a scrim behind the drawer when open, and tapping it closes '
      'the drawer, which the original three-layer Stack omitted entirely',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene, play: false);

        double scrimOpacity() => tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('scene-metadata-scrim')),
            )
            .opacity;

        expect(scrimOpacity(), 0.0);

        await tester.tap(find.byTooltip('Show details'));
        await tester.pumpAndSettle();
        expect(scrimOpacity(), 1.0);

        // Tapped well away from the drawer itself (pinned to the right
        // edge of the default 800-wide test viewport) — this is a
        // genuine tap-*outside*-closes, not an accidental hit on the
        // drawer's own content.
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        expect(scrimOpacity(), 0.0);
        expect(find.byTooltip('Show details'), findsOneWidget);
      },
    );
  });

  group(
    'SceneScreen: closed metadata drawer accessibility (final review I8)',
    () {
      testWidgets(
        'the closed drawer is excluded from semantics and cannot receive '
        'focus; both flip once opened',
        (tester) async {
          final harness = _harness();
          addTearDown(harness.container.dispose);
          final scene = _scene();
          await _pumpReadyScene(tester, harness, scene, play: false);

          bool excludingSemantics() => tester
              .widget<ExcludeSemantics>(
                find.byKey(
                  const Key('scene-metadata-drawer-exclude-semantics'),
                ),
              )
              .excluding;
          bool descendantsFocusable() => tester
              .widget<FocusScope>(
                find.byKey(const Key('scene-metadata-drawer-focus-scope')),
              )
              .descendantsAreFocusable;

          // Closed by default (`_pumpReadyScene` never opens it): the panel
          // must be out of both the accessibility tree and the focus/tab
          // order, even though `ClipRect`+`AnimatedSlide` keep it mounted
          // just off-screen.
          expect(excludingSemantics(), isTrue);
          expect(descendantsFocusable(), isFalse);

          await tester.tap(find.byTooltip('Show details'));
          await tester.pumpAndSettle();

          expect(excludingSemantics(), isFalse);
          expect(descendantsFocusable(), isTrue);
        },
      );
    },
  );

  group('SceneScreen: metadata drawer max width (fix round 1, item 2)', () {
    testWidgets('the drawer is capped at 420 logical pixels on a wide window', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      await tester.tap(find.byTooltip('Show details'));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(SceneMetadataDrawer)).width,
        SceneMetadataDrawer.maxWidth,
      );
    });

    testWidgets(
      'below 420 logical pixels of window width, the drawer fills the '
      'available width instead of overflowing off-screen — the original '
      'fixed `width: SceneMetadataDrawer.maxWidth` pushed the drawer\'s '
      'left edge negative and clipped its content here',
      (tester) async {
        tester.view.physicalSize = const Size(300, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene, play: false);

        await tester.tap(find.byTooltip('Show details'));
        await tester.pumpAndSettle();

        final drawerWidth = tester
            .getSize(find.byType(SceneMetadataDrawer))
            .width;
        expect(drawerWidth, 300.0);
        expect(drawerWidth, lessThan(SceneMetadataDrawer.maxWidth));
      },
    );
  });

  group('SceneScreen: engine lifecycle across mount/unmount (fix round 1, '
      'item 3)', () {
    // A plain `test()`, not `testWidgets()` — deliberately. Empirically
    // verified (a minimal repro, debug-traced step by step) that driving
    // `.autoDispose`'s teardown via `tester.pumpWidget` swapping the
    // widget tree leaves `PlaybackController.dispose()`'s async
    // continuation permanently stuck partway through (specifically at
    // `await _engine.pause()`, which has no internal `await` of its own
    // and cannot legitimately hang) — no number of `tester.pump()` calls,
    // including a 5-second poll loop, ever unstuck it. This matches the
    // exact class of zone-crossing issue this task already found once
    // before (`setUp()` vs. `testWidgets`'s own `FakeAsync` zone — see
    // the "text-entry propagation" group's own doc comment) and the
    // brief's own documented Task 10 limitation: "wrapping a full
    // PlaybackController.dispose() in fakeAsync hangs... use real
    // (non-fakeAsync) tests for controller-lifecycle work." `.autoDispose`
    // teardown triggered through a widget unmount is exactly that case.
    // `ProviderContainer.listen`/`.close()` exercises the *same*
    // `.autoDispose` mechanism `SceneScreen`'s own `ref.watch` relies on
    // (a subscription appearing and disappearing) without ever touching a
    // widget tree or `FakeAsync`, sidestepping the issue entirely.
    test('unmounting the scene screen disposes the engine, and a second '
        'scene visit gets a fresh, non-disposed one — the exact '
        '.autoDispose -> releasePlayback -> double-invalidate chain this '
        'task added, previously asserted nowhere', () async {
      final harness = _harness();
      addTearDown(harness.container.dispose);

      // `container.listen` (not `container.read`) is what registers a
      // subscription `.autoDispose` actually tracks — mirroring what
      // `SceneScreen`'s own `ref.watch(sceneControllerProvider)` does.
      var subscription = harness.container.listen<SceneController>(
        sceneControllerProvider,
        (_, _) {},
      );
      final firstController = subscription.read();
      final firstLoad = firstController.load('a');
      // `load` resolves `stashApiProvider` (itself deferred) before it
      // ever reaches `_TestStashApi.findScene` — let that chain run
      // before assuming a call has landed in `harness.api.calls`.
      await pumpEventQueue();
      harness.api.calls.single.completer.complete(_scene(id: 'a'));
      await firstLoad;
      await pumpEventQueue();

      final firstEngine = harness.engines.single;
      expect(firstEngine.isDisposed, isFalse);

      // Unmount: closing the subscription is what `SceneScreen`'s own
      // watch going away (the route popping) corresponds to.
      subscription.close();
      // Bounded polling with real (not fake) short delays — safe here
      // since this is a plain, real-event-loop test: the dispose chain
      // resolves in a handful of milliseconds once the fake
      // `saveSceneActivity` succeeds, but the exact number of event
      // loop turns Riverpod's own `.autoDispose` scheduling needs isn't
      // this test's business to hard-code.
      for (var i = 0; i < 50 && !firstEngine.isDisposed; i++) {
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        firstEngine.isDisposed,
        isTrue,
        reason:
            'the engine must not keep playing in the background once '
            'the scene screen is gone',
      );

      // Mount a second scene under the same container.
      subscription = harness.container.listen<SceneController>(
        sceneControllerProvider,
        (_, _) {},
      );
      final secondController = subscription.read();
      final secondLoad = secondController.load('b');
      await pumpEventQueue();
      harness.api.calls.last.completer.complete(_scene(id: 'b'));
      await secondLoad;
      await pumpEventQueue();

      expect(
        harness.engines,
        hasLength(2),
        reason:
            'the next scene visit must build a fresh PlaybackEngine, '
            'not silently inherit the disposed one (the exact '
            'PlaybackPhase.failed-forever regression '
            "playbackEngineProvider's own doc warns about)",
      );
      expect(harness.engines[1].isDisposed, isFalse);
    });
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
      await _tearDownScene(tester, harness);
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
      await _tearDownScene(tester, harness);
    });
  });

  group('SceneScreen: metadata drawer under the app theme', () {
    testWidgets('drawer text is legible on its panel in the shipped theme', (
      tester,
    ) async {
      // The end-to-end half of the guard `scene_metadata_drawer_test.dart`
      // makes in isolation. It belongs here too because this harness is
      // what missed the defect: pumping a bare `MaterialApp` meant the
      // largest widget-test file in the suite exercised the drawer under
      // a theme the app never ships, and the drawer's text is invisible
      // only under one the app does.
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene(title: 'A Real Title');
      await _pumpReadyScene(tester, harness, scene);

      await tester.tap(find.byTooltip('Show details'));
      await tester.pumpAndSettle();

      final title = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(SceneMetadataDrawer),
          matching: find.text('A Real Title'),
        ),
      );
      expect(title.text.style?.color, AppTokens.playerText);
      expect(
        contrastRatio(title.text.style!.color!, SceneMetadataDrawer.panelColor),
        greaterThan(4.5),
      );
      await _tearDownScene(tester, harness);
    });
  });

  group('SceneScreen: transport controls', () {
    testWidgets('exposes play/pause, seek, volume, mute, and '
        'metadata controls with tooltips', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byKey(const Key('scene-seek-bar')), findsOneWidget);
      expect(find.byKey(const Key('scene-volume-slider')), findsOneWidget);
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(find.byTooltip('Show details'), findsOneWidget);
    });

    testWidgets('play/pause button toggles playback via the controller', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      // `loadScene` (inside `_pumpReadyScene`) already issued its own
      // unconditional `PlayCommand` — clear it so the assertion below can
      // only pass if *this* tap is what issues the next one (final review
      // I3: without this, the assertion was true before the tap ever ran).
      harness.engine.commands.clear();
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();

      expect(harness.engine.commands.whereType<PlayCommand>(), isNotEmpty);
    });

    testWidgets(
      'tapping the video itself toggles play/pause too (M7: the gesture '
      'media_kit\'s own controls used to provide)',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene, play: false);

        harness.engine.commands.clear();
        // `warnIfMissed: false`: the fake video surface these tests use
        // renders zero-sized, so this coordinate doesn't land on the
        // 'player-video' widget itself, only on the full-screen
        // `GestureDetector` behind it -- which is exactly what this test
        // means to tap.
        await tester.tap(
          find.byKey(const Key('player-video')),
          warnIfMissed: false,
        );
        // A `GestureDetector` with both `onTap` and `onDoubleTap` holds
        // the single tap until the double-tap window has passed, to see
        // whether a second tap follows.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

        expect(harness.engine.commands.whereType<PlayCommand>(), isNotEmpty);
      },
    );

    testWidgets(
      'dragging the seek bar commits exactly one seek, on release — not '
      'one per pointer sample (final review I2)',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene, play: false);
        harness.engine.emitDuration(const Duration(seconds: 120));
        // Two pumps — see `_pumpReadyScene`'s own doc: one to flush the
        // duration stream's microtask delivery into `PlaybackController`'s
        // state, one more for the rebuild that actually enables the
        // slider's `onChanged`/`onChangeEnd` (disabled while duration is
        // unknown).
        await tester.pump();
        await tester.pump();

        await tester.drag(
          find.byKey(const Key('scene-seek-bar')),
          const Offset(80, 0),
        );
        await tester.pump();

        expect(harness.engine.commands.whereType<SeekCommand>(), hasLength(1));
      },
    );

    testWidgets('prev and next are dead until a browse context arrives', (
      tester,
    ) async {
      final harness = _harness();
      await _pumpReadyScene(tester, harness, _scene());

      // `find.byTooltip` resolves to the `RawTooltip` this Flutter SDK
      // composes underneath `Tooltip` (not `PlayerIconButton` itself), so
      // this climbs to the enclosing `PlayerIconButton` rather than
      // casting the tooltip finder's own widget directly.
      PlayerIconButton button(String tooltip) =>
          tester.widget<PlayerIconButton>(
            find.ancestor(
              of: find.byTooltip(tooltip),
              matching: find.byType(PlayerIconButton),
            ),
          );

      expect(button('Previous scene').onPressed, isNull);
      expect(button('Next scene').onPressed, isNull);

      await _tearDownScene(tester, harness);
    });

    testWidgets('tapping Next steps forward through a real browse context, not '
        'backward', (tester) async {
      // The only end-to-end coverage that `onPrevious`/`onNext` are
      // wired to `goPrevious`/`goNext` in the right direction: a swap
      // between the two at the `PlayerBar` call site would still pass
      // every `SceneController`-level test (those call `goNext`
      // directly) and every other widget test here (browse is `null`,
      // so both buttons are simply dead).
      final harness = _harness();
      await _pumpReadyScene(
        tester,
        harness,
        _scene(id: 's5'),
        browse: const BrowseContext(filter: SceneFilter(), index: 4, total: 10),
      );

      harness.api.pages.add(
        ScenePage(
          total: 10,
          scenes: [_scene(id: 's6', stream: 'six.mp4')],
        ),
      );

      await tester.tap(find.byTooltip('Next scene'));
      await tester.pump();
      // The step's nested `load` fetches "s6"'s own metadata next --
      // `_TestStashApi.calls` now holds the initial "s5" call (already
      // completed by `_pumpReadyScene`) plus this new one.
      harness.api.calls.last.completer.complete(
        _scene(id: 's6', stream: 'six.mp4'),
      );
      await tester.pumpAndSettle();

      // Index 4 stepping forward reads page 6 (Stash pages are
      // 1-indexed: target index 5, so page index + 1 = 6). Landing on
      // page 4 instead would mean this tap actually called
      // `goPrevious`.
      expect(harness.api.requestedPages, [6]);
      final state = harness.container.read(sceneControllerProvider).state;
      expect(state.scene!.id, 's6');
      expect(state.browse!.index, 5);

      await _tearDownScene(tester, harness);
    });

    testWidgets(
      'a network failure during a step is reported as a failure, not as '
      'a library change (M1)',
      (tester) async {
        final harness = _harness();
        await _pumpReadyScene(
          tester,
          harness,
          _scene(id: 's5'),
          browse: const BrowseContext(
            filter: SceneFilter(),
            index: 4,
            total: 10,
          ),
        );

        harness.api.pageFailures.add(const TransportFailure());

        await tester.tap(find.byTooltip('Next scene'));
        await tester.pumpAndSettle();

        // Still on the outgoing scene -- the step was abandoned.
        final state = harness.container.read(sceneControllerProvider).state;
        expect(state.scene!.id, 's5');

        final notice = harness.container.read(globalNoticeProvider);
        expect(notice, isNotNull);
        expect(notice!.severity, AppNoticeSeverity.warning);
        expect(notice.message, 'Could not reach the Stash server.');
        expect(notice.message, isNot('There is no scene there any more.'));

        await _tearDownScene(tester, harness);
      },
    );

    testWidgets('skipping forward seeks ten seconds on the engine', (
      tester,
    ) async {
      final harness = _harness();
      await _pumpReadyScene(tester, harness, _scene());

      await tester.tap(find.byTooltip('Forward 10 seconds'));
      await tester.pump();

      // Asserts against the engine, not the controller: the button exists
      // to move playback, and a callback-only check would still pass if it
      // fired without ever seeking.
      expect(
        harness.engine.commands.whereType<SeekCommand>().last.position,
        const Duration(seconds: 10),
      );

      await _tearDownScene(tester, harness);
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
        await _tearDownScene(tester, harness);
      },
    );

    testWidgets('both chrome bars fade from the same animation', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);

      // The two `FadeTransition`s must share the literal same `Animation`
      // object, not merely compute matching values from separate, equally-
      // driven ones: two independent animations agree at every sample
      // point too, right up until someone edits one without the other.
      // Identity is the property that actually rules that out.
      final topOpacity = tester
          .widget<FadeTransition>(
            find.byKey(const Key('scene-controls-overlay')),
          )
          .opacity;
      final playerBarOpacity = tester
          .widget<FadeTransition>(
            find.byKey(const Key('scene-controls-overlay-player-bar')),
          )
          .opacity;
      expect(identical(topOpacity, playerBarOpacity), isTrue);

      // Fully visible on mount: both bars agree, not just the top one
      // `_controlsOpacity` alone has always checked.
      expect(_controlsOpacity(tester), 1.0);
      expect(_playerBarOpacity(tester), 1.0);

      await tester.pump(const Duration(seconds: 4));

      // And fully hidden after auto-hide fires: still in lockstep. If the
      // player bar's own `FadeTransition` (and its key) were ever
      // deleted, `_playerBarOpacity` would throw here rather than let
      // this pass.
      expect(_controlsOpacity(tester), 0.0);
      expect(_playerBarOpacity(tester), 0.0);
      await _tearDownScene(tester, harness);
    });

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
      await _tearDownScene(tester, harness);
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
      await _tearDownScene(tester, harness);
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
      await _tearDownScene(tester, harness);
    });

    testWidgets(
      'hovering the controls suppresses auto-hide (fix round 1, item 4: '
      'previously untested — MouseRegion.onEnter/onExit could silently '
      'never fire and nothing would notice)',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.byTooltip('Pause')));
        await tester.pump();

        // Still hovering the controls well past the normal 3s hide delay.
        await tester.pump(const Duration(seconds: 4));
        expect(_controlsOpacity(tester), 1.0);

        // Move off the controls onto the video — hover leaves the
        // controls, and (as a fresh activity signal from the video's own
        // `onHover`) a new 3s countdown starts from this moment.
        await gesture.moveTo(
          tester.getCenter(find.byKey(const Key('player-video'))),
        );
        await tester.pump();
        await gesture.removePointer();
        await tester.pump();

        await tester.pump(const Duration(seconds: 4));
        expect(_controlsOpacity(tester), 0.0);

        await _tearDownScene(tester, harness);
      },
    );

    testWidgets('focusing a control suppresses auto-hide (fix round 1, item 4: '
        'previously untested, the fragile one, since FocusScope.onFocusChange '
        'depends on the implicit scope node actually reporting focus for a '
        'descendant PlayerIconButton)', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene);

      // `find.byTooltip` locates the `Tooltip` wrapping the `PlayerIconButton`,
      // and the button's own `InkWell` sits *above* the `Focus` node its
      // build method creates internally, so `Focus.of` on the tooltip or
      // the button's own context finds no ancestor `Focus` at all and
      // throws. The button's `icon` child ends up nested *inside* that
      // internal `InkWell`/`Focus`, so it's the shallowest context that
      // actually has one as an ancestor. Find that instead.
      final muteButtonContext = tester.element(
        find.descendant(
          of: find.byTooltip('Mute'),
          matching: find.byType(Icon),
        ),
      );
      Focus.of(muteButtonContext).requestFocus();
      await tester.pump();

      await tester.pump(const Duration(seconds: 4));
      expect(
        _controlsOpacity(tester),
        1.0,
        reason:
            'a keyboard user mid-interaction with a focused control must '
            'not have it fade out from under them',
      );

      // `FocusNode.unfocus()`'s default `UnfocusDisposition.scope` only
      // moves the primary focus up to the *nearest enclosing scope* —
      // which here is the controls' own `FocusScope`, so that scope's
      // own `hasFocus` (true whenever it or a descendant holds primary
      // focus) stays true and `onFocusChange` never fires false.
      // Plain `FocusScopeNode.requestFocus()` on the root scope doesn't
      // help either — it re-descends via `findFirstFocus` into whatever
      // child each scope remembers as last-focused, walking right back
      // down to this same mute button. `requestScopeFocus()` parks the
      // primary focus on the root scope itself with no such descent,
      // which is the only way to genuinely leave the controls scope.
      FocusManager.instance.rootScope.requestScopeFocus();
      await tester.pump();

      await tester.pump(const Duration(seconds: 4));
      expect(_controlsOpacity(tester), 0.0);

      await _tearDownScene(tester, harness);
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
      'a stream failure after the video already played does not cover '
      'the video with a full error state, but does show a persistent '
      'Retry banner (fix round 1, item 5, scenario 1: a way out of a '
      'mid-stream failure)',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);
        harness.engine.emitDuration(const Duration(seconds: 120));
        await tester.pump();

        // A genuine stream-level failure (e.g. a network drop mid-scene)
        // reported by the engine's own `errors` stream, after duration
        // (and thus a once-successful open) is already known.
        harness.engine.emitError('stream broke');
        await tester.pump();
        await tester.pump();

        // The video surface and transport controls are still there — no
        // full-screen failure overlay took over.
        expect(find.byKey(const Key('player-video')), findsOneWidget);
        expect(find.byTooltip('Pause'), findsOneWidget);
        expect(find.text('This video could not be played.'), findsNothing);
        // But a *persistent* Retry banner is now reachable — not just a
        // one-shot, auto-dismissing notice — closing the dead end the
        // review flagged: previously nothing anywhere offered a way to
        // recover from this state.
        expect(
          find.byKey(const Key('scene-transient-failure-banner')),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        // The failure is still surfaced non-modally too.
        final notice = harness.container.read(globalNoticeProvider);
        expect(notice, isNotNull);
        expect(notice!.severity, AppNoticeSeverity.warning);

        // Tapping the banner's Retry re-issues `findScene` (the same
        // recovery path the blocking overlay's own Retry uses).
        final callsBefore = harness.api.calls.length;
        await tester.tap(find.text('Retry'));
        await tester.pump();
        expect(harness.api.calls, hasLength(callsBefore + 1));

        await _tearDownScene(tester, harness);
      },
    );

    testWidgets(
      'with a failure banner showing, the back button and details toggle '
      'stay hit-testable and tapping the details toggle opens the drawer, '
      'not the banner underneath it',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);
        harness.engine.emitDuration(const Duration(seconds: 120));
        await tester.pump();

        // The banner used to sit on top of the top bar and silently
        // swallow taps meant for the back button and details toggle.
        harness.engine.emitError('stream broke');
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('scene-transient-failure-banner')),
          findsOneWidget,
        );

        // A hit-test miss on either control below only prints a warning
        // by default (see `WidgetController.tap`'s own doc); make it
        // fatal for this test so a tap occluded by the banner fails
        // loudly instead of silently passing.
        WidgetController.hitTestWarningShouldBeFatal = true;
        addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

        // Nothing to pop from the root route, but the tap must actually
        // land on the back button rather than being swallowed by the
        // banner sitting near it.
        await tester.tap(find.byTooltip('Back to library'));
        await tester.pump();

        double scrimOpacity() => tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('scene-metadata-scrim')),
            )
            .opacity;
        expect(scrimOpacity(), 0.0);
        final callsBefore = harness.api.calls.length;

        await tester.tap(find.byTooltip('Show details'));
        await tester.pumpAndSettle();

        // The drawer opened, not the banner's Retry action underneath it
        // (before this fix: the details toggle's centre fell inside the
        // banner's Retry button, so this tap re-loaded the scene instead).
        expect(scrimOpacity(), 1.0);
        expect(find.byTooltip('Hide details'), findsOneWidget);
        expect(harness.api.calls, hasLength(callsBefore));

        await _tearDownScene(tester, harness);
      },
    );
  });

  group('SceneScreen: control-command failures (fix round 1, item 5)', () {
    testWidgets(
      'a failed setVolume never shows a failure overlay or the transient '
      'banner (scenario 3: it must not touch phase at all), and a second '
      'independent failure still produces its own fresh notice (scenario '
      '2: repeated failures are never silently absorbed)',
      (tester) async {
        final harness = _harness(
          wrapEngine: (inner) => _ThrowingSetVolumeEngine(inner),
        );
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);
        harness.engine.emitDuration(const Duration(seconds: 120));
        await tester.pump();

        final controller = harness.container.read(playbackControllerProvider);

        await controller.setVolume(0.2);
        await tester.pump();

        expect(find.text('Retry'), findsNothing);
        expect(
          find.byKey(const Key('scene-transient-failure-banner')),
          findsNothing,
        );
        expect(find.byTooltip('Pause'), findsOneWidget);
        final firstNotice = harness.container.read(globalNoticeProvider);
        expect(firstNotice, isNotNull);
        expect(firstNotice!.severity, AppNoticeSeverity.warning);

        await controller.setVolume(0.3);
        await tester.pump();

        final secondNotice = harness.container.read(globalNoticeProvider);
        expect(secondNotice, isNotNull);
        expect(secondNotice!.id, isNot(firstNotice.id));
        // Still no failure surface of any kind — the scene is genuinely
        // fine, only the volume command failed, twice.
        expect(find.text('Retry'), findsNothing);
        expect(find.byTooltip('Pause'), findsOneWidget);

        await _tearDownScene(tester, harness);
      },
    );
  });

  group('SceneScreen: fullscreen (deliberately absent from this chrome)', () {
    testWidgets(
      'no fullscreen control is rendered and Escape is a harmless no-op',
      (tester) async {
        final harness = _harness();
        addTearDown(harness.container.dispose);
        final scene = _scene();
        await _pumpReadyScene(tester, harness, scene);

        // No real platform fullscreen hook exists on any target yet, so
        // the player bar simply has no fullscreen control at all, rather
        // than a disabled one that claims a capability the OS was never
        // asked for.
        expect(
          find.byTooltip('Fullscreen (not yet implemented)'),
          findsNothing,
        );

        // Escape still routes through `PlayerActionShortcuts` to
        // `PlaybackController.handleAction(PlayerAction.exitFullscreen)`,
        // which is already a no-op when not fullscreen: confirm the key
        // binding stays wired without crashing, even with no fullscreen
        // control anywhere in the tree to reflect a state change.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(tester.takeException(), isNull);
        await _tearDownScene(tester, harness);
      },
    );

    testWidgets('space toggles play/pause the same as the button', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, play: false);

      // See the play/pause button test above (final review I3): clear the
      // `PlayCommand` `loadScene` already issued before asserting on the
      // one this interaction is supposed to cause.
      harness.engine.commands.clear();
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
  FindScenesPage? findScenes,
  MutateOCounter? mutateO,
  VoidCallback? releasePlayback,
}) => _makeSceneControllerWithEngine(
  findScene: findScene,
  findScenes: findScenes,
  mutateO: mutateO,
  releasePlayback: releasePlayback,
).controller;

class _SceneControllerAndEngine {
  _SceneControllerAndEngine(this.controller, this.engine);
  final SceneController controller;
  final FakePlaybackEngine engine;
}

_SceneControllerAndEngine _makeSceneControllerWithEngine({
  FindScene? findScene,
  FindScenesPage? findScenes,
  MutateOCounter? mutateO,
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
    findScenes:
        findScenes ??
        (filter, {required page, required perPage}) async =>
            throw StateError('unexpected findScenes(page: $page)'),
    mutateO:
        mutateO ??
        (id, mutation) async => throw StateError('unexpected $mutation on $id'),
    playback: playback,
    releasePlayback: releasePlayback ?? () {},
  );
  return _SceneControllerAndEngine(controller, engine);
}
