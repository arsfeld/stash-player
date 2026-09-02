import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/failure.dart';
import '../../domain/scene.dart';
import '../../domain/scene_filter.dart';
import '../../services/stash_api.dart';
import 'library_state.dart';

/// Scenes fetched per page. Matches the GTK client's library page size —
/// see that app's `pages/library.rs`.
const int libraryPageSize = 48;

typedef LibrarySeedGenerator = int Function();

/// Owns the library grid's filter/paging/random-play state.
///
/// Every filter-changing intent (`set*` below) starts a fresh
/// [LibraryState] at the next generation and re-fetches page 1; every
/// paging fetch captures the generation it was issued under and discards
/// its response if a newer filter change has since superseded it (see
/// [_fetchNextPage]). Accepted pages are merged by scene id — appending
/// pages can otherwise duplicate ids when the underlying result set
/// shifts between requests.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required StashApi api,
    required LibrarySeedGenerator seedGenerator,
  }) : _api = api,
       _seedGenerator = seedGenerator;

  final StashApi _api;
  final LibrarySeedGenerator _seedGenerator;

  LibraryState _state = const LibraryState();
  LibraryState get state => _state;

  /// Set by [dispose]. [ChangeNotifierProvider] disposes the notifier it
  /// built as soon as a watched dependency (here,
  /// [connectionGenerationProvider]) changes and it rebuilds — which can
  /// happen while a page request from the *old* controller is still in
  /// flight. The generation guard alone doesn't catch that case (a
  /// disposed controller's own `state.generation` is frozen, so a
  /// same-generation late response still looks "current" to it); this
  /// flag is checked alongside it so a response landing after disposal
  /// is discarded instead of calling `notifyListeners()` on a disposed
  /// `ChangeNotifier`, which throws.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Kicks off the very first page load for the default filter. A no-op
  /// once a load has already started or finished — call [retry] instead
  /// to recover from a failure, or one of the `set*` intents to change
  /// the filter.
  Future<void> loadInitial() async {
    if (_state.phase != LibraryPhase.initial) return;
    await _resetAndFetch(_state.filter, bumpGeneration: false);
  }

  Future<void> setQuery(String query) => _resetAndFetch(
    _state.filter.copyWith(query: query),
    bumpGeneration: true,
  );

  Future<void> setSort(SceneSort sort) =>
      _resetAndFetch(_state.filter.copyWith(sort: sort), bumpGeneration: true);

  Future<void> setDirection(SortDirection direction) => _resetAndFetch(
    _state.filter.copyWith(direction: direction),
    bumpGeneration: true,
  );

  Future<void> setMinimumRating(int? minimumRating) => _resetAndFetch(
    minimumRating == null
        ? _state.filter.copyWith(clearMinimumRating: true)
        : _state.filter.copyWith(minimumRating: minimumRating),
    bumpGeneration: true,
  );

  Future<void> setOrganized(bool? organized) => _resetAndFetch(
    organized == null
        ? _state.filter.copyWith(clearOrganized: true)
        : _state.filter.copyWith(organized: organized),
    bumpGeneration: true,
  );

  Future<void> setHideTracked(bool hideTracked) => _resetAndFetch(
    _state.filter.copyWith(hideTracked: hideTracked),
    bumpGeneration: true,
  );

  /// Resets query, minimum rating, organized, and hide-tracked to a
  /// neutral "show everything" state in a single request.
  ///
  /// Deliberately not four chained `set*` calls: each is its own full
  /// `_resetAndFetch` (bump generation, reset state, fetch page 1), so
  /// chaining them would issue four page-1 requests and discard three —
  /// blanking the grid to empty between each — for one logical intent.
  /// Building one `SceneFilter` with every `clear*` flag set keeps this
  /// to exactly one round trip. Sort and direction are left untouched —
  /// they don't affect whether any scenes match, only their order.
  Future<void> clearFilters() => _resetAndFetch(
    _state.filter.copyWith(
      query: '',
      clearMinimumRating: true,
      clearOrganized: true,
      hideTracked: false,
    ),
    bumpGeneration: true,
  );

  /// Re-requests the page that just failed, keeping whatever scenes were
  /// already accepted before the failure.
  Future<void> retry() async {
    if (_state.phase != LibraryPhase.failed) return;
    await _fetchNextPage();
  }

  /// Loads one more page if the currently accepted content doesn't fill
  /// the viewport, more results remain, and nothing is already in
  /// flight.
  ///
  /// This deliberately fetches at most one page per call rather than
  /// looping until the viewport is satisfied: a single page may not fill
  /// a large window, and the caller (the library grid) is expected to
  /// re-measure its actual extent and call this again after each
  /// accepted page. Relying on an edge-reached-style trigger alone
  /// stalls forever when the first page never overflows the viewport in
  /// the first place — this is what lets the grid keep asking until
  /// either condition below stops being true.
  ///
  /// Also stops once a page has failed ([LibraryPhase.failed]) rather
  /// than auto-retrying: `hasMore` is left untouched by a failure (the
  /// page that failed hasn't been ruled out, so paging should resume
  /// from it once whatever's wrong is fixed), so without this check a
  /// widget that re-measures and calls this again after every rebuild
  /// would re-fire the same failing request in a tight, unbounded loop.
  /// [retry] is the explicit, user-driven way back out of `failed`.
  Future<void> ensureViewportFilled({
    required double contentExtent,
    required double viewportExtent,
  }) async {
    if (_state.isLoading) return;
    if (_state.phase == LibraryPhase.failed) return;
    if (!_state.hasMore) return;
    if (contentExtent > viewportExtent) return;
    await _fetchNextPage();
  }

  /// Picks one random scene honoring the active filters, independent of
  /// the browsed grid's own paging state — this does not touch [state].
  /// Returns [RandomSceneEmpty] rather than a bare null so a caller can't
  /// mistake "no scene matched" for "not resolved yet".
  Future<RandomSceneSelection> playRandom() async {
    final filter = _state.filter.copyWith(
      sort: SceneSort.random,
      randomSeed: _nextSeed(),
    );
    final result = await _api.findScenes(filter, page: 1, perPage: 1);
    if (result.scenes.isEmpty) return const RandomSceneSelection.empty();
    return RandomSceneSelection.found(result.scenes.first);
  }

  Future<void> _resetAndFetch(
    SceneFilter filter, {
    required bool bumpGeneration,
  }) async {
    final prepared = _prepareRandomSeed(filter);
    final generation = bumpGeneration
        ? _state.generation + 1
        : _state.generation;
    _state = LibraryState(filter: prepared, generation: generation);
    // Guards `notifyListeners()` exactly like `_fetchNextPage`'s own
    // post-await calls do (see that method's stale-response comment) —
    // a caller can reach this after `dispose()` when e.g. a widget's
    // debounced search callback still holds a tear-off of a `set*`
    // method bound to a controller a connection-generation bump has
    // since disposed. `ChangeNotifier.notifyListeners` asserts (and
    // throws) when called on a disposed notifier.
    if (_disposed) return;
    notifyListeners();
    await _fetchNextPage();
  }

  Future<void> _fetchNextPage() async {
    if (_state.isLoading) return;
    if (!_state.hasMore) return;

    final generation = _state.generation;
    final requestedPage = _state.page + 1;
    final filter = _state.filter;

    _state = _state.copyWith(phase: LibraryPhase.loading);
    notifyListeners();

    try {
      final result = await _api.findScenes(
        filter,
        page: requestedPage,
        perPage: libraryPageSize,
      );
      // A newer filter change superseded this request while it was in
      // flight — discard the response rather than let it clobber
      // whatever that newer generation has already accepted. Also bail
      // if `dispose()` landed while this was in flight (see its doc
      // comment) — `notifyListeners()` on a disposed notifier throws.
      if (_disposed || generation != _state.generation) return;

      final merged = _dedupeAppend(_state.scenes, result.scenes);
      final shortPage = result.scenes.length < libraryPageSize;
      final reachedTotal = merged.length >= result.total;
      _state = _state.copyWith(
        scenes: merged,
        page: requestedPage,
        total: result.total,
        hasMore: !shortPage && !reachedTotal,
        phase: merged.isEmpty ? LibraryPhase.empty : LibraryPhase.ready,
        clearFailure: true,
      );
      notifyListeners();
    } on Failure catch (failure) {
      if (_disposed || generation != _state.generation) return; // stale
      _state = _state.copyWith(phase: LibraryPhase.failed, failure: failure);
      notifyListeners();
    } catch (_) {
      // `_api.findScenes` (by way of `StashApi`) always normalizes to a
      // `Failure`, but the deferred adapter `libraryControllerProvider`
      // wires up (`_DeferredStashApi`) resolves `stashApiProvider`
      // *before* reaching that code — and that chain can throw a bare
      // platform exception (e.g. secure storage/keyring access denied),
      // which isn't a `Failure`. Without this fallback that escapes both
      // catch clauses above, leaving `phase == loading` permanently:
      // `_fetchNextPage` itself refuses to run again while loading,
      // `ensureViewportFilled` blocks on the same check, and `retry`
      // requires `phase == failed`, which would then be unreachable.
      if (_disposed || generation != _state.generation) return; // stale
      _state = _state.copyWith(
        phase: LibraryPhase.failed,
        failure: const TransportFailure(),
      );
      notifyListeners();
    }
  }

  /// Clears the seed when the filter no longer sorts randomly, and mints
  /// one when it newly does (a fresh shuffle for this generation) —
  /// paging within a generation reuses whatever seed the filter already
  /// carries by never calling this again until the next reset, which is
  /// what keeps a random-sorted page 2 consistent with page 1 instead of
  /// reshuffling under the reader.
  SceneFilter _prepareRandomSeed(SceneFilter filter) {
    if (filter.sort != SceneSort.random) {
      return filter.randomSeed == null
          ? filter
          : filter.copyWith(clearRandomSeed: true);
    }
    return filter.randomSeed == null
        ? filter.copyWith(randomSeed: _nextSeed())
        : filter;
  }

  int _nextSeed() => _seedGenerator() & 0x7fffffff;

  List<Scene> _dedupeAppend(List<Scene> existing, List<Scene> incoming) {
    final seen = existing.map((scene) => scene.id).toSet();
    final merged = <Scene>[...existing];
    for (final scene in incoming) {
      if (seen.add(scene.id)) merged.add(scene);
    }
    return List.unmodifiable(merged);
  }
}

