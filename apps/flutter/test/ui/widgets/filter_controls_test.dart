import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/filter_controls.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('AppMenuButton', () {
    testWidgets('shows the label of the current value', (tester) async {
      await _pump(
        tester,
        AppMenuButton<int>(
          value: 40,
          tooltip: 'Minimum rating',
          items: const [
            AppMenuItem(value: 0, label: 'Any rating'),
            AppMenuItem(value: 40, label: '2+ stars'),
          ],
          onChanged: (_) {},
        ),
      );

      expect(find.text('2+ stars'), findsOneWidget);
      expect(find.text('Any rating'), findsNothing);
    });

    testWidgets('reports a zero sentinel selection like any other', (
      tester,
    ) async {
      // The reason the type parameter is non-nullable: PopupMenuButton and
      // showMenu both report a null selection as a dismissal, so a nullable
      // "none" entry could never be chosen. Callers pass a sentinel instead.
      int? selected;
      await _pump(
        tester,
        AppMenuButton<int>(
          value: 40,
          tooltip: 'Minimum rating',
          items: const [
            AppMenuItem(value: 0, label: 'Any rating'),
            AppMenuItem(value: 40, label: '2+ stars'),
          ],
          onChanged: (value) => selected = value,
        ),
      );

      await tester.tap(find.text('2+ stars'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Any rating').last);
      await tester.pumpAndSettle();

      expect(selected, 0);
    });

    testWidgets('activates from the keyboard', (tester) async {
      final focusNode = FocusNode(debugLabel: 'probe');
      addTearDown(focusNode.dispose);
      await _pump(
        tester,
        AppMenuButton<int>(
          value: 0,
          focusNode: focusNode,
          tooltip: 'Minimum rating',
          items: const [
            AppMenuItem(value: 0, label: 'Any rating'),
            AppMenuItem(value: 40, label: '2+ stars'),
          ],
          onChanged: (_) {},
        ),
      );

      focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('2+ stars'), findsOneWidget);
    });
  });

  group('AppIconToggle', () {
    testWidgets('carries a tooltip and a semantics label', (tester) async {
      await _pump(
        tester,
        AppIconToggle(
          icon: Icons.visibility_off,
          tooltip: 'Hide scenes that have already been played',
          semanticLabel: 'Hide tracked scenes',
          selected: true,
          onPressed: () {},
        ),
      );

      expect(
        find.byTooltip('Hide scenes that have already been played'),
        findsOneWidget,
      );
      expect(
        tester
            .getSemantics(find.byType(AppIconToggle))
            .label
            .contains('Hide tracked scenes'),
        isTrue,
      );
    });

    test('rejects an empty tooltip or semantics label', () {
      expect(
        () => AppIconToggle(
          icon: Icons.visibility_off,
          tooltip: '',
          semanticLabel: 'Hide tracked scenes',
          selected: false,
          onPressed: () {},
        ),
        throwsAssertionError,
      );
      expect(
        () => AppIconToggle(
          icon: Icons.visibility_off,
          tooltip: 'Hide tracked',
          semanticLabel: '',
          selected: false,
          onPressed: () {},
        ),
        throwsAssertionError,
      );
    });

    testWidgets('fires onPressed when tapped', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        AppIconToggle(
          icon: Icons.visibility_off,
          tooltip: 'Hide tracked',
          semanticLabel: 'Hide tracked scenes',
          selected: false,
          onPressed: () => taps++,
        ),
      );

      await tester.tap(find.byType(AppIconToggle));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('AppSearchField', () {
    testWidgets('puts the caller key on the editable field itself', (
      tester,
    ) async {
      // `tester.enterText` needs the key to resolve to the EditableText, so
      // the key goes on the inner TextField, not on the wrapper.
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var latest = '';
      await _pump(
        tester,
        AppSearchField(
          fieldKey: const Key('probe-search'),
          controller: controller,
          onChanged: (value) => latest = value,
        ),
      );

      await tester.enterText(find.byKey(const Key('probe-search')), 'kyoto');
      await tester.pump();

      expect(latest, 'kyoto');
    });
  });
}
