import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/library/library_controller.dart';
import 'package:stash_player_flutter/features/library/library_state.dart';

import '../../support/fakes.dart';

List<Scene> scenes(int count, {int start = 0}) => List.generate(
  count,
  (index) => Scene(id: '${start + index}', paths: const ScenePaths()),
);

void main() {
  late FakeStashApi api;
  late int nextSeed;
  late LibraryController controller;

  setUp(() {
    api = FakeStashApi();
    nextSeed = 1000;
    controller = LibraryController(api: api, seedGenerator: () => nextSeed++);
  });

  group('initial state', () {
    test('starts with the default filter and untouched paging state', () {
      expect(controller.state.filter, const SceneFilter());
      expect(controller.state.scenes, isEmpty);
      expect(controller.state.page, 0);
      expect(controller.state.total, 0);
      expect(controller.state.phase, LibraryPhase.initial);
      expect(controller.state.generation, 0);
      expect(controller.state.hasMore, isTrue);
      expect(controller.state.failure, isNull);
      expect(controller.state.isLoading, isFalse);
    });
  });

  group('filter changes', () {
    test(
      'loadInitial fetches page 1 at generation 0 without bumping it',
      () async {
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));

        await controller.loadInitial();

        expect(controller.state.generation, 0);
        expect(controller.state.page, 1);
        expect(controller.state.phase, LibraryPhase.ready);
        expect(api.requestedPages, [1]);
      },
    );

    test(
      'setQuery resets paging, bumps generation, and requests page 1',
      () async {
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
        await controller.loadInitial();
        api.pages.add(ScenePage(total: 1, scenes: scenes(1, start: 5)));

        await controller.setQuery('bunnies');

        expect(controller.state.filter.query, 'bunnies');
        expect(controller.state.generation, 1);
        expect(controller.state.page, 1);
        expect(controller.state.scenes.map((s) => s.id), ['5']);
        expect(api.requestedPages, [1, 1]);
      },
    );

    test(
      'setSort resets paging, bumps generation, and requests page 1',
      () async {
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
        await controller.loadInitial();
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));

        await controller.setSort(SceneSort.title);

        expect(controller.state.filter.sort, SceneSort.title);
        expect(controller.state.generation, 1);
        expect(api.requestedPages, [1, 1]);
      },
    );

    test(
      'setDirection resets paging, bumps generation, and requests page 1',
      () async {
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
        await controller.loadInitial();
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));

        await controller.setDirection(SortDirection.ascending);

        expect(controller.state.filter.direction, SortDirection.ascending);
        expect(controller.state.generation, 1);
        expect(api.requestedPages, [1, 1]);
      },
    );

    test('setMinimumRating sets and clears the filter field', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.loadInitial();

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setMinimumRating(80);
      expect(controller.state.filter.minimumRating, 80);
      expect(controller.state.generation, 1);

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setMinimumRating(null);
      expect(controller.state.filter.minimumRating, isNull);
      expect(controller.state.generation, 2);

      expect(api.requestedPages, [1, 1, 1]);
    });

    test('setOrganized sets and clears the filter field', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.loadInitial();

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setOrganized(true);
      expect(controller.state.filter.organized, isTrue);
      expect(controller.state.generation, 1);

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setOrganized(null);
      expect(controller.state.filter.organized, isNull);
      expect(controller.state.generation, 2);

      expect(api.requestedPages, [1, 1, 1]);
    });

    test(
      'setHideTracked resets paging, bumps generation, and requests page 1',
      () async {
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
        await controller.loadInitial();
        api.pages.add(ScenePage(total: 1, scenes: scenes(1)));

        await controller.setHideTracked(false);

        expect(controller.state.filter.hideTracked, isFalse);
        expect(controller.state.generation, 1);
        expect(api.requestedPages, [1, 1]);
      },
    );

    test('a filter change discards scenes/page/total from before it', () async {
      api.pages.add(ScenePage(total: 120, scenes: scenes(48, start: 0)));
      await controller.loadInitial();
      expect(controller.state.scenes, hasLength(48));

      api.pages.add(ScenePage(total: 1, scenes: scenes(1, start: 900)));
      await controller.setQuery('reset me');

      expect(controller.state.scenes.map((s) => s.id), ['900']);
      expect(controller.state.page, 1);
      expect(controller.state.total, 1);
    });
  });

  group('pagination', () {
    test(
      'continues loading until viewport is filled or results exhaust',
      () async {
        api.pages.addAll([
          ScenePage(total: 120, scenes: scenes(48, start: 0)),
          ScenePage(total: 120, scenes: scenes(48, start: 48)),
        ]);
        await controller.loadInitial();
        await controller.ensureViewportFilled(
          contentExtent: 500,
          viewportExtent: 900,
        );
        expect(api.requestedPages, [1, 2]);
      },
    );

    test('ensureViewportFilled does nothing once the content already fills '
        'the viewport', () async {
      api.pages.add(ScenePage(total: 120, scenes: scenes(48)));
      await controller.loadInitial();

      await controller.ensureViewportFilled(
        contentExtent: 1000,
        viewportExtent: 900,
      );

      expect(api.requestedPages, [1]);
    });

    test('a page shorter than the page size terminates paging even when the '
        'reported total suggests more', () async {
      api.pages.add(ScenePage(total: 200, scenes: scenes(10)));

      await controller.loadInitial();

      expect(controller.state.hasMore, isFalse);
      expect(controller.state.scenes, hasLength(10));

      await controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );
      expect(api.calls, hasLength(1));
    });

    test('reaching the reported total terminates paging even on a full-size '
        'page', () async {
      api.pages.add(ScenePage(total: 48, scenes: scenes(48)));

      await controller.loadInitial();

      expect(controller.state.hasMore, isFalse);
      expect(controller.state.scenes, hasLength(48));

      await controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );
      expect(api.calls, hasLength(1));
    });

    test('dedupes accepted scenes by id across pages when the underlying '
        'result set shifts', () async {
      api.pages.addAll([
        ScenePage(total: 100, scenes: scenes(48, start: 0)),
        // Overlaps the previous page by exactly one id ("47") — the
        // classic symptom of the result set shifting between requests.
        ScenePage(total: 100, scenes: scenes(48, start: 47)),
      ]);

      await controller.loadInitial();
      await controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );

      final ids = controller.state.scenes.map((s) => s.id).toList();
      expect(ids, hasLength(95));
      expect(ids.toSet(), hasLength(95));
      expect(ids.where((id) => id == '47'), hasLength(1));
    });

    test(
      'does not start a second request while one is already in flight',
      () async {
        final first = controller.loadInitial();
        final second = controller.loadInitial();

        expect(api.calls, hasLength(1));

        api.calls.single.completer.complete(
          ScenePage(total: 1, scenes: scenes(1)),
        );
        await first;
        await second;

        expect(controller.state.scenes, hasLength(1));
      },
    );

    test('ensureViewportFilled does not start a second request while its own '
        'page fetch is already in flight', () async {
      api.pages.add(ScenePage(total: 120, scenes: scenes(48)));
      await controller.loadInitial();

      final first = controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );
      final second = controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );

      expect(api.calls, hasLength(2)); // page 1 (loadInitial) + page 2

      api.calls[1].completer.complete(
        ScenePage(total: 120, scenes: scenes(48, start: 48)),
      );
      await first;
      await second;

      expect(controller.state.scenes, hasLength(96));
      expect(api.calls, hasLength(2)); // still just the one page-2 request
    });

    test('a paging error preserves already-accepted scenes, and retry '
        're-requests the same page', () async {
      api.pages.add(ScenePage(total: 120, scenes: scenes(48, start: 0)));
      await controller.loadInitial();
      expect(controller.state.scenes, hasLength(48));

      api.pageFailures.add(const TransportFailure());
      await controller.ensureViewportFilled(
        contentExtent: 100,
        viewportExtent: 900,
      );

      expect(controller.state.phase, LibraryPhase.failed);
      expect(controller.state.failure, isA<TransportFailure>());
      expect(controller.state.scenes, hasLength(48));
      expect(controller.state.page, 1);
      expect(api.requestedPages, [1, 2]);

      api.pages.add(ScenePage(total: 120, scenes: scenes(48, start: 48)));
      await controller.retry();

      expect(controller.state.phase, LibraryPhase.ready);
      expect(controller.state.failure, isNull);
      expect(controller.state.scenes, hasLength(96));
      expect(controller.state.page, 2);
      expect(api.requestedPages, [1, 2, 2]);
    });
  });

  group('races', () {
    test(
      'a stale response from a superseded generation is discarded',
      () async {
        final firstLoad = controller.loadInitial();
        expect(controller.state.generation, 0);

        final secondLoad = controller.setQuery('cats');
        expect(controller.state.generation, 1);
        expect(api.calls, hasLength(2));

        api.calls[1].completer.complete(
          ScenePage(total: 1, scenes: scenes(1, start: 9)),
        );
        await secondLoad;

        expect(controller.state.generation, 1);
        expect(controller.state.scenes.map((s) => s.id), ['9']);
        expect(controller.state.phase, LibraryPhase.ready);

        api.calls[0].completer.complete(
          ScenePage(total: 1, scenes: scenes(1, start: 99)),
        );
        await firstLoad;

        // The late generation-0 response must not clobber what generation
        // 1 already accepted.
        expect(controller.state.generation, 1);
        expect(controller.state.scenes.map((s) => s.id), ['9']);
        expect(controller.state.phase, LibraryPhase.ready);
      },
    );

    test(
      'a stale error from a superseded generation is discarded too',
      () async {
        final firstLoad = controller.loadInitial();
        final secondLoad = controller.setQuery('cats');

        api.calls[1].completer.complete(
          ScenePage(total: 1, scenes: scenes(1, start: 9)),
        );
        await secondLoad;

        api.calls[0].completer.completeError(const TransportFailure());
        await firstLoad;

        expect(controller.state.generation, 1);
        expect(controller.state.phase, LibraryPhase.ready);
        expect(controller.state.failure, isNull);
        expect(controller.state.scenes.map((s) => s.id), ['9']);
      },
    );
  });

  group('random play', () {
    test(
      'reuses the same random seed across pages while sort stays random',
      () async {
        api.pages.addAll([
          ScenePage(total: 100, scenes: scenes(48, start: 0)),
          ScenePage(total: 100, scenes: scenes(48, start: 48)),
        ]);

        await controller.setSort(SceneSort.random);
        final firstSeed = controller.state.filter.randomSeed;
        expect(firstSeed, isNotNull);

        await controller.ensureViewportFilled(
          contentExtent: 100,
          viewportExtent: 900,
        );

        expect(controller.state.filter.randomSeed, firstSeed);
        expect(api.requestedFilters[0].randomSeed, firstSeed);
        expect(api.requestedFilters[1].randomSeed, firstSeed);
      },
    );

    test('leaving random sort clears the seed', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setSort(SceneSort.random);
      expect(controller.state.filter.randomSeed, isNotNull);

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setSort(SceneSort.createdAt);

      expect(controller.state.filter.randomSeed, isNull);
    });

    test('playRandom requests a fresh seed at page 1/per-page 1 and returns '
        'the scene', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1, start: 7)));

      final result = await controller.playRandom();

      expect(result, isA<RandomSceneFound>());
      expect((result as RandomSceneFound).scene.id, '7');
      expect(api.requestedPages, [1]);
      expect(api.requestedPerPage, [1]);
      expect(api.requestedFilters.single.sort, SceneSort.random);
      expect(api.requestedFilters.single.randomSeed, isNotNull);
    });

    test(
      'playRandom returns an explicit empty result when nothing matches',
      () async {
        api.pages.add(ScenePage(total: 0, scenes: const []));

        final result = await controller.playRandom();

        expect(result, isA<RandomSceneEmpty>());
      },
    );

    test('playRandom generates a fresh seed on every call', () async {
      api.pages.addAll([
        ScenePage(total: 1, scenes: scenes(1)),
        ScenePage(total: 1, scenes: scenes(1)),
      ]);

      await controller.playRandom();
      await controller.playRandom();

      expect(
        api.requestedFilters[0].randomSeed,
        isNot(api.requestedFilters[1].randomSeed),
      );
    });

    test('playRandom does not touch the browsed grid state', () async {
      api.pages.add(ScenePage(total: 120, scenes: scenes(48)));
      await controller.loadInitial();

      api.pages.add(ScenePage(total: 1, scenes: scenes(1, start: 500)));
      await controller.playRandom();

      expect(controller.state.scenes, hasLength(48));
      expect(controller.state.filter.sort, SceneSort.createdAt);
    });
  });
}
