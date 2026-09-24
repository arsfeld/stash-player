import 'package:flutter/widgets.dart';

import 'app_menu.dart';

/// Converts an [AppMenu] into a menu for Flutter's [PlatformMenuBar] (the
/// macOS menu bar). Separators become group boundaries, a disabled action
/// becomes an item with no callback, and [AppMenuAction.shortcut] becomes
/// the item's key equivalent.
///
/// [AppMenuAction.checked] is dropped: [PlatformMenuItem] has no check
/// state. Menu-bar toggles say what they will do instead ("Mute" /
/// "Unmute"), which is also the macOS convention for them.
PlatformMenu toPlatformMenu(String label, AppMenu menu) {
  final groups = <List<PlatformMenuItem>>[[]];
  for (final entry in menu.entries) {
    switch (entry) {
      case AppMenuSeparator():
        if (groups.last.isNotEmpty) groups.add([]);
      case AppMenuAction():
        groups.last.add(
          PlatformMenuItem(
            label: entry.label,
            shortcut: entry.shortcut,
            onSelected: entry.enabled ? entry.onSelected : null,
          ),
        );
    }
  }
  return PlatformMenu(
    label: label,
    menus: [
      for (final group in groups)
        if (group.isNotEmpty) PlatformMenuItemGroup(members: group),
    ],
  );
}
