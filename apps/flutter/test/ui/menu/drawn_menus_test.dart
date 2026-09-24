import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';
import 'package:stash_player_flutter/ui/menu/drawn_menus.dart';
import 'package:stash_player_flutter/ui/menu/native_menus.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

import '../../support/recording_menus.dart';

void main() {
  late List<String> picked;
  late AppMenu menu;

  setUp(() {
    picked = [];
    menu = AppMenu([
      AppMenuAction(
        label: 'One',
        checked: true,
        onSelected: () => picked.add('One'),
      ),
      const AppMenuSeparator(),
      AppMenuAction(label: 'Two', onSelected: () => picked.add('Two')),
      AppMenuAction(
        label: 'Off',
        enabled: false,
        onSelected: () => picked.add('Off'),
      ),
    ]);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                const DrawnMenus().show(context, menu, globalRectOf(context)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows every action, a divider, and the check', (tester) async {
    await open(tester);
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);
  });

  testWidgets('runs the chosen action once the menu closes', (tester) async {
    await open(tester);
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(picked, ['Two']);
  });

  testWidgets('a disabled action cannot be chosen', (tester) async {
    await open(tester);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });

  testWidgets('dismissing runs nothing', (tester) async {
    await open(tester);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });

  testWidgets('NativeMenusScope.of falls back to DrawnMenus', (tester) async {
    late NativeMenus found;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          found = NativeMenusScope.of(context);
          return const SizedBox();
        },
      ),
    );
    expect(found, isA<DrawnMenus>());
  });

  testWidgets('NativeMenusScope.of returns the scoped renderer', (
    tester,
  ) async {
    final recording = RecordingMenus();
    late NativeMenus found;
    await tester.pumpWidget(
      NativeMenusScope(
        menus: recording,
        child: Builder(
          builder: (context) {
            found = NativeMenusScope.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(found, same(recording));
  });
}
