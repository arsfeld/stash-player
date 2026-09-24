import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/app_router.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/browse_context.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/connection/connection_form.dart';
import 'package:stash_player_flutter/features/connection/connection_settings_dialog.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';
import 'package:stash_player_flutter/features/library/library_screen.dart';
import 'package:stash_player_flutter/features/player/activity_sync.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/scene_controller.dart';
import 'package:stash_player_flutter/features/player/scene_screen.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/toolbar/native_toolbar.dart';

import '../support/fake_connection_sheet.dart';
import '../support/fake_playback_engine.dart';
import '../support/fakes.dart';
import '../support/recording_toolbar.dart';

void main() {
  testWidgets(
    'first-launch: a successful test connects and shows the library',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await container.read(appControllerProvider.notifier).bootstrap();

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Connect to Stash'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('connection-server-url')),
        'https://stash.test',
      );
      // enterText doesn't rebuild the tree, and Connect's enabled state is
      // rebuilt through a ListenableBuilder, so pump once before tapping or
      // this hits the still-disabled button.
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
      // The library screen no longer renders a title anywhere (the
      // redesign dropped its `AppBar`), so the widget type is what proves
      // we landed there, not a word it used to show.
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.text('Connect to Stash'), findsNothing);
    },
  );

  testWidgets(
    'settings: a successful save closes the dialog and reconnects the '
    'library',
    (tester) async {
      final container = _container(
        saved: const ConnectionConfig(serverUrl: 'https://old.test'),
      );
      addTearDown(container.dispose);
      await container.read(appControllerProvider.notifier).bootstrap();

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      container.read(appControllerProvider.notifier).openSettings();
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionSettingsDialog), findsOneWidget);
      // The dialog floats over the library rather than replacing it.
      expect(find.byType(LibraryScreen), findsOneWidget);

      final generationBefore = container.read(connectionGenerationProvider);

      await tester.enterText(
        find.byKey(const Key('connection-server-url')),
        'https://new.test',
      );
      // enterText doesn't rebuild the tree, and Save's enabled state is
      // rebuilt through a ListenableBuilder, so pump once before tapping or
      // this hits the still-disabled button.
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(ConnectionSettingsDialog), findsNothing);
      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
      expect(
        container.read(connectionGenerationProvider),
        generationBefore + 1,
      );
    },
  );

  testWidgets('settings: Escape closes the dialog without reconnecting', (
    tester,
  ) async {
    final container = _container(
      saved: const ConnectionConfig(serverUrl: 'https://old.test'),
    );
    addTearDown(container.dispose);
    await container.read(appControllerProvider.notifier).bootstrap();

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    container.read(appControllerProvider.notifier).openSettings();
    await tester.pumpAndSettle();
    final generationBefore = container.read(connectionGenerationProvider);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionSettingsDialog), findsNothing);
    expect(
      container.read(appControllerProvider),
      const AppDestination.library(),
    );
    expect(container.read(connectionGenerationProvider), generationBefore);
  });

  testWidgets(
    'first-launch with a native sheet: a non-cancellable sheet connects and '
    'shows the library',
    (tester) async {
      final sheet = FakeConnectionSheet();
      final container = ProviderContainer(
        overrides: [
          connectionSheetProvider.overrideWith(
            () => FakeConnectionSheetNotifier(sheet),
          ),
          connectionStoreProvider.overrideWithValue(FakeConnectionStore()),
          environmentProvider.overrideWithValue(const {}),
          stashApiFactoryProvider.overrideWithValue(
            (config) =>
                FakeStashApi(versionValue: 'v0.31.0')
                  ..pages.add(ScenePage(total: 0, scenes: const [])),
          ),
          connectionControllerOverride,
        ],
      );
      addTearDown(container.dispose);
      await container.read(appControllerProvider.notifier).bootstrap();

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(
        container.read(appControllerProvider),
        const AppDestination.connection(),
      );
      final presented = sheet.presented!;
      expect(presented.title, 'Connect to Stash');
      expect(presented.confirmLabel, 'Connect');
      expect(presented.cancellable, isFalse);
      expect(find.byType(ConnectionForm), findsNothing);

      sheet.send(
        const ConnectionSheetSubmitted(
          ConnectionConfig(serverUrl: 'https://stash.test'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(sheet.dismissed, isTrue);
    },
  );

  testWidgets(
    'settings with a native sheet: presents the sheet, no drawn dialog',
    (tester) async {
      final sheet = FakeConnectionSheet();
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(
            () => _FixedDestinationController(
              const LibraryDestination(settingsOpen: true),
            ),
          ),
          connectionSheetProvider.overrideWith(
            () => FakeConnectionSheetNotifier(sheet),
          ),
          connectionStoreProvider.overrideWithValue(
            FakeConnectionStore(
              saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
            ),
          ),
          environmentProvider.overrideWithValue(const {}),
          stashApiFactoryProvider.overrideWithValue(
            (config) =>
                FakeStashApi(versionValue: 'v0.31.0')
                  ..pages.add(ScenePage(total: 0, scenes: const [])),
          ),
          connectionControllerOverride,
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.byType(ConnectionSettingsDialog), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(sheet.presented!.title, 'Connection');
      expect(sheet.presented!.confirmLabel, 'Save');
      expect(sheet.presented!.cancellable, isTrue);
    },
  );

  testWidgets('popping the scene page returns to the library', (tester) async {
    // Task 11 wired the real `SceneScreen` into the `scene(sceneId)`
    // branch this test exercises, so — like every other test that mounts
    // it (see `scene_screen_test.dart`) — this needs the same
    // `playbackEngineFactoryProvider` override the rest of the suite
    // uses: without it, simply watching `sceneControllerProvider` (which
    // eagerly reads `playbackControllerProvider`, per that provider's own
    // doc) would construct a real `MediaKitPlaybackEngine`, starting
    // native playback libraries mid-test.
    final stashApi = FakeStashApi()
      ..sceneResults.add(
        Scene(
          id: '42',
          paths: const ScenePaths(stream: 'x.mp4'),
        ),
      );
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(
          () => _FixedDestinationController(const AppDestination.scene('42')),
        ),
        connectionStoreProvider.overrideWithValue(
          FakeConnectionStore(
            saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
          ),
        ),
        environmentProvider.overrideWithValue(const {}),
        stashApiFactoryProvider.overrideWithValue((config) => stashApi),
        playbackEngineFactoryProvider.overrideWithValue(
          ({httpProxyUrl}) => FakePlaybackEngine(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const AppRouter(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // `Scene(id: '42')` has no title, so `Scene.displayTitle` falls back
    // to `'Scene 42'` — the scene screen's own transport bar renders it
    // (a second copy also sits in the metadata drawer's header, always
    // present in the tree even while the drawer itself is slid off-screen
    // — hence `findsWidgets`, not `findsOneWidget`).
    expect(find.text('Scene 42'), findsWidgets);
    // The library screen no longer renders a title anywhere (the redesign
    // dropped its `AppBar`), so the widget type is what proves the library
    // isn't what's showing, not the absence of a word it used to render.
    //
    // What this asserts is that the library is not on screen, which is
    // the property that matters here. It is not evidence that the screen
    // was torn down: `find.byType` defaults to `skipOffstage: true`, so
    // it cannot tell "never built" from "built but offstage", and
    // `MaterialPage` keeps `maintainState: true`, so `LibraryScreen`
    // does in fact stay built underneath the scene route.
    expect(find.byType(LibraryScreen), findsNothing);

    // `SceneScreen` is video-first with no `AppBar` (so no automatic
    // Material `BackButton`) — its own back control is the transport
    // bar's tooltip-labelled icon button.
    await tester.tap(find.byTooltip('Back to library'));
    // Not `pumpAndSettle()` — correction (fix round 1): the original
    // comment here claimed `pumpAndSettle`'s own ~10s default budget was
    // the problem. That's wrong; `pumpAndSettle`'s default *timeout* is
    // 10 *minutes* of fake-clock time, not ~10s, and it only stops
    // pumping once `hasScheduledFrame` is false.
    //
    // `ActivitySync.dispose` now cancels its own timeout `Timer` the
    // moment its flush settles (final review I5), so the (fast-
    // succeeding, here) flush this test's teardown triggers no longer
    // leaves a stray ~10s `Timer` pending the way the old
    // `Future.any([flushSettled.future, _delay(disposeFlushTimeout)])`
    // did. This explicit pump past `disposeFlushTimeout` is kept anyway,
    // as a bound tied to the named production constant rather than a
    // bare magic number, so a future regression that reintroduces a
    // leaked timer here fails obviously instead of silently.
    await tester.pump();
    await tester.pump(disposeFlushTimeout + const Duration(seconds: 1));

    // The library screen no longer renders a title anywhere (the redesign
    // dropped its `AppBar`), so the widget type is what proves we landed
    // there, not a word it used to show.
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('Scene 42'), findsNothing);
    expect(
      container.read(appControllerProvider),
      const AppDestination.library(),
    );
  });

  testWidgets('a scene destination hands its context to the screen', (
    tester,
  ) async {
    // The destination and the controller both grew a browse context
    // before anything connected them, which left prev/next inert while
    // every unit test still passed.
    const browse = BrowseContext(filter: SceneFilter(), index: 7, total: 412);

    final container = await pumpRouterAt(
      tester,
      const SceneDestination('1001', browse: browse),
    );

    expect(tester.widget<SceneScreen>(find.byType(SceneScreen)).browse, browse);
    // The constructor field alone would still pass this test even if
    // `SceneScreen.initState` dropped `browse: widget.browse` from its
    // `load(...)` call. Asserting on the controller's own state is what
    // actually proves the context reached `SceneController`, not just the
    // widget that carries it past the router.
    expect(container.read(sceneControllerProvider).state.browse, browse);
  });

  testWidgets(
    'settings when the native sheet fails to present: the drawn dialog '
    'appears instead',
    (tester) async {
      final sheet = FakeConnectionSheet(failPresent: true);
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(
            () => _FixedDestinationController(const AppDestination.library()),
          ),
          connectionSheetProvider.overrideWith(
            () => FakeConnectionSheetNotifier(sheet),
          ),
          connectionStoreProvider.overrideWithValue(
            FakeConnectionStore(
              saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
            ),
          ),
          environmentProvider.overrideWithValue(const {}),
          stashApiFactoryProvider.overrideWithValue(
            (config) =>
                FakeStashApi(versionValue: 'v0.31.0')
                  ..pages.add(ScenePage(total: 0, scenes: const [])),
          ),
          connectionControllerOverride,
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionSettingsDialog), findsNothing);

      container.read(appControllerProvider.notifier).openSettings();
      await tester.pumpAndSettle();

      expect(sheet.presented, isNull);
      expect(container.read(connectionSheetProvider), isNull);
      expect(find.byType(ConnectionSettingsDialog), findsOneWidget);
      expect(find.byType(LibraryScreen), findsOneWidget);
    },
  );

  testWidgets(
    'the native toolbar empties while a scene shows and comes back with '
    'the library',
    (tester) async {
      final toolbar = RecordingToolbar();
      final container = await pumpRouterAt(
        tester,
        const AppDestination.library(),
        toolbar: toolbar,
      );
      await tester.pump();
      expect(toolbar.last.items, isNotEmpty);

      container.read(appControllerProvider.notifier).openScene('1001');
      await tester.pumpAndSettle();
      expect(find.byType(SceneScreen), findsOneWidget);
      expect(toolbar.last.items, isEmpty);

      container.read(appControllerProvider.notifier).showLibrary();
      await tester.pump();
      await tester.pump(disposeFlushTimeout + const Duration(seconds: 1));

      expect(find.byType(SceneScreen), findsNothing);
      expect(toolbar.last.items, isNotEmpty);
    },
  );
}

/// Drives [AppRouter] straight to [destination], with the same
/// scene/playback overrides `popping the scene page returns to the
/// library` uses to reach the scene route without starting real playback
/// or network code. Returns the [ProviderContainer] so a caller can
/// inspect provider state past what the widget tree alone can prove.
Future<ProviderContainer> pumpRouterAt(
  WidgetTester tester,
  AppDestination destination, {
  NativeToolbar? toolbar,
}) async {
  final stashApi = FakeStashApi()
    // Enough for a library destination's first fetch.
    ..pages.addAll([
      for (var i = 0; i < 3; i++) ScenePage(total: 0, scenes: const []),
    ])
    ..sceneResults.add(
      Scene(
        id: '1001',
        paths: const ScenePaths(stream: 'x.mp4'),
      ),
    );
  final container = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(
        () => _FixedDestinationController(destination),
      ),
      connectionStoreProvider.overrideWithValue(
        FakeConnectionStore(
          saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
        ),
      ),
      environmentProvider.overrideWithValue(const {}),
      stashApiFactoryProvider.overrideWithValue((config) => stashApi),
      playbackEngineFactoryProvider.overrideWithValue(
        ({httpProxyUrl}) => FakePlaybackEngine(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: toolbar == null
            ? const AppRouter()
            : NativeToolbarScope(toolbar: toolbar, child: const AppRouter()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// A test-only `AppController` that always starts at whatever
/// [AppDestination] it is built with, so [pumpRouterAt] can drive
/// [AppRouter] straight to any destination a test needs.
class _FixedDestinationController extends AppController {
  _FixedDestinationController(this._destination);

  final AppDestination _destination;

  @override
  AppDestination build() => _destination;
}

ProviderContainer _container({
  ConnectionConfig saved = const ConnectionConfig(),
}) => ProviderContainer(
  overrides: [
    connectionStoreProvider.overrideWithValue(
      FakeConnectionStore(saved: saved),
    ),
    environmentProvider.overrideWithValue(const {}),
    stashApiFactoryProvider.overrideWithValue(
      // Task 7 made the library destination a real `LibraryScreen`, which
      // fetches its first page on mount — an empty-but-resolved page
      // keeps that fetch from staying in `loading` forever (an
      // indeterminate `AppSpinner`, which would hang any `pumpAndSettle`
      // in this file that lands on the library).
      (config) =>
          FakeStashApi(versionValue: 'v0.31.0')
            ..pages.add(ScenePage(total: 0, scenes: const [])),
    ),
    connectionControllerOverride,
  ],
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: const AppRouter(),
  ),
);
