import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/features/library/library_controller.dart';
import 'package:stash_player_flutter/features/library/library_state.dart';
import 'package:stash_player_flutter/services/stash_api.dart';

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
        expect(api.requestedPerPage, [libraryPageSize]);
        // The library opens to untracked-only by default — assert it on
        // what actually went out over the wire, not just on
        // `controller.state.filter`, which could diverge from the
        // request if a reset captured the filter before applying this.
        expect(api.requestedFilters.first.hideTracked, isTrue);
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
        // Must be what was actually sent, not just what `state` ended up
        // holding — a controller that updated `_state.filter` correctly
        // but requested with a stale filter would still pass the checks
        // above.
        expect(api.requestedFilters.last.query, 'bunnies');
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
        expect(api.requestedFilters.last.sort, SceneSort.title);
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
        expect(api.requestedFilters.last.direction, SortDirection.ascending);
      },
    );

    test('setMinimumRating sets and clears the filter field', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.loadInitial();

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setMinimumRating(80);
      expect(controller.state.filter.minimumRating, 80);
      expect(controller.state.generation, 1);
      expect(api.requestedFilters.last.minimumRating, 80);

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setMinimumRating(null);
      expect(controller.state.filter.minimumRating, isNull);
      expect(controller.state.generation, 2);
      expect(api.requestedFilters.last.minimumRating, isNull);

      expect(api.requestedPages, [1, 1, 1]);
    });

    test('setOrganized sets and clears the filter field', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.loadInitial();

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setOrganized(true);
      expect(controller.state.filter.organized, isTrue);
      expect(controller.state.generation, 1);
      expect(api.requestedFilters.last.organized, isTrue);

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setOrganized(null);
      expect(controller.state.filter.organized, isNull);
      expect(controller.state.generation, 2);
      expect(api.requestedFilters.last.organized, isNull);

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
        expect(api.requestedFilters.last.hideTracked, isFalse);
      },
    );

    test('clearFilters resets query, minimum rating, organized, and hide '
        'tracked in a single request', () async {
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.loadInitial();
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setQuery('bunnies');
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setMinimumRating(80);
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.setOrganized(true);
      expect(controller.state.filter.query, 'bunnies');
      expect(controller.state.filter.minimumRating, 80);
      expect(controller.state.filter.organized, isTrue);

      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      final callsBefore = api.calls.length;

      await controller.clearFilters();

      // Exactly one more request went out — not one per field cleared.
      expect(api.calls, hasLength(callsBefore + 1));
      final outgoing = api.requestedFilters.last;
      expect(outgoing.query, '');
      expect(outgoing.minimumRating, isNull);
      expect(outgoing.organized, isNull);
      expect(outgoing.hideTracked, isFalse);
      // Sort/direction are untouched — they don't affect whether any
      // scenes match, only their order.
      expect(outgoing.sort, controller.state.filter.sort);
    });

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
        // Pins the "library page size is exactly 48" constraint in the
        // direction that actually matters: what was requested, not just
        // what the fixture happened to return.
        expect(api.requestedPerPage, [48, 48]);
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
      expect(api.requestedPerPage, [48]);
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
      expect(api.requestedPerPage, [48]);
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

      // Cardinality, order, and first-copy-wins all in one assertion: a
      // dedupe that merged with the incoming copy winning, or that
      // sorted, or that just deduped without preserving arrival order,
      // would all fail this even though they'd pass a length-only or
      // set-only check.
      final ids = controller.state.scenes.map((s) => s.id).toList();
      expect(ids, List.generate(95, (i) => '$i'));
      expect(api.requestedPerPage, [48, 48]);
    });

    test(
      'does not start a second request while one is already in flight',
      () async {
        api.allowManualCompletion = true;
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
      api.allowManualCompletion = true;
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

    test('a non-Failure throw still lands the controller in failed with a '
        'usable retry, rather than wedging it in loading forever', () async {
      // `StashApi` implementations normalize every error to a
      // `Failure`, but the real `_DeferredStashApi` adapter that
      // `libraryControllerProvider` wires up can throw a bare platform
      // exception (e.g. secure storage/keyring access denied) while
      // resolving the API instance itself, before any `StashApi` code
      // runs at all. `_fetchNextPage`'s `on Failure` alone wouldn't
      // catch that.
      api.pageRawErrors.add(StateError('secret service locked'));

      await controller.loadInitial();

      expect(controller.state.phase, LibraryPhase.failed);
      expect(controller.state.failure, isNotNull);
      expect(controller.state.isLoading, isFalse);

      // And it must actually be recoverable — not just "failed" in
      // name while every entry point still refuses to run.
      api.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      await controller.retry();

      expect(controller.state.phase, LibraryPhase.ready);
      expect(controller.state.failure, isNull);
      expect(controller.state.scenes, hasLength(1));
    });

    test(
      'ensureViewportFilled does not retry a failed page on its own',
      () async {
        api.pages.add(ScenePage(total: 120, scenes: scenes(48, start: 0)));
        await controller.loadInitial();

        api.pageFailures.add(const TransportFailure());
        await controller.ensureViewportFilled(
          contentExtent: 100,
          viewportExtent: 900,
        );
        expect(controller.state.phase, LibraryPhase.failed);
        expect(api.calls, hasLength(2));

        // A widget re-measuring after the failed page's `notifyListeners`
        // and calling this again (the exact shape of Task 7's post-frame
        // fill callback) must not re-fire the same failing request in an
        // unbounded loop — only an explicit `retry()` should.
        await controller.ensureViewportFilled(
          contentExtent: 100,
          viewportExtent: 900,
        );
        await controller.ensureViewportFilled(
          contentExtent: 100,
          viewportExtent: 900,
        );

        expect(api.calls, hasLength(2));
        expect(controller.state.phase, LibraryPhase.failed);
      },
    );
  });

  group('disposal', () {
    test(
      'a response landing after dispose is discarded rather than throwing',
      () async {
        api.allowManualCompletion = true;
        final future = controller.loadInitial(); // page 1 left pending
        controller.dispose();

        api.calls.single.completer.complete(
          ScenePage(total: 1, scenes: scenes(1)),
        );

        // Must complete without throwing — `ChangeNotifier.notifyListeners`
        // asserts (and throws) when called on a disposed notifier, and
        // the generation guard alone can't catch this: the disposed
        // controller's own `state.generation` never changes, so a
        // same-generation late response still looks current to it.
        await future;
      },
    );

    test(
      'an error landing after dispose is discarded rather than throwing',
      () async {
        api.allowManualCompletion = true;
        final future = controller.loadInitial();
        controller.dispose();

        api.calls.single.completer.completeError(const TransportFailure());

        await future;
      },
    );

    test('a filter-changing call reaching _resetAndFetch after dispose does '
        'not throw (final review §3b: library_controller.dart:188 — the '
        "widget-level guard in LibraryToolbar's own debounce timer already "
        "intercepts this in practice, so it needs its own direct test here "
        'rather than relying on a widget test to reach it)', () async {
      controller.dispose();

      // `setQuery` (like every other `set*` method) routes through
      // `_resetAndFetch`, which calls `notifyListeners()` —
      // `ChangeNotifier.notifyListeners` asserts (and throws) when
      // called on an already-disposed notifier, so this must complete
      // without throwing.
      await controller.setQuery('anything');
    });
  });

  group('races', () {
    test(
      'a stale response from a superseded generation is discarded',
      () async {
        api.allowManualCompletion = true;
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
        api.allowManualCompletion = true;
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

    test(
      'playRandom hands back a context over its own seeded filter',
      () async {
        api.pages.add(
          ScenePage(
            total: 42,
            scenes: [Scene(id: '1001', paths: const ScenePaths())],
          ),
        );

        final result = await controller.playRandom();

        final found = result as RandomSceneFound;
        expect(found.browse.index, 0);
        expect(found.browse.total, 42);
        // The seeded random filter the fetch actually used, not the
        // library's own filter: next has to walk the same shuffle the user
        // landed in.
        expect(found.browse.filter, api.requestedFilters.single);
        expect(found.browse.filter.sort, SceneSort.random);
        expect(found.browse.filter.randomSeed, isNotNull);
      },
    );
  });

  group('libraryControllerProvider', () {
    ProviderContainer buildContainer({
      ConnectionConfig saved = const ConnectionConfig(
        serverUrl: 'https://stash.test',
        apiKey: 'key',
      ),
      Future<ConnectionConfig>? loadFuture,
      StashApi Function(ConnectionConfig config)? apiFactory,
    }) {
      final container = ProviderContainer(
        overrides: [
          connectionStoreProvider.overrideWithValue(
            FakeConnectionStore(saved: saved, loadFuture: loadFuture),
          ),
          environmentProvider.overrideWithValue(const {}),
          stashApiFactoryProvider.overrideWithValue(
            apiFactory ?? (config) => FakeStashApi(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the provided controller resolves findScenes through the deferred '
        'stashApiProvider', () async {
      final fakeApi = FakeStashApi();
      fakeApi.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      final container = buildContainer(apiFactory: (config) => fakeApi);

      final notifier = container.read(libraryControllerProvider.notifier);
      await notifier.loadInitial();

      expect(notifier.state.phase, LibraryPhase.ready);
      expect(notifier.state.scenes, hasLength(1));
      expect(fakeApi.requestedPages, [1]);
    });

    test('bumping connectionGenerationProvider yields a fresh controller with '
        'reset state, discarding the old one', () async {
      final firstApi = FakeStashApi();
      firstApi.pages.add(ScenePage(total: 1, scenes: scenes(1)));
      final container = buildContainer(apiFactory: (config) => firstApi);

      final firstController = container.read(
        libraryControllerProvider.notifier,
      );
      await firstController.loadInitial();
      expect(firstController.state.scenes, hasLength(1));

      container.read(connectionGenerationProvider.notifier).state++;

      final secondController = container.read(
        libraryControllerProvider.notifier,
      );

      expect(identical(firstController, secondController), isFalse);
      expect(secondController.state.phase, LibraryPhase.initial);
      expect(secondController.state.scenes, isEmpty);
      expect(secondController.state.generation, 0);
    });

    test('a raw (non-Failure) error resolving the connection lands the '
        'provided controller in failed rather than stuck loading', () async {
      // Reproduces the real reachable path: `_DeferredStashApi` awaits
      // `stashApiProvider`, which awaits `effectiveConnectionProvider`,
      // which reads the connection store — and a store read can throw
      // a bare platform exception (e.g. secure storage/keyring
      // access), never a `Failure`, before `HttpStashApi` ever runs.
      final container = buildContainer(
        loadFuture: Future<ConnectionConfig>.error(
          Exception('secret service locked'),
        ),
      );

      final notifier = container.read(libraryControllerProvider.notifier);
      await notifier.loadInitial();

      expect(notifier.state.phase, LibraryPhase.failed);
      expect(notifier.state.failure, isNotNull);
      expect(notifier.state.isLoading, isFalse);
    });
  });
}
