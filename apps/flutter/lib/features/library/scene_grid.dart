import 'package:flutter/material.dart';

import '../../domain/scene.dart';
import '../../services/thumbnail_repository.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/scene_tile.dart';

/// Signature of [LibraryController.ensureViewportFilled], threaded through
/// as a plain callback so this widget stays ignorant of Riverpod/the
/// controller — it only ever forwards measured extents.
typedef EnsureViewportFilled =
    Future<void> Function({
      required double contentExtent,
      required double viewportExtent,
    });

/// The library's scrollable grid of [SceneTile]s, plus the two triggers
/// that keep paging moving:
///
/// - A scroll listener that asks for another page once the user scrolls
///   within [_loadMoreThreshold] logical pixels of the bottom.
/// - A post-frame check, re-run every time [scenes]' length changes, that
///   asks for another page if the content accepted so far doesn't even
///   fill the viewport yet (the "does a single page overflow a large
///   monitor" case — an edge-reached-only trigger stalls forever here,
///   since the grid never becomes scrollable in the first place).
///
/// Both triggers call the same [ensureViewportFilled] callback with
/// different measured (contentExtent, viewportExtent) pairs — the
/// controller's own guards (already loading, no more pages, failed) make
/// firing it repeatedly from a scroll listener or a rebuild loop safe.
class SceneGrid extends StatefulWidget {
  const SceneGrid({
    required this.scenes,
    required this.ordinals,
    required this.isLoadingMore,
    required this.thumbnailRepository,
    required this.onOpenScene,
    required this.ensureViewportFilled,
    super.key,
  });

  final List<Scene> scenes;

  /// [scenes]' 0-based positions in the active filter's ordering, same
  /// order, one per entry. See [LibraryState.ordinals]'s own doc for why
  /// this can diverge from plain list index and must be threaded through
  /// rather than derived here from `index`.
  final List<int> ordinals;
  final bool isLoadingMore;
  final ThumbnailRepository? thumbnailRepository;

  /// Called with the tapped scene's id and its ordinal (from [ordinals])
  /// in the active filter's ordering. The scene screen needs that
  /// ordinal to step through the ordering.
  final void Function(String sceneId, int index) onOpenScene;
  final EnsureViewportFilled ensureViewportFilled;

  @override
  State<SceneGrid> createState() => _SceneGridState();
}

class _SceneGridState extends State<SceneGrid> {
  static const double _loadMoreThreshold = 600;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _scheduleViewportCheck();
  }

  @override
  void didUpdateWidget(covariant SceneGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-measure and ask again after every frame that landed a new (or
    // shrunk-by-filter-reset, though that unmounts this widget before it
    // gets here) page — this is what closes the loop for a viewport a
    // single page doesn't fill: the controller only ever fetches one page
    // per call, and relies on the caller to keep asking.
    if (oldWidget.scenes.length != widget.scenes.length) {
      _scheduleViewportCheck();
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _scheduleViewportCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The widget (or its State) may have been unmounted between
      // scheduling this callback and the frame actually landing —
      // guard so a stray callback never touches a disposed controller.
      if (!mounted) return;
      _checkViewportFilled();
    });
  }

  void _checkViewportFilled() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // `maxScrollExtent` is 0 whenever content doesn't overflow the
    // viewport (whether it's exactly the same size or far short of it),
    // so reconstructing the total content extent as
    // `maxScrollExtent + viewportDimension` collapses those two cases
    // together — both correctly read as "not yet more than the
    // viewport" and keep the fill loop going. The moment content
    // actually overflows by any amount, this sum exceeds
    // `viewportDimension` and the loop stops.
    widget.ensureViewportFilled(
      contentExtent: position.maxScrollExtent + position.viewportDimension,
      viewportExtent: position.viewportDimension,
    );
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final remaining = position.maxScrollExtent - position.pixels;
    // Reuse the same "is there still at least `viewportExtent` worth of
    // content ahead?" check, but scoped to "the next `_loadMoreThreshold`
    // logical pixels below the current scroll position" rather than the
    // whole viewport — this is the near-bottom infinite-scroll trigger.
    widget.ensureViewportFilled(
      contentExtent: remaining,
      viewportExtent: _loadMoreThreshold,
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final geometry = SceneGridGeometry.resolve(
              availableWidth: constraints.maxWidth - AppTokens.space5 * 2,
              textScaler: MediaQuery.textScalerOf(context),
            );
            return GridView.builder(
              key: const Key('library-scene-grid'),
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space5,
                vertical: AppTokens.space4,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: geometry.columnCount,
                crossAxisSpacing: SceneGridGeometry.crossAxisSpacing,
                mainAxisSpacing: SceneGridGeometry.mainAxisSpacing,
                mainAxisExtent: geometry.tileHeight,
              ),
              itemCount: widget.scenes.length,
              itemBuilder: (context, index) {
                final scene = widget.scenes[index];
                // Captured here, not read from `widget.ordinals[index]`
                // inside the tap closure below: `index` is fixed at
                // build time, but the closure itself can outlive this
                // build (a filter change shrinking `ordinals` before the
                // tile is tapped), which would otherwise turn a stale
                // `index` into a `RangeError` at tap time instead of
                // build time.
                final ordinal = widget.ordinals[index];
                return SceneTile(
                  key: ValueKey(scene.id),
                  scene: scene,
                  thumbnailRepository: widget.thumbnailRepository,
                  onOpen: () => widget.onOpenScene(scene.id, ordinal),
                );
              },
            );
          },
        ),
      ),
      if (widget.isLoadingMore)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
    ],
  );
}
