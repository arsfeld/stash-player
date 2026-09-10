import 'package:flutter/material.dart';

import '../../domain/scene_stream.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/window_chrome.dart';
import 'player_icon_button.dart';

/// The scene screen's top chrome: back, title, the quality menu, and the
/// metadata toggle, over a scrim that darkens only the top edge of the
/// picture.
///
/// Purely presentational. Fades in and out with [PlayerBar] on the scene
/// screen's existing auto-hide timer.
///
/// This is the scene screen's stand-in for [AppWindowChrome], and it
/// takes both its leading inset and its band height from that same
/// widget's static methods. The macOS window is configured with a
/// transparent, full-size-content titlebar and an empty unified toolbar,
/// which are *window*-level settings: the Flutter view extends under the
/// traffic lights on every screen, not just the ones that use the strip,
/// and the lights sit on the same centre line here as they do over the
/// library. Reading both metrics from [AppWindowChrome] rather than
/// hardcoding them keeps the two top bars from drifting apart, which is
/// how the back button ended up underneath the lights.
///
/// The gradient scrim runs past the band's bottom edge so the title fades
/// out over the picture instead of ending on a hard line.
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    required this.title,
    required this.metadataOpen,
    required this.onBack,
    required this.onToggleMetadata,
    required this.streamOptions,
    required this.currentStream,
    required this.onSelectStream,
    required this.onMenuOpenChanged,
    super.key,
  });

  final String title;
  final bool metadataOpen;
  final VoidCallback onBack;
  final VoidCallback onToggleMetadata;

  /// Everything Stash offered for this scene, in Stash's own order. The
  /// menu button hides itself when there is nothing to choose between.
  final List<SceneStream> streamOptions;

  /// The stream actually playing, checked in the menu. `null` while no
  /// scene has loaded.
  final SceneStream? currentStream;
  final ValueChanged<SceneStream> onSelectStream;

  /// Fires `true` when the menu opens and `false` when it closes (by a
  /// pick or a dismiss), so the caller can hold the auto-hide timer off
  /// while a menu anchored to this bar is still on screen.
  final ValueChanged<bool> onMenuOpenChanged;

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
        padding: EdgeInsets.only(
          left: AppWindowChrome.leadingInsetFor(Theme.of(context).platform),
          right: AppTokens.space3,
          bottom: AppTokens.space5,
        ),
        child: SizedBox(
          height: AppWindowChrome.stripHeightFor(Theme.of(context).platform),
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
              if (streamOptions.length > 1)
                PopupMenuButton<SceneStream>(
                  tooltip: 'Video quality',
                  icon: const Icon(
                    Icons.high_quality_outlined,
                    color: AppTokens.playerText,
                  ),
                  // The top bar fades on the scene screen's auto-hide
                  // timer. Without this the menu would outlive the bar it
                  // is anchored to.
                  onOpened: () => onMenuOpenChanged(true),
                  onCanceled: () => onMenuOpenChanged(false),
                  onSelected: (stream) {
                    onMenuOpenChanged(false);
                    onSelectStream(stream);
                  },
                  itemBuilder: (context) => [
                    for (final stream in streamOptions)
                      PopupMenuItem<SceneStream>(
                        value: stream,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: stream == currentStream
                                  ? const Icon(Icons.check, size: 18)
                                  : null,
                            ),
                            Expanded(child: Text(stream.label)),
                          ],
                        ),
                      ),
                  ],
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
    ),
  );
}
