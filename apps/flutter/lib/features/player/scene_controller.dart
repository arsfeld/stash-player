import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/browse_context.dart';
import '../../domain/failure.dart';
import '../../domain/scene.dart';
import '../../domain/scene_filter.dart';
import 'playback_controller.dart';

/// Resolves one [Scene] by id, or `null` if Stash has nothing under that
/// id — matches `StashApi.findScene`'s own contract. Narrower than the
/// full `StashApi` interface: [SceneController] only ever needs this one
/// call, the same reasoning `ConnectionResolver`/`FullscreenRequester` in
/// `playback_controller.dart` already use for their own single-method
/// dependencies.
typedef FindScene = Future<Scene?> Function(String id);

/// Which O-counter mutation to run. One parameter rather than two
/// separate function dependencies, so the controller's guard code cannot
/// apply to one and miss the other.
enum OMutation { increment, reset }

/// The paged scene lookup prev/next needs, narrowed from the full
/// `StashApi` exactly as [FindScene] is.
typedef FindScenesPage =
    Future<ScenePage> Function(
      SceneFilter filter, {
      required int page,
      required int perPage,
    });

/// Runs one O-counter mutation and returns the server's new count.
typedef MutateOCounter = Future<int> Function(String id, OMutation mutation);

/// Where a [SceneState] sits in its metadata-load lifecycle. Deliberately
/// separate from `PlaybackController`'s own `PlaybackPhase`: this only
/// ever reflects whether *scene metadata* (title, performers, files, ...)
/// is available — video playback has its own independent phase, read
/// straight off `playbackControllerProvider`. A scene whose metadata
/// loaded fine but whose video failed to open is `ScenePhase.ready` here
/// while simultaneously `PlaybackPhase.failed` on the playback side —
/// `SceneScreen` renders both together but never conflates them.
enum ScenePhase { initial, loading, ready, notFound, failed }

/// Immutable snapshot of [SceneController]: which [sceneId] was last
/// requested (kept even on failure/notFound so [SceneController.retry]
/// knows what to repeat, and so "Open in Stash" has an id to build a URL
/// from even before/without a loaded [scene]), the loaded [scene] once
/// [phase] reaches [ScenePhase.ready], and any [failure].
///
/// [generation] is bumped by every [SceneController.load] call and
/// captured by that call before its first `await` — see that method's
/// own doc for why, mirroring the exact discipline `LibraryController`
/// and `PlaybackController` already use for their own paging/scene
/// requests.
class SceneState {
  const SceneState({
    this.phase = ScenePhase.initial,
    this.sceneId,
    this.scene,
    this.failure,
    this.generation = 0,
    this.browse,
    this.navigating = false,
    this.oCount,
    this.oFailureSequence = 0,
    this.browseFailureSequence = 0,
  });

  final ScenePhase phase;
  final String? sceneId;
  final Scene? scene;
  final Failure? failure;
  final int generation;

  /// Where this scene sits in the ordering the user was browsing, if
  /// any. Advanced by [SceneController.goPrevious]/[SceneController.goNext].
  final BrowseContext? browse;

  /// True from the moment a prev/next fetch starts until its scene
  /// lands. [scene] deliberately keeps holding the *outgoing* scene for
  /// that whole window, which is what keeps the video surface mapped
  /// rather than remounting mid-browse, so anything acting on the
  /// current scene has to check this too or it acts on the one the user
  /// just left.
  final bool navigating;

  /// The live O counter: seeded from `Scene.oCounter` on load, then
  /// replaced by whatever the server returns from a mutation. `null`
  /// means no scene is loaded, or one is mid-navigation, and the
  /// player's O-counter controls are dead. Distinct from `0`, which
  /// means a loaded scene nobody has counted yet.
  final int? oCount;

  /// Bumped every time an O-counter mutation fails. A counter rather
  /// than a flag or a message: two consecutive failures with the same
  /// cause have to be two observable events, or the second is silently
  /// swallowed. The same technique `PlaybackState.controlFailureSequence`
  /// already uses, for the same reason.
  final int oFailureSequence;

  /// Bumped every time a prev/next step finds nothing to move to.
  final int browseFailureSequence;

