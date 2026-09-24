import 'package:flutter/widgets.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';
import 'package:stash_player_flutter/ui/menu/native_menus.dart';

/// A [NativeMenus] that records what was shown and "selects" the action
/// labelled [choose], if any, the way a native menu would.
class RecordingMenus implements NativeMenus {
  RecordingMenus({this.choose});

  String? choose;
  final List<AppMenu> shown = [];
  final List<Rect> anchors = [];

  @override
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor) async {
    shown.add(menu);
    anchors.add(anchor);
    for (final entry in menu.entries) {
      if (entry is AppMenuAction && entry.label == choose) {
        entry.onSelected();
      }
    }
  }
}
