import 'package:flutter/widgets.dart';

import '../../ui/menu/app_menu.dart';
import 'playback_controller.dart';
import 'playback_state.dart';
import 'player_shortcuts.dart';

/// The macOS menu bar's Playback menu. [state] is null off the scene
/// screen, where every item is disabled.
///
/// Each item's shortcut is looked up from [playerKeyBindings], the one
/// source of truth for player keys, so the menu can never show a key that
/// does something else. The key itself is still handled by the scene
/// screen's own `Shortcuts`: Flutter sees a key before AppKit's menu does,
/// so the menu's key equivalent only fires for a key Flutter left
/// unhandled.
AppMenu playbackMenu(
  PlaybackState? state,
  void Function(PlayerAction) dispatch,
) {
  AppMenuAction item(String label, PlayerAction action) => AppMenuAction(
    label: label,
    enabled: state != null,
    shortcut: _shortcutFor(action),
    onSelected: () => dispatch(action),
  );

  return AppMenu([
    item(
      state?.playing ?? false ? 'Pause' : 'Play',
      PlayerAction.togglePlayPause,
    ),
    const AppMenuSeparator(),
    item('Back 5 Seconds', PlayerAction.seekBackward5),
    item('Forward 5 Seconds', PlayerAction.seekForward5),
    item('Back 10 Seconds', PlayerAction.seekBackward10),
    item('Forward 10 Seconds', PlayerAction.seekForward10),
    item('Back 1 Minute', PlayerAction.seekBackward60),
    item('Forward 1 Minute', PlayerAction.seekForward60),
    item('Go to Start', PlayerAction.seekToStart),
    item('Go to End', PlayerAction.seekToEnd),
    const AppMenuSeparator(),
    item('Volume Up', PlayerAction.volumeUp),
    item('Volume Down', PlayerAction.volumeDown),
    item(state?.muted ?? false ? 'Unmute' : 'Mute', PlayerAction.toggleMute),
  ]);
}

SingleActivator? _shortcutFor(PlayerAction action) {
  for (final MapEntry(:key, :value) in playerKeyBindings.entries) {
    if (value == action) return SingleActivator(key);
  }
  return null;
}