  SceneState copyWith({
    ScenePhase? phase,
    String? sceneId,
    Scene? scene,
    Failure? failure,
    int? generation,
    bool clearFailure = false,
    BrowseContext? browse,
    bool? navigating,
    int? oCount,
    bool clearOCount = false,
    int? oFailureSequence,
    int? browseFailureSequence,
  }) => SceneState(
    phase: phase ?? this.phase,
    sceneId: sceneId ?? this.sceneId,
    scene: scene ?? this.scene,
    failure: clearFailure ? null : (failure ?? this.failure),
    generation: generation ?? this.generation,
    browse: browse ?? this.browse,
    navigating: navigating ?? this.navigating,
    oCount: clearOCount ? null : (oCount ?? this.oCount),
    oFailureSequence: oFailureSequence ?? this.oFailureSequence,
    browseFailureSequence: browseFailureSequence ?? this.browseFailureSequence,
  );
}

/// Owns fetching one scene's metadata (via [FindScene]) for the scene
/// screen, and handing it off to the shared [PlaybackController] once
/// accepted.
///
/// ## Generation guard
///
/// [load] claims the next generation *synchronously*, before its first
/// `await` — including before the `findScene` call itself — exactly the
/// discipline `LibraryController._fetchNextPage` and
/// `PlaybackController.loadScene` already use: two `load` calls issued
/// back-to-back (before either reaches its own first suspension point)
/// would otherwise both compute the same "next generation" against the
/// same stale `_state.generation`, defeating the guard (both earlier
/// tasks shipped exactly this bug before a review caught it). Every
/// `await` inside [load] re-checks `_disposed` and the captured
/// generation afterward, on both the success and failure paths, so a
/// response for a scene the user has since navigated away from can never
/// clobber whatever superseded it.
///
/// ## Disposal
///
/// [dispose] marks this controller disposed (so any in-flight [load] can
/// no longer apply its result) and calls the injected [releasePlayback]
/// hook. `sceneControllerProvider`'s own wiring makes that hook invalidate
/// both `playbackControllerProvider` and `playbackEngineProvider` — that
/// invalidation is what actually disposes the shared [PlaybackController]
/// (and, through it, the shared `PlaybackEngine`): Riverpod's
/// `ChangeNotifierProvider` invokes the outgoing notifier's own
/// `dispose()` as part of tearing down an invalidated provider, exactly
/// the way a `connectionGenerationProvider` bump already disposes the old
/// `PlaybackController`/engine pair today (see that provider's own doc
/// comment for the full mechanics). Without this, leaving the scene
/// screen would hold the engine alive — and playing — in the background
/// (the exact failure mode the GTK client's own `AppModel` guards against
/// by dropping its `ScenePage` controller on `connect_popped`), *and* the
/// next scene visit would silently hand the new `PlaybackController` an
/// already-disposed engine, permanently stuck in `PlaybackPhase.failed`
/// (see `playbackEngineProvider`'s own doc for that exact regression).
class SceneController extends ChangeNotifier {
  SceneController({
    required FindScene findScene,
    required FindScenesPage findScenes,
    required MutateOCounter mutateO,
    required PlaybackController playback,
    required VoidCallback releasePlayback,
  }) : _findScene = findScene,
       _findScenes = findScenes,
       _mutateO = mutateO,
       _playback = playback,
       _releasePlayback = releasePlayback;

  final FindScene _findScene;
  final FindScenesPage _findScenes;
  final MutateOCounter _mutateO;
  final PlaybackController _playback;
  final VoidCallback _releasePlayback;

  SceneState _state = const SceneState();
  SceneState get state => _state;

  bool _disposed = false;

