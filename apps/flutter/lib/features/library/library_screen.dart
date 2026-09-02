import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../app/notices.dart';
import '../../app/providers.dart';
import '../../domain/browse_context.dart';
import '../../domain/failure.dart';
import '../../services/thumbnail_repository.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/status_views.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'library_toolbar.dart';
import 'scene_grid.dart';

/// The adaptive scene library: toolbar plus grid, driven entirely by
/// [libraryControllerProvider]'s [LibraryState].
///
/// Consumes [AppController.openScene] directly (via [ref] — a card tap or
/// a resolved "play random" both navigate the same way) since that
/// destination is owned by [AppController] itself. Settings has no such
/// owner — Task 4 made it a router-owned modal push — so [onOpenSettings]
/// is threaded in from the router instead of duplicated here.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({required this.onOpenSettings, super.key});

  final VoidCallback onOpenSettings;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    _scheduleLoadInitial();
  }

  // Unlike `ConnectionScreen`'s `load()`, `loadInitial` mutates state
  // (and calls `notifyListeners()`) *synchronously* before its first
  // `await` — calling it directly during a build/`initState` would modify
  // `libraryControllerProvider` while this very widget tree is still
  // building, which Riverpod forbids. Deferring to a post-frame callback
  // runs it once the current frame has actually landed.
  void _scheduleLoadInitial() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(libraryControllerProvider).loadInitial();
    });
  }

  /// Surfaces both `playRandom`'s explicit "nothing matched" outcome and
  /// any thrown failure as a dismissible [globalNoticeProvider] notice —
  /// `LibraryController.playRandom` has no try/catch of its own (it
  /// calls the API directly, not through `_fetchNextPage`'s error
  /// handling), and this was previously invoked as a fire-and-forget
  /// `VoidCallback` with nothing downstream to observe a thrown
  /// `Failure`: a server outage during "Play random" silently did
  /// nothing but leave an unhandled async error on stderr.
  Future<void> _handlePlayRandom(LibraryController controller) async {
    try {
      final result = await controller.playRandom();
      if (!mounted) return;
      switch (result) {
        case RandomSceneFound(:final scene, :final browse):
          ref
              .read(appControllerProvider.notifier)
              .openScene(scene.id, browse: browse);
        case RandomSceneEmpty():
          _showNotice('No scenes match these filters', AppNoticeSeverity.info);
      }
    } on Failure catch (failure) {
      if (!mounted) return;
      _showNotice(failure.userMessage, AppNoticeSeverity.error);
    } catch (_) {
      // Mirrors `LibraryController`'s own fallback for a bare,
      // non-`Failure` error surfacing through the deferred `StashApi`
      // adapter (e.g. secure storage access denied) — see that class's
      // doc comment on `_fetchNextPage`.
      if (!mounted) return;
      _showNotice('Could not play a random scene.', AppNoticeSeverity.error);
    }
  }

  void _showNotice(String message, AppNoticeSeverity severity) {
    ref
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: message, severity: severity));
  }

  @override
  Widget build(BuildContext context) {
    // `libraryControllerProvider` is rebuilt from scratch — a brand new
    // controller, reset to `LibraryPhase.initial` — whenever a settings
    // change bumps `connectionGenerationProvider` (see that provider's
    // own doc comment). This screen stays mounted across that swap (the
    // router keeps the library page in place), so `initState`'s one-time
    // kickoff never runs again on its own; without re-arming it here, a
    // reconnect would leave the fresh controller sitting in `initial`
    // forever with nothing to ever call `loadInitial` on it.
    ref.listen<int>(connectionGenerationProvider, (previous, next) {
      if (previous != next) _scheduleLoadInitial();
    });
    final controller = ref.watch(libraryControllerProvider);
    final state = controller.state;
    final thumbnailRepository = ref
        .watch(thumbnailRepositoryProvider)
        .valueOrNull;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibraryToolbar(
            filter: state.filter,
            onQueryChanged: controller.setQuery,
            onSortChanged: controller.setSort,
            onDirectionChanged: controller.setDirection,
            onMinimumRatingChanged: controller.setMinimumRating,
            onOrganizedChanged: controller.setOrganized,
            onHideTrackedChanged: controller.setHideTracked,
            onPlayRandom: () => _handlePlayRandom(controller),
            onOpenSettings: widget.onOpenSettings,
          ),
          Expanded(
            child: _LibraryBody(
              state: state,
              controller: controller,
              thumbnailRepository: thumbnailRepository,
              onClearFilters: controller.clearFilters,
              onOpenScene: (sceneId, index) => ref
                  .read(appControllerProvider.notifier)
                  .openScene(
                    sceneId,
                    browse: BrowseContext(
                      filter: state.filter,
                      index: index,
                      total: state.total,
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryBody extends StatelessWidget {
  const _LibraryBody({
    required this.state,
    required this.controller,
    required this.thumbnailRepository,
    required this.onClearFilters,
    required this.onOpenScene,
  });

  final LibraryState state;
  final LibraryController controller;
  final ThumbnailRepository? thumbnailRepository;
  final VoidCallback onClearFilters;
  final void Function(String sceneId, int index) onOpenScene;

  @override
  Widget build(BuildContext context) {
    if (state.scenes.isEmpty) {
      return switch (state.phase) {
        LibraryPhase.initial || LibraryPhase.loading || LibraryPhase.ready =>
          const AppLoadingView(semanticLabel: 'Loading scenes'),
        LibraryPhase.empty => AppEmptyView(
          message: 'No scenes match these filters',
          actionLabel: 'Clear filters',
          onAction: onClearFilters,
        ),
        LibraryPhase.failed => AppErrorView(
          // `Failure.message` can carry raw server text, so only
          // `userMessage` is ever rendered here.
          message: state.failure?.userMessage ?? 'Something went wrong.',
          onRetry: controller.retry,
        ),
      };
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.phase == LibraryPhase.failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space5,
              AppTokens.space3,
              AppTokens.space5,
              0,
            ),
            child: AppInlineBanner(
              message: state.failure?.userMessage ?? 'Something went wrong.',
              actionLabel: 'Retry',
              onAction: controller.retry,
            ),
          ),
        Expanded(
          child: SceneGrid(
            scenes: state.scenes,
            isLoadingMore: state.isLoading,
            thumbnailRepository: thumbnailRepository,
            onOpenScene: onOpenScene,
            ensureViewportFilled: controller.ensureViewportFilled,
          ),
        ),
      ],
    );
  }
}
