import 'package:flutter/material.dart';

import '../../domain/scene_stream.dart';
import '../../ui/icons/app_icons.dart';
import '../../ui/menu/app_menu.dart';
import '../../ui/menu/native_menus.dart';
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
                icon: AppIcon.back,
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
                Builder(
                  builder: (anchor) => PlayerIconButton(
                    icon: AppIcon.quality,
                    tooltip: 'Video quality',
                    onPressed: () => _openQualityMenu(anchor),
                  ),
                ),
              PlayerIconButton(
                icon: AppIcon.info,
                tooltip: metadataOpen ? 'Hide details' : 'Show details',
                onPressed: onToggleMetadata,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// The top bar fades on the scene screen's auto-hide timer, so it is
  /// held open ([onMenuOpenChanged]) for as long as the menu is up. The
  /// choice is applied only after the menu has closed, so the bar is
  /// released before the stream switch starts, the same order as before.
  ///
  /// `onMenuOpenChanged(false)` runs in a `finally` so the bar can't stay
  /// pinned open forever if `show` throws.
  Future<void> _openQualityMenu(BuildContext anchor) async {
    SceneStream? chosen;
    onMenuOpenChanged(true);
    try {
      await NativeMenusScope.of(anchor).show(
        anchor,
        AppMenu([
          for (final stream in streamOptions)
            AppMenuAction(
              label: stream.label,
              checked: stream == currentStream,
              onSelected: () => chosen = stream,
            ),
        ]),
        globalRectOf(anchor),
      );
    } finally {
      onMenuOpenChanged(false);
    }
    if (chosen case final stream?) onSelectStream(stream);
  }
}