  /// Fetches [id]'s metadata. On success, hands the scene to the shared
  /// [PlaybackController] (fire-and-forget: playback has its own phase
  /// and failure surface, independent of this controller's own
  /// [SceneState] — see that class's doc). A `null` result maps to
  /// [NotFoundFailure], matching `StashApi.findScene`'s own documented
  /// contract.
  ///
  /// [browse] is where the caller says this scene sits in an ordering,
  /// if any. `null` keeps whatever ordering was already in place
  /// (unchanged by a bare [retry], for instance). Seeds [SceneState.oCount]
  /// from [Scene.oCounter] on success, defaulting an unreported count to
  /// zero so the player's O-counter controls always have something
  /// actionable to show.
  Future<void> load(String id, {BrowseContext? browse}) async {
    if (_disposed) return;
    // Claimed synchronously, before any `await` below — see class doc.
    final generation = _state.generation + 1;
    _state = SceneState(
      phase: ScenePhase.loading,
      sceneId: id,
      generation: generation,
      // A step (`_step`) sets `navigating` true and calls this method
      // while it is still true, precisely so the outgoing scene keeps
      // the video surface mapped for the whole fetch. See
      // [SceneState.navigating]'s own doc. Carrying [Scene] forward here
      // only in that case is what makes that true: a step's nested
      // `load` must never let `scene` go null (that is what un-maps the
      // video surface), while a fresh `load`/[retry] genuinely should
      // drop whatever scene came before.
      scene: _state.navigating ? _state.scene : null,
      browse: browse ?? _state.browse,
      navigating: _state.navigating,
      oFailureSequence: _state.oFailureSequence,
      browseFailureSequence: _state.browseFailureSequence,
    );
    notifyListeners();

    try {
      final scene = await _findScene(id);
      if (_disposed || generation != _state.generation) return;

      if (scene == null) {
        _state = _state.copyWith(
          phase: ScenePhase.notFound,
          failure: const NotFoundFailure(),
          navigating: false,
        );
        notifyListeners();
        return;
      }

      _state = _state.copyWith(
        phase: ScenePhase.ready,
        scene: scene,
        oCount: scene.oCounter ?? 0,
        navigating: false,
        clearFailure: true,
      );
      notifyListeners();
      unawaited(_playback.loadScene(scene));
    } on Failure catch (failure) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: ScenePhase.failed,
        failure: failure,
        navigating: false,
      );
      notifyListeners();
    } catch (_) {
      // Mirrors `LibraryController._fetchNextPage`'s own fallback: the
      // deferred `FindScene` this controller is built with can throw a
      // bare, non-`Failure` platform exception (e.g. secure storage
      // access denied) before `HttpStashApi` ever gets a chance to
      // normalize it.
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(
        phase: ScenePhase.failed,
        failure: const TransportFailure(),
        navigating: false,
      );
      notifyListeners();
    }
  }

  /// Re-requests the scene that just failed (or came back not-found),
  /// using the same id. A no-op otherwise — call [load] directly to open
  /// a different scene.
  Future<void> retry() async {
    final id = _state.sceneId;
    if (id == null) return;
    if (_state.phase != ScenePhase.failed &&
        _state.phase != ScenePhase.notFound) {
      return;
    }
    await load(id);
  }

  /// Steps to the scene before this one in the browsed ordering.
  Future<void> goPrevious() => _step(-1);

  /// Steps to the scene after this one in the browsed ordering.
  Future<void> goNext() => _step(1);

  /// Fetches the scene [offset] positions away and loads it.
  ///
  /// Reads exactly one scene at the target position rather than paging
  /// through: Stash's pages are 1-indexed, so `perPage: 1` makes page
  /// number and index interchangeable, and the fetch stays correct
  /// however far past the library's loaded pages the user has browsed.
  ///
  /// Refuses while [SceneState.navigating] is already true, which is
  /// what stops a held-down next button issuing a fetch per frame, each
  /// stepping from the same stale index.
  Future<void> _step(int offset) async {
    if (_disposed || _state.navigating) return;
    final browse = _state.browse;
    if (browse == null) return;
    if (offset < 0 && !browse.canGoPrevious) return;
    if (offset > 0 && !browse.canGoNext) return;

    final targetIndex = browse.index + offset;
    // Snapshotted before anything about the outgoing scene changes, so
    // abandoning the step puts back exactly what was on screen: not just
    // the O count, but the scene, its id, its phase, and its position in
    // the ordering. `load`'s own top-of-function reset only keeps `scene`
    // (not `sceneId`/`browse`/`phase`) while a step is in flight, so a
    // step whose nested `load` lands on `notFound`/`failed` would
    // otherwise leave `sceneId` pointing at the bad target while `scene`
    // still held the old one: an incoherent mix no phase/id pairing
    // anywhere else in this controller produces. Restoring `oCount` from
    // this snapshot rather than re-reading `scene.oCounter` matters for
    // the same reason it already did before this fix: it must not undo a
    // bump made since the scene loaded.
    final restorePhase = _state.phase;
    final restoreSceneId = _state.sceneId;
    final restoreScene = _state.scene;
    final restoreFailure = _state.failure;
    final restoreCount = _state.oCount ?? _state.scene?.oCounter ?? 0;
    // Claimed synchronously, before the first await, exactly as `load`
    // does. Two presses issued back to back would otherwise compute the
    // same next generation against the same stale value.
    final generation = _state.generation + 1;
    _state = _state.copyWith(
      generation: generation,
      navigating: true,
      clearOCount: true,
    );
    notifyListeners();

    void abandon() => _abandonStep(
      browse: browse,
      phase: restorePhase,
      sceneId: restoreSceneId,
      scene: restoreScene,
      failure: restoreFailure,
      oCount: restoreCount,
    );

    try {
      final page = await _findScenes(
        browse.filter,
        page: targetIndex + 1,
        perPage: 1,
      );
      if (_disposed || generation != _state.generation) return;

      if (page.scenes.isEmpty) {
        abandon();
        return;
      }

      await load(page.scenes.first.id, browse: browse.at(targetIndex));
      // `load` bumps `_state.generation` again as part of its own guard
      // discipline, so the check here is against `generation + 1`, not
      // `generation`: that is the value this step's own nested `load`
      // call set, if and only if nothing else superseded it while it was
      // in flight. If something else did (a fresh `load`/`_step` issued
      // from outside this one), `_state.generation` will be higher than
      // that, and this step must leave state alone, exactly like every
      // other generation check in this class.
      if (_disposed || _state.generation != generation + 1) return;
      // `load` never throws (it catches its own failures), so a step
      // whose target scene came back notFound/failed reaches here rather
      // than the `catch` below. The controller must still end up either
      // fully on the new scene or exactly back on the outgoing one, so a
      // step that didn't land on `ScenePhase.ready` reverts too.
      if (_state.phase != ScenePhase.ready) abandon();
    } catch (_) {
      if (_disposed || generation != _state.generation) return;
      abandon();
    }
  }

  /// Puts the controller back where it was before a step that could not
  /// complete: the outgoing scene (with its own id, phase, and position
  /// in the ordering) stays exactly as it was, the count it was showing
  /// comes back, and the screen is told so it can say something.
  void _abandonStep({
    required BrowseContext browse,
    required ScenePhase phase,
    required String? sceneId,
    required Scene? scene,
    required Failure? failure,
    required int oCount,
  }) {
    _state = _state.copyWith(
      phase: phase,
      sceneId: sceneId,
      scene: scene,
      browse: browse,
      failure: failure,
      clearFailure: failure == null,
      navigating: false,
      oCount: oCount,
      browseFailureSequence: _state.browseFailureSequence + 1,
    );
    notifyListeners();
  }

  /// Bumps the current scene's O counter.
  Future<void> bumpO() => _runOMutation(OMutation.increment);

  /// Resets the current scene's O counter to zero.
  Future<void> clearO() => _runOMutation(OMutation.reset);

  /// Runs [mutation] against the scene that is actually on screen and
  /// stable.
  ///
  /// The displayed count is replaced by the server's answer rather than
  /// adjusted locally first. Both mutations return the authoritative new
  /// value, so an optimistic bump could only ever show a wrong number
  /// that has to be corrected a moment later. A failure therefore leaves
  /// the old count showing, which stays the truth until the server says
  /// otherwise.
  Future<void> _runOMutation(OMutation mutation) async {
    if (_disposed || _state.navigating) return;
    final scene = _state.scene;
    if (scene == null || _state.phase != ScenePhase.ready) return;

    final generation = _state.generation;
    try {
      final count = await _mutateO(scene.id, mutation);
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(oCount: count);
      notifyListeners();
    } catch (_) {
      // Surfaced by the screen, which watches this controller and owns
      // the notice channel. Nothing to roll back: the count never moved.
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(oFailureSequence: _state.oFailureSequence + 1);
      notifyListeners();
    }
  }

  /// Tears this controller down: rejects any [load] response still in
  /// flight (via the generation/disposed guard) and releases the shared
  /// playback stack via [_releasePlayback] — see class doc. Safe to call
  /// more than once.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releasePlayback();
    super.dispose();
  }
}

