import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/app_router.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';

import '../support/fakes.dart';

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
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Connect to Stash'), findsNothing);
    },
  );

  testWidgets(
    'settings: a successful reconnect dismisses the modal and lands back '
    'on the library',
    (tester) async {
      final container = _container(
        saved: const ConnectionConfig(serverUrl: 'https://old.test'),
      );
      addTearDown(container.dispose);
      await container.read(appControllerProvider.notifier).bootstrap();

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);

      await tester.tap(find.byTooltip('Connection settings'));
      await tester.pumpAndSettle();
      expect(find.text('Connection settings'), findsOneWidget);

      final generationBefore = container.read(connectionGenerationProvider);

      await tester.enterText(
        find.byKey(const Key('connection-server-url')),
        'https://new.test',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      // The modal is gone — this is the actual regression guard for
      // carried-forward item 2 (dismiss promptly on success rather than
      // leaving the settings screen mounted).
      expect(find.text('Connection settings'), findsNothing);
      expect(find.text('Library'), findsOneWidget);
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

  testWidgets('popping the scene page returns to the library', (tester) async {
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_SceneFirstController.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppRouter()),
      ),
    );
    await tester.pump();

    expect(find.text('Scene 42'), findsOneWidget);
    expect(find.text('Library'), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Scene 42'), findsNothing);
    expect(
      container.read(appControllerProvider),
      const AppDestination.library(),
    );
  });
}

/// A test-only `AppController` whose initial destination is a scene, so
/// [AppRouter]'s `scene(sceneId)` branch — and the "popping it returns to
/// the library" back-navigation it wires up — can be exercised without
/// anything from Task 5+'s library/scene features. `showLibrary()` and
/// every other method is inherited unchanged from the real controller.
class _SceneFirstController extends AppController {
  @override
  AppDestination build() => const AppDestination.scene('42');
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
      (config) => FakeStashApi(versionValue: 'v0.31.0'),
    ),
    connectionControllerOverride,
  ],
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: AppRouter()),
);
