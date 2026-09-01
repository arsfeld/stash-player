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
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(
          filled ? 17 : AppTokens.radiusControl,
        ),
        child: Container(
          width: filled ? 34 : 28,
          height: filled ? 34 : 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? AppTokens.playerText : AppTokens.playerControl,
            borderRadius: BorderRadius.circular(
              filled ? 17 : AppTokens.radiusControl,
            ),
          ),
          child: Icon(
            icon,
            size: filled ? 18 : 15,
            color: filled ? const Color(0xFF16181C) : AppTokens.playerText,
          ),
        ),
      ),
    ),
  );
}