/// Deferred [FindScene] resolving `stashApiProvider` lazily on each call —
/// `sceneControllerProvider` is a `ChangeNotifierProvider` and must hand
/// back a [SceneController] synchronously, before the async
/// `stashApiProvider` has necessarily resolved. Mirrors
/// `LibraryController`'s own `_DeferredStashApi` adapter, narrowed to the
/// one call [SceneController] needs.
FindScene _deferredFindScene(Ref ref) =>
    (id) async => (await ref.read(stashApiProvider.future)).findScene(id);

/// Deferred [FindScenesPage], mirroring [_deferredFindScene] for the
/// paged lookup [SceneController]'s prev/next steps need.
FindScenesPage _deferredFindScenes(Ref ref) =>
    (filter, {required page, required perPage}) async => (await ref.read(
      stashApiProvider.future,
    )).findScenes(filter, page: page, perPage: perPage);

/// Deferred [MutateOCounter], mirroring [_deferredFindScene] for the two
/// O-counter mutations [SceneController] runs.
MutateOCounter _deferredMutateO(Ref ref) => (id, mutation) async {
  final api = await ref.read(stashApiProvider.future);
  return switch (mutation) {
    OMutation.increment => api.incrementO(id),
    OMutation.reset => api.resetO(id),
  };
};

