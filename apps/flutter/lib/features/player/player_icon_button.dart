import 'package:flutter/material.dart';

import '../../ui/theme/app_tokens.dart';

/// A translucent icon control for the player's chrome. Always light,
/// because it sits over video regardless of the app's theme.
///
/// [filled] makes it the primary control: a solid white circle with a dark
/// glyph, used for play/pause so there is one obvious target rather than
/// six equal-weight icons.
class PlayerIconButton extends StatelessWidget {
  const PlayerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.filled = false,
    super.key,
  }) : assert(tooltip != '', 'an icon-only control needs a tooltip');

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  /// The glyph on the [filled] variant's white pill, dark enough to read
  /// against it.
  static const Color _filledGlyph = Color(0xFF16181C);

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(filled ? 17 : AppTokens.radiusControl);
    // Player chrome is always dark, so its hovered and pressed states are
    // a wash of the glyph colour rather than the theme's controlHover /
    // controlActive, which follow the app's brightness. The filled
    // variant inverts: a solid white pill darkens instead of brightening.
    final overlay = filled ? _filledGlyph : AppTokens.playerText;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: Container(
          width: filled ? 34 : 28,
          height: filled ? 34 : 28,
          decoration: BoxDecoration(
            color: filled ? AppTokens.playerText : AppTokens.playerControl,
            borderRadius: radius,
          ),
          // A Material between the fill and the InkWell. Ink features
          // paint directly above their host Material and below the rest
          // of its subtree, so a control whose opaque background sits
          // under its InkWell hides every splash it produces. The
          // nearest Material here was the scene screen's Scaffold,
          // behind the video.
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              hoverColor: overlay.withValues(alpha: 0.1),
              highlightColor: overlay.withValues(alpha: 0.18),
              splashColor: overlay.withValues(alpha: 0.18),
              borderRadius: radius,
              child: Center(
                child: Icon(
                  icon,
                  size: filled ? 18 : 15,
                  color: filled
                      ? _filledGlyph
                      : AppTokens.playerText.withValues(
                          alpha: enabled ? 1 : 0.38,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
