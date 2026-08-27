import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/library/library_controller.dart';
import 'package:stash_player_flutter/features/library/library_screen.dart';
import 'package:stash_player_flutter/features/library/library_state.dart';
import 'package:stash_player_flutter/services/thumbnail_repository.dart';
import 'package:stash_player_flutter/shared/scene_placeholder.dart';

import '../../support/fakes.dart';

Scene _scene({
  required String id,
  String? title,
  int? rating100,
  double? resumeTime,
  List<SceneFile> files = const [],
}) => Scene(
  id: id,
  paths: const ScenePaths(),
  title: title,
  rating100: rating100,
  resumeTime: resumeTime,
  files: files,
);

List<Scene> _scenes(int count, {int start = 0}) =>
    List.generate(count, (i) => _scene(id: '${start + i}'));

class _Harness {
  _Harness(this.container, this.controller, this.api);

  final ProviderContainer container;
  final LibraryController controller;
  final FakeStashApi api;
}

Future<_Harness> _pumpLibrary(
  WidgetTester tester, {
  FakeStashApi? api,
  ThumbnailRepository? thumbnailRepository,
  VoidCallback? onOpenSettings,
  Size size = const Size(1200, 900),
}) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;

  final fakeApi = api ?? FakeStashApi();
  final controller = LibraryController(api: fakeApi, seedGenerator: () => 42);
  final container = ProviderContainer(
    overrides: [
      libraryControllerProvider.overrideWith((ref) => controller),
      thumbnailRepositoryProvider.overrideWith(
        (ref) async => thumbnailRepository ?? FakeThumbnailRepository(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: LibraryScreen(onOpenSettings: onOpenSettings ?? () {}),
      ),
    ),
  );

  return _Harness(container, controller, fakeApi);
}

