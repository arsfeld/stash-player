import '../../domain/browse_context.dart';
import '../../domain/failure.dart';
import '../../domain/scene.dart';
import '../../domain/scene_filter.dart';

/// Where a [LibraryState] sits in its load lifecycle.
///
/// `isLoading` on [LibraryState] is derived from this rather than tracked
/// as a second mutable flag, so the two can never disagree.
enum LibraryPhase { initial, loading, empty, ready, failed }

/// Immutable snapshot of the library grid: the active [filter], the
/// scenes accepted so far (deduped by id across pages), and where paging
/// currently stands.
///
/// [generation] is bumped by every filter-changing intent
/// ([LibraryController]'s `set*` methods) and captured by each in-flight
/// request; a response is only applied if its captured generation still
/// matches [generation] at the time it resolves, which is what lets a
/// filter change made while a request is in flight discard that request's
/// (now-stale) response instead of letting it clobber newer state.
class LibraryState {
  const LibraryState({
    this.filter = const SceneFilter(),
    this.scenes = const [],
    this.page = 0,
    this.total = 0,
    this.phase = LibraryPhase.initial,
    this.generation = 0,
    this.hasMore = true,
    this.failure,
  });

  final SceneFilter filter;
  final List<Scene> scenes;
  final int page;
  final int total;
  final LibraryPhase phase;
  final int generation;
  final bool hasMore;
  final Failure? failure;

  bool get isLoading => phase == LibraryPhase.loading;

  LibraryState copyWith({
    SceneFilter? filter,
    List<Scene>? scenes,
    int? page,
    int? total,
    LibraryPhase? phase,
    int? generation,
    bool? hasMore,
    Failure? failure,
    bool clearFailure = false,
  }) => LibraryState(
    filter: filter ?? this.filter,
    scenes: scenes ?? this.scenes,
    page: page ?? this.page,
    total: total ?? this.total,
    phase: phase ?? this.phase,
    generation: generation ?? this.generation,
    hasMore: hasMore ?? this.hasMore,
    failure: clearFailure ? null : failure ?? this.failure,
  );
}

/// Result of [LibraryController.playRandom]: either a scene to jump to,
/// or an explicit signal that the active filters matched nothing. Kept as
/// its own sealed type — rather than a bare nullable `Scene?` — so a
/// caller can't mistake "no scene matched" for "not resolved yet".
sealed class RandomSceneSelection {
  const RandomSceneSelection();

  const factory RandomSceneSelection.found(Scene scene, BrowseContext browse) =
      RandomSceneFound;
  const factory RandomSceneSelection.empty() = RandomSceneEmpty;
}

final class RandomSceneFound extends RandomSceneSelection {
  const RandomSceneFound(this.scene, this.browse);

  final Scene scene;

  /// The ordering the pick came from: its own seeded filter, at index 0.
  /// Prev/next from a random scene walk that same shuffle rather than
  /// jumping into the library's visible ordering.
  final BrowseContext browse;
}

final class RandomSceneEmpty extends RandomSceneSelection {
  const RandomSceneEmpty();
}
