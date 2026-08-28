import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/failure.dart';
import '../../domain/scene.dart';
import 'playback_controller.dart';

/// Resolves one [Scene] by id, or `null` if Stash has nothing under that
/// id — matches `StashApi.findScene`'s own contract. Narrower than the
/// full `StashApi` interface: [SceneController] only ever needs this one
/// call, the same reasoning `ConnectionResolver`/`FullscreenRequester` in
/// `playback_controller.dart` already use for their own single-method
/// dependencies.
typedef FindScene = Future<Scene?> Function(String id);

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
  });

  final ScenePhase phase;
  final String? sceneId;
  final Scene? scene;
  final Failure? failure;
  final int generation;

  SceneState copyWith({
    ScenePhase? phase,
    String? sceneId,
    Scene? scene,
    Failure? failure,
    int? generation,
    bool clearFailure = false,
  }) => SceneState(
    phase: phase ?? this.phase,
    sceneId: sceneId ?? this.sceneId,
    scene: scene ?? this.scene,
    failure: clearFailure ? null : (failure ?? this.failure),
    generation: generation ?? this.generation,
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
    required PlaybackController playback,
    required VoidCallback releasePlayback,
  }) : _findScene = findScene,
       _playback = playback,
       _releasePlayback = releasePlayback;

  final FindScene _findScene;
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
  Future<void> load(String id) async {
    if (_disposed) return;
    // Claimed synchronously, before any `await` below — see class doc.
    final generation = _state.generation + 1;
    _state = SceneState(
      phase: ScenePhase.loading,
      sceneId: id,
      generation: generation,
    );
    notifyListeners();

    try {
      final scene = await _findScene(id);
      if (_disposed || generation != _state.generation) return;

      if (scene == null) {
        _state = _state.copyWith(
          phase: ScenePhase.notFound,
          failure: const NotFoundFailure(),
        );
        notifyListeners();
        return;
      }

      _state = _state.copyWith(
        phase: ScenePhase.ready,
        scene: scene,
        clearFailure: true,
      );
      notifyListeners();
      unawaited(_playback.loadScene(scene));
    } on Failure catch (failure) {
      if (_disposed || generation != _state.generation) return;
      _state = _state.copyWith(phase: ScenePhase.failed, failure: failure);
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
        playback: ref.read(playbackControllerProvider),
        releasePlayback: () {
          ref.invalidate(playbackEngineProvider);
          ref.invalidate(playbackControllerProvider);
        },
      );
    });
