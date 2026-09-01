import 'package:flutter/material.dart';

import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/window_chrome.dart';
import 'player_icon_button.dart';

/// The scene screen's top chrome: back, title, and the metadata toggle,
/// over a scrim that darkens only the top edge of the picture.
///
/// Purely presentational. Fades in and out with [PlayerBar] on the scene
/// screen's existing auto-hide timer.
///
/// This is the scene screen's stand-in for [AppWindowChrome], and it
/// takes its leading inset from that same method. The macOS window is
/// configured with a transparent, full-size-content titlebar, which is a
/// *window*-level setting: the Flutter view extends under the traffic
/// lights on every screen, not just the ones that use the strip. Reading
/// the inset from [AppWindowChrome.leadingInsetFor] rather than
/// hardcoding one keeps the two top bars from drifting apart, which is
/// how the back button ended up underneath the lights.
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
        padding: EdgeInsets.fromLTRB(
          AppWindowChrome.leadingInsetFor(Theme.of(context).platform),
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
