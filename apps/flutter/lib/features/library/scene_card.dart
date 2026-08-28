import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/scene.dart';
import '../../services/thumbnail_repository.dart';
import '../../shared/formatters.dart';
import '../../shared/scene_placeholder.dart';

/// One scene tile in the library grid: a 16:9 thumbnail, title, formatted
/// duration, rating, and a resume indicator when playback was left
/// partway through.
///
/// Purely presentational — [onOpen] is the only intent it produces, fired
/// by both mouse activation (`InkWell`'s own tap) and the keyboard
/// (Enter/Space activate a focused `InkWell` the same way any Material
/// button does). Owns its own [FocusNode] (rather than taking one from a
/// parent) so the library grid doesn't need to track a growing/shrinking
/// map of nodes as pages load — each card manages its own lifecycle.
class SceneCard extends StatefulWidget {
  const SceneCard({
    required this.scene,
    required this.thumbnailRepository,
    required this.onOpen,
    super.key,
  });

  final Scene scene;

  /// `null` while the connection-bound repository is still resolving —
  /// treated exactly like a `null` [ThumbnailRepository.load] result:
  /// [ScenePlaceholder] instead of a thumbnail.
  final ThumbnailRepository? thumbnailRepository;
  final VoidCallback onOpen;

  /// The pixel size thumbnails are requested at — matches the grid
  /// delegate's `maxCrossAxisExtent` (320) at a 16:9 aspect ratio.
  static const int thumbnailWidth = 320;
  static const int thumbnailHeight = 180;

  @override
  State<SceneCard> createState() => _SceneCardState();
}

class _SceneCardState extends State<SceneCard> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'scene-card-${widget.scene.id}');
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    final duration = scene.files.isNotEmpty ? scene.files.first.duration : null;
    final resumeAvailable = scene.effectiveResume != null;

    return Semantics(
      button: true,
      label: scene.displayTitle,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          focusNode: _focusNode,
          onTap: widget.onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  _SceneThumbnail(
                    source: scene.paths.screenshot,
                    thumbnailRepository: widget.thumbnailRepository,
                  ),
                  if (resumeAvailable)
                    const Positioned(
                      left: 8,
                      bottom: 8,
                      child: Tooltip(
                        message: 'Resume available',
                        child: Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 4)],
                        ),
                      ),
                    ),
                ],
              ),
              // The grid delegate's `childAspectRatio` (16/12) leaves only
              // `0.1875 * tileWidth` below the 16:9 thumbnail for this
              // metadata block, and that budget shrinks below what a
              // title line plus one metadata row needs at some common
              // window widths (and at any width once the system text
              // scale grows) — a fixed-height Column here overflows in
              // exactly those cases. `Expanded` gives this block whatever
              // is actually left (never negative, since the thumbnail
              // above is always shorter than the whole cell), and
              // `FittedBox` uniformly shrinks its content to fit that
              // space instead of overflowing it — the tradeoff is that a
              // card squeezed enough shows smaller text rather than
              // truncating further, which is preferable to a rendering
              // error. `ConstrainedBox` caps the *reference* size the
              // title lays out at before any shrinking, so the `Text`'s
              // own `overflow: ellipsis` still has a meaningful width to
              // truncate against for a very long title.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            scene.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (duration != null) ...[
                                const Icon(Icons.schedule, size: 14),
                                const SizedBox(width: 4),
                                Text(
                                  formatDuration(duration),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                              if (duration != null && scene.rating100 != null)
                                const SizedBox(width: 12),
                              if (scene.rating100 case final int rating100) ...[
                                const Icon(Icons.star, size: 14),
                                const SizedBox(width: 4),
                                Text(
                                  formatRating(rating100),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
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
/// inside `build()` — [LibraryScreen] watches a `ChangeNotifierProvider`,
/// so *every* `notifyListeners()` (a page landing, a filter change, a
/// bottom-of-grid fetch starting or finishing) rebuilds every currently
/// visible card. Calling `repository.load(...)` directly in `build()`
/// would fire a brand new HTTP fetch for the same already-fetched (or
/// already in-flight) thumbnail on every single one of those
/// notifications — with dozens of cards on screen and no in-flight dedupe
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
    // actually changed — e.g. the connection-bound repository just
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
            SceneCard.thumbnailWidth,
            SceneCard.thumbnailHeight,
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