/// Forwards every [StashApi] call to whatever [stashApiProvider] resolves
/// to, resolving it lazily on each call rather than requiring one
/// synchronously at construction time.
///
/// [stashApiProvider] is a `FutureProvider`, but [libraryControllerProvider]
/// below is a `ChangeNotifierProvider` and must hand back a
/// [LibraryController] synchronously — so [LibraryController] is always
/// constructed with a [StashApi] it can call immediately, and this
/// adapter is what makes that true even before the real one has resolved.
class _DeferredStashApi implements StashApi {
  _DeferredStashApi(this._ref);

  final Ref _ref;

  Future<StashApi> get _resolved => _ref.read(stashApiProvider.future);

  @override
  Future<String> version() async => (await _resolved).version();

  @override
  Future<Scene?> findScene(String id) async => (await _resolved).findScene(id);

  @override
  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  }) async =>
      (await _resolved).findScenes(filter, page: page, perPage: perPage);

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) async => (await _resolved).saveSceneActivity(
    id: id,
    resumeTime: resumeTime,
    playDuration: playDuration,
  );

  @override
  Future<int> incrementO(String id) async => (await _resolved).incrementO(id);

  @override
  Future<int> resetO(String id) async => (await _resolved).resetO(id);
}

/// The library's controller. Rebuilt from scratch — a fresh
/// [LibraryController] with fresh [LibraryState] — whenever
/// [connectionGenerationProvider] changes, which discards any in-flight
/// request or accepted scene from the old connection outright rather
/// than trying to reconcile old data against what may no longer be the
/// same Stash server, the same way [stashApiProvider] itself is rebuilt.
final libraryControllerProvider = ChangeNotifierProvider<LibraryController>((
  ref,
) {
  ref.watch(connectionGenerationProvider);
  return LibraryController(
    api: _DeferredStashApi(ref),
    seedGenerator: () => Random().nextInt(1 << 32),
  );
});
