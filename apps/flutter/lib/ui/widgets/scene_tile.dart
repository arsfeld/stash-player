import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/scene.dart';
import '../../services/thumbnail_repository.dart';
import '../../shared/scene_labels.dart';
import '../../shared/scene_placeholder.dart';
import '../theme/app_tokens.dart';

/// Geometry for the library grid.
///
/// The grid computes its own cell size instead of using
/// `childAspectRatio`, because a chromeless tile's height is a 16:9
/// thumbnail *plus* a text block whose height follows the text scale, not
/// a constant multiple of the tile's width. Deriving `mainAxisExtent` here
/// is what lets the tile drop the `FittedBox` that used to shrink each
/// title to whatever space was left over, which is why titles rendered at
/// visibly different sizes from tile to tile.
@immutable
class SceneGridGeometry {
  const SceneGridGeometry({
    required this.columnCount,
    required this.tileWidth,
    required this.tileHeight,
  });

  static const double maxTileWidth = AppTokens.sceneTileMaxWidth;
  static const double crossAxisSpacing = AppTokens.space4;
  static const double mainAxisSpacing = AppTokens.space5;

  static const double titleFontSize = 13;
  static const double subtitleFontSize = 12;
  static const double lineHeight = 1.3;

  final int columnCount;
  final double tileWidth;
  final double tileHeight;

  /// Height of the text block beneath a thumbnail: the gap under the
  /// image, a title line, a small gap, and a subtitle line.
  static double textBlockHeight(TextScaler textScaler) =>
      AppTokens.space2 +
      textScaler.scale(titleFontSize) * lineHeight +
      AppTokens.space1 / 2 +
      textScaler.scale(subtitleFontSize) * lineHeight;

  static SceneGridGeometry resolve({
    required double availableWidth,
    required TextScaler textScaler,
  }) {
    final usable = math.max(1.0, availableWidth);
    final columnCount = math.max(1, (usable / maxTileWidth).ceil());
    final tileWidth =
        (usable - crossAxisSpacing * (columnCount - 1)) / columnCount;
    return SceneGridGeometry(
      columnCount: columnCount,
      tileWidth: tileWidth,
      tileHeight:
          tileWidth / sceneThumbnailAspectRatio + textBlockHeight(textScaler),
    );
  }
}

/// One scene in the library grid: a rounded thumbnail with the title and
/// subtitle beneath it, on the page background. No container, no border,
/// no elevation. The artwork is the only strong shape.
///
/// Purely presentational; [onOpen] is the only intent it produces, fired
/// by both a mouse tap and the keyboard (Enter and Space activate a
/// focused `InkWell`). Owns its own [FocusNode] so the grid does not have
/// to track a map of nodes as pages load.
class SceneTile extends StatefulWidget {
  const SceneTile({
    required this.scene,
    required this.thumbnailRepository,
    required this.onOpen,
    super.key,
  });

  final Scene scene;

  /// `null` while the connection-bound repository is still resolving,
  /// treated exactly like a `null` load result: a [ScenePlaceholder].
  final ThumbnailRepository? thumbnailRepository;
  final VoidCallback onOpen;

  /// A true 2x for the 280px tile, so artwork stays crisp on a Retina
  /// display. The disk cache keys on these dimensions, so changing them
  /// re-fetches every thumbnail once.
  static const int thumbnailWidth = 560;
  static const int thumbnailHeight = 315;

  @override
  State<SceneTile> createState() => _SceneTileState();
}

class _SceneTileState extends State<SceneTile> {
  late final FocusNode _focusNode;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'scene-tile-${widget.scene.id}');
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTokens.of(context);
    final scene = widget.scene;

    return Semantics(
      button: true,
      label: scene.displayTitle,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          focusNode: _focusNode,
          onTap: widget.onOpen,
          onFocusChange: (focused) => setState(() => _focused = focused),
          borderRadius: BorderRadius.circular(AppTokens.radiusControl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: AppTokens.hoverDuration,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    AppTokens.radiusControl + 2,
                  ),
                  border: Border.all(
                    color: _focused
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusControl),
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      _SceneThumbnail(
                        source: scene.paths.screenshot,
                        thumbnailRepository: widget.thumbnailRepository,
                      ),
                      if (_hovered)
                        const Positioned.fill(
                          child: ColoredBox(color: Color(0x1FFFFFFF)),
                        ),
                      if (scene.effectiveResume != null)
                        const Positioned(
                          left: AppTokens.space2,
                          bottom: AppTokens.space2,
                          child: Tooltip(
                            message: 'Resume available',
                            child: Icon(
                              Icons.play_circle_fill,
                              size: 20,
                              color: Colors.white,
                              shadows: [Shadow(blurRadius: 4)],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.space2),
              Text(
                scene.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: AppTokens.space1 / 2),
              Text(
                sceneSubtitle(scene),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loads (and caches) the thumbnail for [source] via [thumbnailRepository].
///
/// A `StatefulWidget` specifically so the loaded [Future] is created once
/// per (source, repository) pair and reused across rebuilds, rather than
/// inside `build()`. [LibraryScreen] watches a `ChangeNotifierProvider`,
/// so *every* `notifyListeners()` (a page landing, a filter change, a
/// bottom-of-grid fetch starting or finishing) rebuilds every currently
/// visible card. Calling `repository.load(...)` directly in `build()`
/// would fire a brand new HTTP fetch for the same already-fetched (or
/// already in-flight) thumbnail on every single one of those
/// notifications, with dozens of cards on screen and no in-flight dedupe
/// in `DiskThumbnailRepository` itself, a few page loads would queue
/// hundreds of duplicate GETs behind the fetch semaphore and starve the
/// thumbnails actually needed next.
class _SceneThumbnail extends StatefulWidget {
  const _SceneThumbnail({
    required this.source,
    required this.thumbnailRepository,
  });

  final String? source;
  final ThumbnailRepository? thumbnailRepository;

  @override
  State<_SceneThumbnail> createState() => _SceneThumbnailState();
}

class _SceneThumbnailState extends State<_SceneThumbnail> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant _SceneThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only start a new load when the source or the repository *instance*
    // actually changed: e.g. the connection-bound repository just
    // resolved from `null` to a real one, or (across a card recycling
    // the same `State`, which `ValueKey(scene.id)` at the grid level
    // prevents) the scene itself changed. Every other rebuild reuses the
    // cached `_future`.
    if (widget.source != oldWidget.source ||
        widget.thumbnailRepository != oldWidget.thumbnailRepository) {
      _startLoad();
    }
  }

  void _startLoad() {
    final source = widget.source;
    final repository = widget.thumbnailRepository;
    _future = (source == null || repository == null)
        ? null
        : repository.load(
            source,
            SceneTile.thumbnailWidth,
            SceneTile.thumbnailHeight,
          );
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) return const ScenePlaceholder();

    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return const ScenePlaceholder();
        return AspectRatio(
          aspectRatio: sceneThumbnailAspectRatio,
          child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        );
      },
    );
  }
}
