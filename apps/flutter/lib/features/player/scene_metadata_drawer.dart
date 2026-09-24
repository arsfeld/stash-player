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
/// to [maxWidth] and sliding it in from the right over the video, never
/// resizing the video itself (see that file's own doc for the `Stack`
/// layering this must never become a `Row` or split pane).
///
/// The panel is always dark, in both app themes, because it sits over
/// video. Everything inside it therefore takes its colour from the
/// always-dark player tokens by way of [_drawerTheme], never from the
/// ambient theme: theme-derived text on a theme-independent surface put
/// `AppPalette.lightText` on this panel in light mode, a contrast ratio
/// of about 1.02:1 that made the whole drawer invisible.
class SceneMetadataDrawer extends StatelessWidget {
  const SceneMetadataDrawer({
    required this.scene,
    required this.onClose,
    super.key,
  });

  /// The drawer's maximum width. `SceneScreen` is responsible for
  /// applying it; this widget has no opinion on its own position.
  static const double maxWidth = AppTokens.drawerMaxWidth;

  /// The panel's own fill. Near-opaque and near-black in both themes,
  /// because the drawer slides over video. Named so the contrast tests
  /// can measure against the real value rather than a copy of it.
  static const Color panelColor = Color(0xF0131416);

  final Scene scene;
  final VoidCallback onClose;

  /// The drawer's own theme: the ambient one with every text, icon and
  /// chip colour swapped for the always-dark player tokens.
  ///
  /// A whole [ThemeData] rather than a colour on each [Text] because the
  /// drawer's descendants read colours from four different places, and
  /// only a theme reaches all of them: [TextTheme] for the labelled
  /// styles, [ColorScheme.onSurfaceVariant] for the section labels, the
  /// file-table labels and the M3 [IconButton]'s glyph, [ChipThemeData]
  /// for the performer chips (whose light fill on a black panel was the
  /// one thing still legible, and wrong), and the [DefaultTextStyle] the
  /// enclosing [Material] republishes for the bare description [Text].
  static ThemeData _drawerTheme(ThemeData theme) {
    final textTheme = theme.textTheme.apply(
      bodyColor: AppTokens.playerText,
      displayColor: AppTokens.playerText,
    );
    return theme.copyWith(
      textTheme: textTheme,
      iconTheme: const IconThemeData(color: AppTokens.playerText),
      colorScheme: theme.colorScheme.copyWith(
        onSurface: AppTokens.playerText,
        onSurfaceVariant: AppTokens.playerTextDim,
        surfaceContainerHighest: AppTokens.playerControl,
      ),
      chipTheme: theme.chipTheme.copyWith(
        backgroundColor: AppTokens.playerControl,
        labelStyle: textTheme.labelMedium?.copyWith(
          color: AppTokens.playerText,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: panelColor,
      border: Border(left: BorderSide(color: AppTokens.playerHairline)),
    ),
    child: Theme(
      data: _drawerTheme(Theme.of(context)),
      // The drawer's own Material, for two reasons. It republishes the
      // DefaultTextStyle from the theme above, which is what gives the
      // bare description Text a legible colour; and it hosts the close
      // button's ink, which otherwise goes to the scene screen's
      // Scaffold and paints behind the video.
      child: Material(
        type: MaterialType.transparency,
        child: Builder(builder: _buildContents),
      ),
    ),
  );

  Widget _buildContents(BuildContext context) {
    final theme = Theme.of(context);
    final file = scene.files.isNotEmpty ? scene.files.first : null;

    return SafeArea(
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
              (scene.date?.isNotEmpty ?? false) ? scene.date! : 'Unknown date',
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
