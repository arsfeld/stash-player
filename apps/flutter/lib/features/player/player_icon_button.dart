import 'package:flutter/material.dart';

import '../../ui/theme/app_tokens.dart';

/// How a [PlayerIconButton] presents itself.
enum PlayerIconButtonVariant {
  /// A small translucent tile behind the glyph. For chrome drawn straight
  /// over the picture with nothing else behind it, like the top bar.
  tile,

  /// Just the glyph, with a wash only on hover and press. For controls
  /// that already sit on a frame of their own, like the player bar.
  bare,

  /// [bare], with the glyph a step dimmer, for the secondary controls
  /// that should not compete with the transport.
  subdued,

  /// A solid white circle with a dark glyph, used for play/pause so there
  /// is one obvious target rather than a row of equal-weight icons.
  primary,
}

/// An icon control for the player's chrome. Always light, because it sits
/// over video regardless of the app's theme.
class PlayerIconButton extends StatelessWidget {
  const PlayerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.variant = PlayerIconButtonVariant.tile,
    super.key,
  }) : assert(tooltip != '', 'an icon-only control needs a tooltip');

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final PlayerIconButtonVariant variant;

  /// Side length of every variant but [PlayerIconButtonVariant.primary].
  /// The player bar's reflow breakpoints are built from these two sizes.
  static const double size = 28;

  /// Side length of [PlayerIconButtonVariant.primary].
  static const double primarySize = 38;

  /// The glyph on the primary variant's white circle, dark enough to read
  /// against it.
  static const Color _primaryGlyph = Color(0xFF16181C);

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final primary = variant == PlayerIconButtonVariant.primary;
    final extent = primary ? primarySize : size;
    final radius = BorderRadius.circular(
      variant == PlayerIconButtonVariant.tile
          ? AppTokens.radiusPlayerControl
          : extent / 2,
    );
    // Player chrome is always dark, so its hovered and pressed states are
    // a wash of the glyph colour rather than the theme's controlHover /
    // controlActive, which follow the app's brightness. The primary
    // variant inverts: a solid white circle darkens instead of brightening.
    final overlay = primary ? _primaryGlyph : AppTokens.playerText;
    final Color glyph = switch (variant) {
      PlayerIconButtonVariant.primary => _primaryGlyph,
      PlayerIconButtonVariant.subdued => AppTokens.playerGlyphSubdued,
      _ => AppTokens.playerText,
    };
    final Color? fill = switch (variant) {
      PlayerIconButtonVariant.primary => AppTokens.playerText,
      PlayerIconButtonVariant.tile => AppTokens.playerControl,
      _ => null,
    };
    final double glyphSize = switch (variant) {
      PlayerIconButtonVariant.primary => 22,
      PlayerIconButtonVariant.tile => 15,
      _ => 18,
    };

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: Container(
          width: extent,
          height: extent,
          decoration: BoxDecoration(color: fill, borderRadius: radius),
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
                  size: glyphSize,
                  color: primary || enabled
                      ? glyph
                      : glyph.withValues(alpha: 0.38),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