void main() {
  group('explicit states', () {
    testWidgets(
      'initial/loading with no data shows centered progress and Loading '
      'scenes semantics',
      (tester) async {
        // No pages configured: `findScenes` never resolves, so the
        // controller stays in `loading` forever — exactly the
        // "initial/loading with no data" bucket. Deliberately bounded
        // pumps rather than `pumpAndSettle`: the indeterminate
        // `CircularProgressIndicator` this state renders schedules
        // frames forever, which `pumpAndSettle` would wait on forever
        // too.
        await _pumpLibrary(tester, api: FakeStashApi());
        await tester.pump();
        await tester.pump();

        expect(find.bySemanticsLabel('Loading scenes'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );

    testWidgets('empty shows the no-match message and a Clear filters '
        'action', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 0, scenes: const []));
      await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('No scenes match these filters'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Clear filters'),
        findsOneWidget,
      );
    });

    testWidgets('ready shows the accepted grid', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 2, scenes: _scenes(2)));
      await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('Scene 0'), findsOneWidget);
      expect(find.text('Scene 1'), findsOneWidget);
    });

    testWidgets('ready shows bottom-page progress while a further page is '
        'loading', (tester) async {
      final api = FakeStashApi();
      api.pages.add(ScenePage(total: 100, scenes: _scenes(48)));
      final harness = await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();
      expect(harness.controller.state.phase, LibraryPhase.ready);

      unawaited(
        harness.controller.ensureViewportFilled(
          contentExtent: 100,
          viewportExtent: 900,
        ),
      );
      await tester.pump();

      expect(harness.controller.state.isLoading, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The already-accepted cards stay put while the next page loads.
      expect(find.text('Scene 0'), findsOneWidget);

      harness.api.calls[1].completer.complete(
        ScenePage(total: 100, scenes: _scenes(48, start: 48)),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('failed with accepted scenes keeps cards and shows an '
        'inline banner with Retry', (tester) async {
      final api = FakeStashApi();
      api.pages.add(ScenePage(total: 200, scenes: _scenes(48)));
      final harness = await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      api.pageFailures.add(const TransportFailure());
      await harness.controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not reach the Stash server.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      // Accepted cards remain visible alongside the banner.
      expect(find.text('Scene 0'), findsOneWidget);

      api.pages.add(ScenePage(total: 200, scenes: _scenes(48, start: 48)));
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(harness.controller.state.phase, LibraryPhase.ready);
      expect(find.text('Could not reach the Stash server.'), findsNothing);
    });

    testWidgets('failed without accepted scenes shows a centered safe '
        'error and Retry, never the raw failure message', (tester) async {
      final api = FakeStashApi()
        ..pageFailures.add(const GraphQlFailure('secret internal detail'));
      final harness = await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      expect(
        find.text('The Stash server could not complete that request.'),
        findsOneWidget,
      );
      expect(find.text('secret internal detail'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

      api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(harness.controller.state.phase, LibraryPhase.ready);
    });
  });

  group('scene card formatting', () {
    testWidgets('shows formatted duration, rating, and a resume indicator', (
      tester,
    ) async {
      final scene = _scene(
        id: '1',
        title: 'Test Scene',
        rating100: 70,
        resumeTime: 30,
        files: const [SceneFile(duration: 3723)],
      );
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: [scene]));
      await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('Test Scene'), findsOneWidget);
      expect(find.text('1:02:03'), findsOneWidget);
      expect(find.text('3.5'), findsOneWidget);
      expect(find.byTooltip('Resume available'), findsOneWidget);
    });

    testWidgets('falls back to the file name, then a placeholder title, '
        'when no title is set', (tester) async {
      final named = _scene(
        id: '1',
        files: const [SceneFile(path: '/videos/My Great Scene.mp4')],
      );
      final unnamed = _scene(id: '2');
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 2, scenes: [named, unnamed]));
      await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('My Great Scene'), findsOneWidget);
      expect(find.text('Scene 2'), findsOneWidget);
    });

    testWidgets('tapping a scene card navigates via AppController.openScene', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1, start: 7)));
      final harness = await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Scene 7'));
      await tester.pump();

      expect(
        harness.container.read(appControllerProvider),
        const AppDestination.scene('7'),
      );
    });

    testWidgets('a missing/failed thumbnail falls back to the shared '
        'placeholder', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(
        tester,
        api: api,
        thumbnailRepository: FakeThumbnailRepository(),
      );
      await tester.pumpAndSettle();

      // The card wraps its whole tappable area in one `Semantics(button:
      // true, label: displayTitle)` node, which merges every descendant
      // label (including the placeholder's own "Thumbnail unavailable")
      // into a single combined announcement — the right default for a
      // screen reader navigating a card list. That means the widget type,
      // not a standalone semantics label, is the correct thing to assert
      // here; `ScenePlaceholder`'s own label contract is covered directly
      // in `shared/scene_placeholder.dart`'s own usage.
      expect(find.byType(ScenePlaceholder), findsOneWidget);
    });
  });

  group('responsive toolbar', () {
    testWidgets('at 1200 every control renders directly and search / Play '
        'random stay visible', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-search')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play random'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsNothing);
      expect(find.byType(DropdownButton<SceneSort>), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets('at 620 search / Play random stay visible and secondary '
        'controls move into a keyboard-accessible Filters popup', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(620, 900));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-search')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play random'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(find.byType(DropdownButton<SceneSort>), findsNothing);

      // Reachable by keyboard, not just a mouse tap: give the trigger
      // focus and activate it with Enter, exactly as a keyboard-only user
      // would, then confirm the secondary controls became available.
      final filtersNode = tester
          .widget<IconButton>(
            find.descendant(
              of: find.byTooltip('Filters'),
              matching: find.byType(IconButton),
            ),
          )
          .focusNode!;
      filtersNode.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, filtersNode);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButton<SceneSort>), findsOneWidget);
    });
  });

  group('sort labels', () {
    testWidgets('shows every sort option with its exact label', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<SceneSort>));
      await tester.pumpAndSettle();

      for (final label in [
        'Date',
        'Title',
        'Rating',
        'Play count',
        'Duration',
        'Date added',
        'Last updated',
        'Random',
      ]) {
        expect(find.text(label), findsWidgets);
      }
    });
  });

  group('tooltips', () {
    testWidgets('every icon-only control has a descriptive tooltip', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      // Default filter sorts descending, so the direction toggle should
      // read "Sort descending".
      expect(find.byTooltip('Sort descending'), findsOneWidget);
      expect(find.byTooltip('Minimum rating'), findsOneWidget);
      expect(find.byTooltip('Connection settings'), findsOneWidget);
      expect(find.byTooltip('Organized: any'), findsOneWidget);
    });
  });

  group('keyboard reachability', () {
    testWidgets(
      'Tab reaches search, sort, direction, minimum rating, organized, '
      'hide tracked, random, settings, and the first scene card, in order',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 2, scenes: _scenes(2)));
        await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
        await tester.pumpAndSettle();

        const expectedOrder = [
          'library-search',
          'library-sort',
          'library-direction',
          'library-minimum-rating',
          'library-organized',
          'library-hide-tracked',
          'library-random',
          'library-settings',
          'scene-card-0',
        ];

        for (final label in expectedOrder) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            FocusManager.instance.primaryFocus?.debugLabel,
            label,
            reason: 'expected focus to reach $label next',
          );
        }
      },
    );

    testWidgets('Enter activates a focused scene card the same as a tap', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      final harness = await _pumpLibrary(
        tester,
        api: api,
        size: const Size(1200, 900),
      );
      await tester.pumpAndSettle();

      for (var i = 0; i < 9; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'scene-card-0');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(
        harness.container.read(appControllerProvider),
        const AppDestination.scene('0'),
      );
    });
  });

  group('clear filters', () {
    testWidgets(
      'genuinely clears query, minimum rating, organized, and hide tracked '
      'on the outgoing request',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        final harness = await _pumpLibrary(tester, api: api);
        await tester.pumpAndSettle();

        api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await harness.controller.setQuery('bunnies');
        api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await harness.controller.setMinimumRating(80);
        api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await harness.controller.setOrganized(true);
        api.pages.add(ScenePage(total: 0, scenes: const []));
        await harness.controller.setHideTracked(true);
        await tester.pumpAndSettle();

        expect(harness.controller.state.filter.query, 'bunnies');
        expect(harness.controller.state.filter.minimumRating, 80);
        expect(harness.controller.state.filter.organized, isTrue);
        expect(find.text('No scenes match these filters'), findsOneWidget);

        // "Clear filters" issues its own four sequential `set*` calls
        // (see `LibraryScreen._clearFilters`) — one queued page per call.
        api.pages.addAll([
          ScenePage(total: 1, scenes: _scenes(1)),
          ScenePage(total: 1, scenes: _scenes(1)),
          ScenePage(total: 1, scenes: _scenes(1)),
          ScenePage(total: 1, scenes: _scenes(1)),
        ]);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
        await tester.pumpAndSettle();

        final outgoing = api.requestedFilters.last;
        expect(outgoing.query, '');
        expect(outgoing.minimumRating, isNull);
        expect(outgoing.organized, isNull);
        expect(outgoing.hideTracked, isFalse);
      },
    );
  });

  group('viewport fill loop', () {
    testWidgets('a viewport taller than one page keeps requesting pages, '
        're-measuring after each, until it is filled or exhausted', (
      tester,
    ) async {
      final api = FakeStashApi();
      api.pages.addAll([
        ScenePage(total: 100, scenes: _scenes(48)),
        ScenePage(total: 100, scenes: _scenes(48, start: 48)),
        ScenePage(total: 100, scenes: _scenes(4, start: 96)),
      ]);
      final harness = await _pumpLibrary(
        tester,
        api: api,
        size: const Size(1200, 20000),
      );
      await tester.pumpAndSettle();

      expect(api.requestedPages, [1, 2, 3]);
      expect(harness.controller.state.hasMore, isFalse);
      expect(harness.controller.state.scenes, hasLength(100));
    });

    testWidgets('stops re-requesting once the widget is unmounted', (
      tester,
    ) async {
      final api = FakeStashApi();
      api.pages.add(ScenePage(total: 100, scenes: _scenes(48)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 20000));
      await tester.pump();

      // Unmount mid-flight, before the next page's post-frame check
      // would fire.
      await tester.pumpWidget(const SizedBox.shrink());

      // Must not throw (a stray callback touching a disposed
      // controller/widget would).
      await tester.pumpAndSettle();
    });
  });

  group('load more on scroll', () {
    testWidgets(
      'scrolling within 600 logical pixels of the bottom requests another '
      'page',
      (tester) async {
        final api = FakeStashApi();
        api.pages.addAll([
          ScenePage(total: 200, scenes: _scenes(48)),
          ScenePage(total: 200, scenes: _scenes(48, start: 48)),
        ]);
        await _pumpLibrary(tester, api: api, size: const Size(1200, 800));
        await tester.pumpAndSettle();
        expect(api.requestedPages, [1]);

        final gridView = tester.widget<GridView>(
          find.byKey(const Key('library-scene-grid')),
        );
        final scrollController = gridView.controller!;
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
        await tester.pumpAndSettle();

        expect(api.requestedPages, containsAllInOrder([1, 2]));
      },
    );
  });
}
