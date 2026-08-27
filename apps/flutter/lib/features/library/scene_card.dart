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
              Padding(
                // Kept deliberately tight: the grid delegate's
                // `childAspectRatio` (16/12) budgets only enough height
                // below a 16:9 thumbnail for a single title line plus one
                // metadata row — anything roomier overflows the cell.
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
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
            ],
          ),
        ),
      ),
    );
  }
}

class _SceneThumbnail extends StatelessWidget {
  const _SceneThumbnail({
    required this.source,
    required this.thumbnailRepository,
  });

  final String? source;
  final ThumbnailRepository? thumbnailRepository;

  @override
  Widget build(BuildContext context) {
    final source = this.source;
    final repository = thumbnailRepository;
    if (source == null || repository == null) return const ScenePlaceholder();

    return FutureBuilder<Uint8List?>(
      future: repository.load(
        source,
        SceneCard.thumbnailWidth,
        SceneCard.thumbnailHeight,
      ),
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
