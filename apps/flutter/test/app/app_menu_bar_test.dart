import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_menu_bar.dart';
import 'package:stash_player_flutter/features/player/playback_menu.dart';

void main() {
  test('the bar is app, Edit, Playback, View, Window, in that order', () {
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      view: viewMenu(null, (_) {}),
      onCheckForUpdates: () {},
    );
    expect(bar.cast<PlatformMenu>().map((m) => m.label), [
      'Stash Player',
      'Edit',
      'Playback',
      'View',
      'Window',
    ]);
  });

  test('the app menu checks for updates', () {
    var checked = 0;
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      view: viewMenu(null, (_) {}),
      onCheckForUpdates: () => checked++,
    );
    final app = bar.first as PlatformMenu;
    final item = app.menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .whereType<PlatformMenuItem>()
        .singleWhere((item) => item.label == 'Check for Updates…');
    item.onSelected!();
    expect(checked, 1);
  });

  test('Edit carries the standard key equivalents', () {
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      view: viewMenu(null, (_) {}),
      onCheckForUpdates: () {},
    );
    final edit = bar[1] as PlatformMenu;
    final shortcuts = edit.menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .cast<PlatformMenuItem>()
        .map((item) => (item.shortcut! as SingleActivator).trigger);
    expect(shortcuts, [
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyA,
    ]);
  });

  testWidgets('only macOS gets a PlatformMenuBar', (tester) async {
    final sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.menu, (call) async {
          sent.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, null),
    );

    await tester.pumpWidget(
      const ProviderScope(child: AppMenuBar(child: SizedBox())),
    );
    expect(find.byType(PlatformMenuBar), findsNothing);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      const ProviderScope(
        child: AppMenuBar(child: SizedBox(key: Key('x'))),
      ),
    );
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
