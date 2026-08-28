import 'package:flutter/material.dart';

import '../../domain/scene.dart';
import '../../shared/formatters.dart';

/// The right-hand metadata overlay: title, details, date, studio,
/// performer chips, and file info (duration, resolution, codec, frame
/// rate) — every field with a safe fallback for Stash's own nullable
/// GraphQL schema (`Scene`'s own doc: "Every metadata field is
/// nullable").
///
/// Purely presentational, and deliberately has no opinion on its own
/// width or position — `SceneScreen` is responsible for constraining this
/// to the brief's 420-logical-pixel max width and sliding it in from the
/// right over the video, never resizing the video itself (see that file's
/// own doc for the `Stack` layering this must never become a `Row` or
/// split pane).
class SceneMetadataDrawer extends StatelessWidget {
  const SceneMetadataDrawer({
    required this.scene,
    required this.onClose,
    super.key,
  });

  /// The brief's mandated maximum drawer width, in logical pixels.
  static const double maxWidth = 420;

  final Scene scene;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = scene.files.isNotEmpty ? scene.files.first : null;

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      scene.displayTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  Tooltip(
                    message: 'Close metadata',
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: onClose,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                (scene.date?.isNotEmpty ?? false)
                    ? scene.date!
                    : 'Unknown date',
                style: theme.textTheme.bodyMedium,
              ),
              if (scene.studio case final StudioRef studio) ...[
                const SizedBox(height: 4),
                Text(studio.name, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 12),
              Text(
                (scene.details?.isNotEmpty ?? false)
                    ? scene.details!
                    : 'No description available.',
              ),
              if (scene.performers.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Performers', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final performer in scene.performers)
                      Chip(label: Text(performer.name)),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('File info', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('Duration: ${_duration(file)}'),
              Text('Resolution: ${_resolution(file)}'),
              Text('Codec: ${_codec(file)}'),
              Text('Frame rate: ${_frameRate(file)}'),
            ],
          ),
        ),
      ),
    );
  }

  static String _duration(SceneFile? file) {
    final duration = file?.duration;
    return duration == null ? 'Unknown' : formatDuration(duration);
  }

  static String _resolution(SceneFile? file) {
    final width = file?.width;
    final height = file?.height;
    return (width == null || height == null) ? 'Unknown' : '$width×$height';
  }

  static String _codec(SceneFile? file) => file?.videoCodec ?? 'Unknown';

  static String _frameRate(SceneFile? file) {
    final frameRate = file?.frameRate;
    return frameRate == null ? 'Unknown' : '${frameRate.round()} fps';
  }
}