/// [SceneController] provider. `.autoDispose` — unlike
/// `libraryControllerProvider`/`playbackControllerProvider`, which are
/// deliberately long-lived app singletons only rebuilt on a
/// [connectionGenerationProvider] bump, [SceneController] only makes sense
/// for as long as *some* scene screen is actually mounted watching it.
/// Riverpod tears it down (calling [SceneController.dispose], which
/// releases the shared playback stack — see that method's own doc) the
/// moment the last watcher (`SceneScreen`'s own `ref.watch`) goes away,
/// i.e. when the scene route pops.
///
/// This has to be `.autoDispose` rather than `SceneScreen` calling
/// `ref.invalidate(sceneControllerProvider)` from its own `State.dispose()`
/// — Riverpod's `ConsumerStatefulElement` forbids using `ref` at all
/// once the element itself is unmounting (`invalidate` throws "Cannot use
/// 'ref' after the widget was disposed", caught empirically by this
/// task's own widget tests), so the widget has no legal hook to trigger
/// this teardown itself; auto-dispose is the only mechanism Riverpod
/// offers for "tear down when nothing needs this anymore" that doesn't
/// require the watcher to say so at exactly the moment it can no longer
/// safely talk to `ref`.
///
/// `playback` is read (not watched) once at construction: this provider's
/// own `connectionGenerationProvider` watch already forces a rebuild on
/// reconnect, at which point re-reading `playbackControllerProvider` here
/// naturally picks up the freshly-rebuilt controller — a `ref.watch` here
/// too would create a second, redundant reactive dependency on the exact
/// same trigger. `releasePlayback` is what `SceneController.dispose`
/// calls to invalidate both `playbackControllerProvider` and
/// `playbackEngineProvider` when the scene screen leaves — see
/// [SceneController]'s own doc for why both must be invalidated together.
/// Invalidating from *this* provider's own disposal callback (rather than
/// from the widget) is safe: it's a plain [Ref], not a
/// [ConsumerStatefulElement]'s, and calling `ref.invalidate` on a
/// *different* provider from inside a provider's own teardown is an
/// ordinary, supported Riverpod pattern.
final sceneControllerProvider =
    ChangeNotifierProvider.autoDispose<SceneController>((ref) {
      ref.watch(connectionGenerationProvider);
      return SceneController(
        findScene: _deferredFindScene(ref),
        findScenes: _deferredFindScenes(ref),
        mutateO: _deferredMutateO(ref),
        playback: ref.read(playbackControllerProvider),
        releasePlayback: () {
          ref.invalidate(playbackEngineProvider);
          ref.invalidate(playbackControllerProvider);
        },
      );
    });
