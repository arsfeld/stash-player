import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';
import 'package:stash_player_flutter/ui/menu/platform_menu_adapter.dart';

void main() {
  test('separators split the menu into groups', () {
    var ran = 0;
    final menu = toPlatformMenu(
      'Playback',
      AppMenu([
        AppMenuAction(
          label: 'Play',
          shortcut: const SingleActivator(LogicalKeyboardKey.space),
          onSelected: () => ran++,
        ),
        const AppMenuSeparator(),
        AppMenuAction(label: 'Mute', onSelected: () {}),
        AppMenuAction(label: 'Off', enabled: false, onSelected: () {}),
      ]),
    );

    expect(menu.label, 'Playback');
    final groups = menu.menus.cast<PlatformMenuItemGroup>();
    expect(groups.map((g) => g.members.length), [1, 2]);

    final play = groups.first.members.single;
    expect(play.label, 'Play');
    expect(play.shortcut, const SingleActivator(LogicalKeyboardKey.space));
    play.onSelected!();
    expect(ran, 1);

    final off = groups.last.members.last;
    expect(off.onSelected, isNull);
  });

  test('leading, trailing and doubled separators leave no empty group', () {
    final menu = toPlatformMenu(
      'X',
      AppMenu([
        const AppMenuSeparator(),
        AppMenuAction(label: 'A', onSelected: () {}),
        const AppMenuSeparator(),
        const AppMenuSeparator(),
        AppMenuAction(label: 'B', onSelected: () {}),
        const AppMenuSeparator(),
      ]),
    );
    expect(menu.menus, hasLength(2));
  });
}
