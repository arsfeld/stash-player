import 'package:flutter/material.dart';

import '../../domain/scene.dart';
import '../../shared/formatters.dart';
import '../../ui/theme/app_tokens.dart';

/// The right-hand metadata overlay: title, details, date, studio,
/// performer chips, and file info (duration, resolution, codec, frame
/// rate), every field with a safe fallback for Stash's own nullable
/// GraphQL schema (`Scene`'s own doc: "Every metadata field is
/// nullable").
///
/// Purely presentational, and deliberately has no opinion on its own
/// width or position: `SceneScreen` is responsible for constraining this
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

  /// The drawer's maximum width. `SceneScreen` is responsible for
  /// applying it; this widget has no opinion on its own position.
  static const double maxWidth = AppTokens.drawerMaxWidth;

  final Scene scene;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = scene.files.isNotEmpty ? scene.files.first : null;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xF0131416),
        border: Border(left: BorderSide(color: AppTokens.playerHairline)),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.space4),
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
                const _SectionLabel('Performers'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final performer in scene.performers)
                      Chip(
                        avatar: CircleAvatar(
                          radius: 10,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          child: Text(
                            _initial(performer.name),
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        label: Text(performer.name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppTokens.space4),
              const _SectionLabel('File'),
              const SizedBox(height: AppTokens.space2),
              Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: FlexColumnWidth(),
                },
                children: [
                  _fileRow(context, 'Duration', _duration(file)),
                  _fileRow(context, 'Resolution', _resolution(file)),
                  _fileRow(context, 'Codec', _codec(file)),
                  _fileRow(context, 'Frame rate', _frameRate(file)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static TableRow _fileRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            right: AppTokens.space4,
            bottom: AppTokens.space1,
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppTokens.space1),
          child: Text(value, style: theme.textTheme.bodySmall),
        ),
      ],
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

  /// First character of [name], for the chip avatar. Empty names are
  /// possible (every Stash metadata field is nullable and the decoder
  /// defaults absent ones), so they fall back to a placeholder.
  static String _initial(String name) =>
      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
}

/// A small uppercase heading above a group of metadata.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
