import 'package:flutter/material.dart';

import 'app_menu.dart';
import 'native_menus.dart';

/// Renders an [AppMenu] as a Material popup menu styled by the theme's
/// `popupMenuTheme`. Used by widget tests, on platforms with no native
/// renderer, and as `ChannelNativeMenus`'s fallback.
class DrawnMenus implements NativeMenus {
  const DrawnMenus();

  @override
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = anchor.shift(-overlay.localToGlobal(Offset.zero));
    final position = RelativeRect.fromRect(
      Rect.fromPoints(local.bottomLeft, local.bottomRight),
      Offset.zero & overlay.size,
    );

    final actions = <int, AppMenuAction>{};
    final items = <PopupMenuEntry<int>>[];
    for (final entry in menu.entries) {
      switch (entry) {
        case AppMenuSeparator():
          items.add(const PopupMenuDivider());
        case AppMenuAction():
          final id = actions.length;
          actions[id] = entry;
          items.add(
            PopupMenuItem<int>(
              value: id,
              enabled: entry.enabled,
              height: 32,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: entry.checked == true ? const Text('✓') : null,
                  ),
                  Flexible(child: Text(entry.label)),
                ],
              ),
            ),
          );
      }
    }

    final chosen = await showMenu<int>(
      context: context,
      position: position,
      items: items,
    );
    if (chosen != null) actions[chosen]!.onSelected();
  }
}
