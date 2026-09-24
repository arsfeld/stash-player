import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_dialog.dart';
import 'package:stash_player_flutter/ui/widgets/app_spinner.dart';

void main() {
  testWidgets('Adwaita: Cancel, title and Save share a header bar above the '
      'body', (tester) async {
    await _pump(tester, platform: TargetPlatform.linux);

    final cancel = tester.getCenter(find.text('Cancel'));
    final title = tester.getCenter(find.text('Connection'));
    final save = tester.getCenter(find.text('Save'));
    final body = tester.getCenter(find.byKey(_bodyKey));

    expect(cancel.dx, lessThan(title.dx));
    expect(title.dx, lessThan(save.dx));
    expect(cancel.dy, moreOrLessEquals(save.dy, epsilon: 1));
    expect(save.dy, lessThan(body.dy));
  });

  testWidgets('macOS: the title leads and Cancel, Save sit bottom-right '
      'below the body', (tester) async {
    await _pump(tester, platform: TargetPlatform.macOS);

    final title = tester.getCenter(find.text('Connection'));
    final cancel = tester.getCenter(find.text('Cancel'));
    final save = tester.getCenter(find.text('Save'));
    final body = tester.getCenter(find.byKey(_bodyKey));

    expect(title.dy, lessThan(body.dy));
    expect(cancel.dy, greaterThan(body.dy));
    expect(cancel.dx, lessThan(save.dx));
    // A sheet hangs from the titlebar, so it starts below the strip.
    final sheet = find
        .ancestor(of: find.text('Connection'), matching: find.byType(Material))
        .first;
    expect(tester.getTopLeft(sheet).dy, greaterThanOrEqualTo(52));
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform: Escape cancels and Enter confirms', (tester) async {
      var cancelled = 0;
      var confirmed = 0;
      await _pump(
        tester,
        platform: platform,
        onCancel: () => cancelled++,
        onConfirm: () => confirmed++,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(cancelled, 1);
      expect(confirmed, 1);
    });

    testWidgets('$platform: busy shows a spinner and Enter does nothing', (
      tester,
    ) async {
      var confirmed = 0;
      await _pump(
        tester,
        platform: platform,
        onConfirm: () => confirmed++,
        busy: true,
      );

      expect(find.byType(AppSpinner), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(confirmed, 0);
    });
  }

  testWidgets('Adwaita: clicking the dimmed window dismisses the dialog', (
    tester,
  ) async {
    final removed = await _pump(tester, platform: TargetPlatform.linux);

    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(removed, ['dialog']);
  });

  testWidgets('macOS: clicking outside a sheet does not dismiss it', (
    tester,
  ) async {
    final removed = await _pump(tester, platform: TargetPlatform.macOS);

    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(removed, isEmpty);
  });

  testWidgets('a disabled Cancel also blocks dismissal by the barrier', (
    tester,
  ) async {
    final removed = await _pump(
      tester,
      platform: TargetPlatform.linux,
      cancelEnabled: false,
    );

    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(removed, isEmpty);
  });
}

const _bodyKey = Key('body');

/// Pumps an [AppDialogPage] over a blank page and returns the names of
/// pages the navigator reports as removed.
Future<List<String?>> _pump(
  WidgetTester tester, {
  required TargetPlatform platform,
  VoidCallback? onCancel,
  VoidCallback? onConfirm,
  bool busy = false,
  bool cancelEnabled = true,
}) async {
  final removed = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light, platform: platform),
      home: Navigator(
        pages: [
          const MaterialPage<void>(name: 'home', child: SizedBox.expand()),
          AppDialogPage<void>(
            name: 'dialog',
            child: AppDialog(
              title: 'Connection',
              cancel: AppDialogAction(
                label: 'Cancel',
                onPressed: cancelEnabled ? (onCancel ?? () {}) : null,
              ),
              confirm: AppDialogAction(
                label: 'Save',
                onPressed: onConfirm ?? () {},
                busy: busy,
              ),
              child: const SizedBox(key: _bodyKey, height: 80),
            ),
          ),
        ],
        onDidRemovePage: (page) => removed.add(page.name),
      ),
    ),
  );
  await _settle(tester);
  return removed;
}

/// `pumpAndSettle` would never return while the busy spinner animates.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
