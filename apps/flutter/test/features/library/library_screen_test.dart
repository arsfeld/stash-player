import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/library/library_controller.dart';
import 'package:stash_player_flutter/features/library/library_screen.dart';
import 'package:stash_player_flutter/features/library/library_state.dart';
import 'package:stash_player_flutter/features/library/library_toolbar.dart';
import 'package:stash_player_flutter/services/thumbnail_repository.dart';
import 'package:stash_player_flutter/shared/scene_placeholder.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/filter_controls.dart';
import 'package:stash_player_flutter/ui/widgets/scene_tile.dart';

import '../../support/fakes.dart';

Scene _scene({
  required String id,
  String? title,
  int? rating100,
  double? resumeTime,
  String? screenshot,
  List<SceneFile> files = const [],
}) => Scene(
  id: id,
  paths: ScenePaths(screenshot: screenshot),
  title: title,
  rating100: rating100,
  resumeTime: resumeTime,
  files: files,
);

List<Scene> _scenes(int count, {int start = 0}) =>
    List.generate(count, (i) => _scene(id: '${start + i}'));

/// A minimal, genuinely decodable 1x1 transparent PNG — used wherever a
/// test needs `Image.memory` to actually succeed rather than merely
/// receiving non-empty bytes (arbitrary bytes would fail to decode and
/// could surface as an async image error rather than exercising the
/// success path this is meant to test).
final Uint8List _transparentPng = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

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
        theme: buildAppTheme(Brightness.light),
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
        // No pages configured, and `allowManualCompletion` opts out of
        // `FakeStashApi`'s drain-safety default (final review §3b): the
        // controller stays in `loading` forever — exactly the
        // "initial/loading with no data" bucket — instead of the call
        // completing with a `StateError`. Deliberately bounded pumps
        // rather than `pumpAndSettle`: the indeterminate
        // `CircularProgressIndicator` this state renders schedules
        // frames forever, which `pumpAndSettle` would wait on forever
        // too.
        await _pumpLibrary(
          tester,
          api: FakeStashApi()..allowManualCompletion = true,
        );
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
      final api = FakeStashApi()..allowManualCompletion = true;
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

    testWidgets('a scene with a screenshot and a successfully loaded thumbnail '
        'renders as an Image', (tester) async {
      final scene = _scene(id: '1', screenshot: 'thumb.jpg');
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: [scene]));
      await _pumpLibrary(
        tester,
        api: api,
        thumbnailRepository: FakeThumbnailRepository(bytes: _transparentPng),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(SceneTile),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.byType(ScenePlaceholder), findsNothing);
    });

    testWidgets(
      'a scene with a screenshot that fails to load falls back to the '
      'placeholder, not a crash',
      (tester) async {
        final scene = _scene(id: '1', screenshot: 'thumb.jpg');
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: [scene]));
        // `bytes: null` (the default) is exactly what `ThumbnailRepository`
        // resolves to for a failed fetch/decode per its own contract.
        await _pumpLibrary(
          tester,
          api: api,
          thumbnailRepository: FakeThumbnailRepository(),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ScenePlaceholder), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SceneTile),
            matching: find.byType(Image),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'does not re-fetch an already-served or in-flight thumbnail when an '
      'unrelated state change rebuilds the still-visible card',
      (tester) async {
        // Reproduces the exact failure scenario: `LibraryScreen` watches
        // the whole `ChangeNotifierProvider`, so the `phase: loading`
        // notification a page-2 fetch fires rebuilds every card that's
        // still on screen from page 1 — calling `repository.load` again
        // for those already-fetched sources without the fix in
        // `_SceneThumbnailState` (Finding 1). Page 1 must be a full,
        // exactly-`libraryPageSize`-long page: `hasMore` (and so whether
        // a second page can even be requested at all) goes false the
        // instant a page comes back shorter than that, regardless of
        // `total` — see `LibraryController._fetchNextPage`.
        final page1Sources = List.generate(48, (i) => 'thumb-$i.jpg');
        final page1 = List.generate(
          48,
          (i) => _scene(id: '$i', screenshot: page1Sources[i]),
        );
        final api = FakeStashApi()
          ..allowManualCompletion = true
          ..pages.add(ScenePage(total: 100, scenes: page1));
        final thumbnailRepo = FakeThumbnailRepository(bytes: _transparentPng);
        final harness = await _pumpLibrary(
          tester,
          api: api,
          thumbnailRepository: thumbnailRepo,
          size: const Size(1200, 900),
        );
        await tester.pumpAndSettle();

        // Only the cards actually laid out within the (finite) test
        // viewport get built by the lazy `GridView.builder`, so this
        // asserts a non-empty subset of page 1 was fetched exactly once
        // each, not the full 48.
        final afterPage1 = List<String>.of(thumbnailRepo.requestedSources);
        expect(afterPage1, isNotEmpty);
        expect(afterPage1.toSet().length, afterPage1.length); // no dupes yet
        expect(page1Sources.toSet().containsAll(afterPage1), isTrue);

        // Start a page-2 fetch without letting it resolve yet — this is
        // the `phase: loading` notify that rebuilds every visible card.
        final pending = harness.controller.ensureViewportFilled(
          contentExtent: 100,
          viewportExtent: 900,
        );
        await tester.pump();
        expect(harness.controller.state.isLoading, isTrue);

        // The already-fetched page-1 thumbnails must not be re-requested
        // just because the controller notified its listeners.
        expect(thumbnailRepo.requestedSources, afterPage1);

        api.calls[1].completer.complete(
          ScenePage(
            total: 100,
            scenes: [_scene(id: '48', screenshot: 'thumb-48.jpg')],
          ),
        );
        await pending;
        await tester.pumpAndSettle();

        // Page 1's already-fetched sources are still not repeated once
        // page 2 lands and the grid rebuilds again, and everything
        // fetched so far is still unique — item 48 itself isn't asserted
        // here since it's appended off the end of the list and, being
        // outside the finite test viewport, is never built/fetched by
        // the lazy `GridView.builder` in the first place.
        final afterPage2 = thumbnailRepo.requestedSources;
        expect(afterPage2.toSet().length, afterPage2.length);
        expect(afterPage2, containsAll(afterPage1));
      },
    );
  });

  group('card metadata overflow', () {
    Scene longTitledScene() => _scene(
      id: '1',
      title: 'A reasonably long scene title for overflow testing',
      rating100: 80,
      files: const [SceneFile(duration: 3723)],
    );

    testWidgets('does not overflow at a narrow window width inside the '
        'known-bad band', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: [longTitledScene()]));
      await _pumpLibrary(tester, api: api, size: const Size(500, 900));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow at an increased system text scale', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: [longTitledScene()]));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
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
      expect(find.byTooltip('Play random'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsNothing);
      expect(find.byType(AppMenuButton<SceneSort>), findsOneWidget);
      expect(find.byTooltip('Organized: any'), findsOneWidget);
      expect(
        find.byTooltip('Hide scenes that have already been played'),
        findsOneWidget,
      );
    });

    testWidgets('at 620 search / Play random stay visible and secondary '
        'controls move into a Filters row, opened by a mouse tap', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(620, 900));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-search')), findsOneWidget);
      expect(find.byTooltip('Play random'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(find.byType(AppMenuButton<SceneSort>), findsNothing);

      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();

      expect(find.byType(AppMenuButton<SceneSort>), findsOneWidget);
    });

    testWidgets(
      'at 620, Tab reaches the Filters trigger, Enter opens it, and Tab '
      'then walks and can activate every secondary control inside — not '
      'just a mouse-openable popup',
      (tester) async {
        // Regression test for a real, previously-shipped bug: an earlier
        // version used a `MenuAnchor` popup here. `Enter` did open it and
        // its contents were findable, but a dedicated probe showed `Tab`
        // from the (still-focused) trigger jumped straight past the
        // entire open overlay to "Play random" — none of the five
        // secondary controls were reachable by keyboard at all, because
        // `MenuAnchor`'s overlay isn't part of the surrounding page's
        // focus-traversal chain. The fix replaced it with an in-tree
        // collapsible row (see `LibraryToolbar`'s class doc), which this
        // test exercises end-to-end by keyboard only.
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await _pumpLibrary(tester, api: api, size: const Size(620, 900));
        await tester.pumpAndSettle();

        // Reach the trigger the same way a keyboard-only user would —
        // sequential Tab from nothing, not `FocusNode.requestFocus()`.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab); // search
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab); // filters trigger
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'library-filters',
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AppMenuButton<SceneSort>), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab); // sort
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-sort');

        await tester.sendKeyEvent(LogicalKeyboardKey.tab); // direction
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'library-direction',
        );

        // Activate it — not just reachable, but usable by keyboard.
        api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(api.requestedFilters.last.direction, SortDirection.ascending);

        for (final label in [
          'library-minimum-rating',
          'library-organized',
          'library-hide-tracked',
        ]) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(FocusManager.instance.primaryFocus?.debugLabel, label);
        }

        // Tab continues on into the primary row afterward, exactly as at
        // the wide breakpoint.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab); // random
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'library-random',
        );
      },
    );

    testWidgets('every strip control carries a tooltip', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      // This test is the stated reason icon-only controls are acceptable
      // at all, so it has to be able to fail. Asserting only that every
      // widget found has a non-empty tooltip could not: both
      // constructors already assert exactly that, so a widget capable of
      // failing it cannot be constructed, and an empty strip passed the
      // whole thing vacuously. Pinning the exact set fails instead when
      // a control is dropped, when one is added without being listed
      // here, when wording changes silently, and (through
      // `find.byTooltip`) when the `Tooltip` stops being composed into
      // the tree even though the field is still set.
      const expectedToggles = <(String, String)>[
        ('Sort descending', 'Sort descending'),
        ('Organized: any', 'Organized filter: any'),
        ('Hide scenes that have already been played', 'Hide tracked scenes'),
      ];
      const expectedActions = <(String, String)>[
        ('Play random', 'Play a random scene'),
        ('Connection settings', 'Connection settings'),
      ];
      const expectedMenus = ['Sort by', 'Minimum rating'];

      final toggles = tester
          .widgetList<AppIconToggle>(find.byType(AppIconToggle))
          .toList();
      expect(toggles, hasLength(expectedToggles.length));
      expect(
        toggles.map((toggle) => (toggle.tooltip, toggle.semanticLabel)),
        expectedToggles,
      );

      final actions = tester
          .widgetList<AppIconAction>(find.byType(AppIconAction))
          .toList();
      expect(actions, hasLength(expectedActions.length));
      expect(
        actions.map((action) => (action.tooltip, action.semanticLabel)),
        expectedActions,
      );

      for (final tooltip in [
        ...expectedToggles.map((entry) => entry.$1),
        ...expectedActions.map((entry) => entry.$1),
        ...expectedMenus,
      ]) {
        expect(
          find.byTooltip(tooltip),
          findsOneWidget,
          reason: 'no strip control renders the tooltip "$tooltip"',
        );
      }
    });
  });

  group('sort labels', () {
    testWidgets('shows every sort option with its exact label', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AppMenuButton<SceneSort>));
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

    testWidgets(
      'each label sends its own distinct SceneSort on the wire — swapping '
      'any two labels in _sortLabel would pass the label-presence test '
      'above but fail this one (final review §3b)',
      (tester) async {
        final api = FakeStashApi()
          // One page per sort selection below, plus the initial load —
          // otherwise `FakeStashApi.findScenes` hangs forever once the
          // queue drains instead of failing (a separate, also-fixed
          // final review §3b gap), and `pumpAndSettle` times out.
          ..pages.addAll(
            List.generate(9, (_) => ScenePage(total: 1, scenes: _scenes(1))),
          );
        await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
        await tester.pumpAndSettle();

        // Ordered so every selection genuinely differs from both the
        // default filter's sort (`SceneFilter.sort` defaults to
        // `createdAt`, i.e. "Date added") and the previous iteration's —
        // a same-value reselection could otherwise leave
        // `api.requestedFilters.last` reflecting a stale request instead
        // of proving this iteration's own mapping.
        const labelToSort = <String, SceneSort>{
          'Date': SceneSort.date,
          'Title': SceneSort.title,
          'Rating': SceneSort.rating,
          'Play count': SceneSort.playCount,
          'Duration': SceneSort.duration,
          'Last updated': SceneSort.updatedAt,
          'Random': SceneSort.random,
          'Date added': SceneSort.createdAt,
        };

        for (final entry in labelToSort.entries) {
          await tester.tap(find.byType(AppMenuButton<SceneSort>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(entry.key).last);
          await tester.pumpAndSettle();

          expect(
            api.requestedFilters.last.sort,
            entry.value,
            reason: '"${entry.key}" must request SceneSort.${entry.value.name}',
          );
        }
      },
    );
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

  group('search debounce', () {
    testWidgets(
      'coalesces rapid typing into exactly one outgoing request, 250ms '
      'after the last keystroke',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await _pumpLibrary(tester, api: api);
        await tester.pumpAndSettle();
        expect(api.calls, hasLength(1)); // the initial load only, so far

        api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        final searchField = find.byKey(const Key('library-search'));
        await tester.enterText(searchField, 'a');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(searchField, 'ab');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(searchField, 'abc');
        // Each keystroke above landed well inside the previous one's
        // 250ms window, so only the *last* debounce timer should ever
        // fire — this pump is long enough to let it.
        await tester.pump(const Duration(milliseconds: 300));

        expect(api.calls, hasLength(2)); // initial load + exactly one query
        expect(api.requestedFilters.last.query, 'abc');
      },
    );

    testWidgets(
      'typing then unmounting before the debounce fires does not throw',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        final harness = await _pumpLibrary(tester, api: api);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('library-search')),
          'partial',
        );
        // The 250ms debounce timer is now armed but hasn't fired.
        await tester.pumpWidget(const SizedBox.shrink());
        // Dispose the controller for real, *here* — inside the test body,
        // before the timer fires — rather than relying only on the
        // `addTearDown(container.dispose)` `_pumpLibrary` already
        // registers, which doesn't run until after this test body
        // returns.
        //
        // This exercises the widget-level `mounted` guard in
        // `LibraryToolbar._onSearchChanged` for real (the widget is
        // genuinely unmounted before the timer fires). It does *not*, on
        // its own, prove anything about the controller-level `_disposed`
        // guard in `LibraryController._resetAndFetch`: that guard is
        // structurally unreachable from this path, since the widget-level
        // `mounted` check returns before ever calling into the controller
        // — true whether or not the controller has also been disposed by
        // then. `library_controller_test.dart`'s own disposal group has a
        // direct test for that guard instead (final review §3b — an
        // earlier version of this comment claimed this test covered both,
        // which does not hold up).
        harness.container.dispose();

        // Must not throw once the timer's original fire time passes —
        // regression guard for the widget-level `mounted` check in
        // `LibraryToolbar._onSearchChanged`.
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull);
      },
    );
  });

  group('play random', () {
    testWidgets('a successful pick navigates to the chosen scene', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      final harness = await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      api.pages.add(ScenePage(total: 1, scenes: _scenes(1, start: 99)));
      await tester.tap(find.byTooltip('Play random'));
      await tester.pumpAndSettle();

      expect(
        harness.container.read(appControllerProvider),
        const AppDestination.scene('99'),
      );
    });

    testWidgets('no matches shows a dismissible info notice', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      final harness = await _pumpLibrary(tester, api: api);
      await tester.pumpAndSettle();

      api.pages.add(ScenePage(total: 0, scenes: const []));
      await tester.tap(find.byTooltip('Play random'));
      await tester.pumpAndSettle();

      final notice = harness.container.read(globalNoticeProvider);
      expect(notice?.message, 'No scenes match these filters');
      expect(notice?.severity, AppNoticeSeverity.info);
    });

    testWidgets(
      'a server failure shows an error notice instead of an unhandled '
      'exception',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        final harness = await _pumpLibrary(tester, api: api);
        await tester.pumpAndSettle();

        api.pageFailures.add(const TransportFailure());
        await tester.tap(find.byTooltip('Play random'));
        await tester.pumpAndSettle();

        final notice = harness.container.read(globalNoticeProvider);
        expect(notice?.message, 'Could not reach the Stash server.');
        expect(notice?.severity, AppNoticeSeverity.error);
        // No card navigation happened as a side effect of the failure.
        expect(
          harness.container.read(appControllerProvider),
          const AppDestination.connection(),
        );
      },
    );
  });

  group('keyboard reachability', () {
    testWidgets('Tab reaches sort, direction, minimum rating, organized, hide '
        'tracked, random, search, settings, and the first scene card, in '
        'the order they render', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 2, scenes: _scenes(2)));
      await _pumpLibrary(tester, api: api, size: const Size(1200, 900));
      await tester.pumpAndSettle();

      // Focus order follows the wide strip's visual order (WCAG 2.4.3),
      // so the search field is visited where it renders, seventh,
      // rather than first. The narrow layout reads in a different
      // order and pins its own sequence in the test above.
      const expectedOrder = [
        'library-sort',
        'library-direction',
        'library-minimum-rating',
        'library-organized',
        'library-hide-tracked',
        'library-random',
        'library-search',
        'library-settings',
        'scene-tile-0',
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
    });

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
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'scene-tile-0');

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

        // "Clear filters" now forwards straight to
        // `LibraryController.clearFilters()`, a single request rather
        // than four chained `set*` calls — one queued page, and the
        // call count assertion below, is what pins that.
        final callsBeforeClear = api.calls.length;
        api.pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
        await tester.pumpAndSettle();

        expect(api.calls, hasLength(callsBeforeClear + 1));

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

      final requestedPagesAtUnmount = List.of(api.requestedPages);

      // Unmount mid-flight, before the next page's post-frame check
      // would fire.
      await tester.pumpWidget(const SizedBox.shrink());

      // Must not throw (a stray callback touching a disposed
      // controller/widget would) — though note that on its own this is
      // weak: `ScrollController.hasClients` doesn't assert on an already
      // -disposed controller, and `State.widget`/`mounted` stay readable
      // after unmount, so a *removed* `_scheduleViewportCheck` `mounted`
      // guard wouldn't make this throw either (final review §3b). The
      // real regression this guards against is a *page still being
      // requested* after unmount, which the assertion below actually
      // pins.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(api.requestedPages, requestedPagesAtUnmount);
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

  group('organized cycle', () {
    test('cycles any, yes, no, back to any', () {
      expect(cycleOrganized(null), isTrue);
      expect(cycleOrganized(true), isFalse);
      expect(cycleOrganized(false), isNull);
    });
  });
}
