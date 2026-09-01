import 'package:flutter/material.dart';

import '../../ui/theme/app_tokens.dart';
import 'player_icon_button.dart';

/// The scene screen's top chrome: back, title, and the metadata toggle,
/// over a scrim that darkens only the top edge of the picture.
///
/// Purely presentational. Fades in and out with [PlayerBar] on the scene
/// screen's existing auto-hide timer.
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    required this.title,
    required this.metadataOpen,
    required this.onBack,
    required this.onToggleMetadata,
    super.key,
  });

  final String title;
  final bool metadataOpen;
  final VoidCallback onBack;
  final VoidCallback onToggleMetadata;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x9E000000), Color(0x00000000)],
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space3,
          AppTokens.space2,
          AppTokens.space3,
          AppTokens.space5,
        ),
        child: Row(
          children: [
            PlayerIconButton(
              icon: Icons.arrow_back,
              tooltip: 'Back to library',
              onPressed: onBack,
            ),
            const SizedBox(width: AppTokens.space2),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTokens.playerText,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            PlayerIconButton(
              icon: Icons.info_outline,
              tooltip: metadataOpen ? 'Hide details' : 'Show details',
              onPressed: onToggleMetadata,
            ),
          ],
        ),
      ),
    ),
  );
}
