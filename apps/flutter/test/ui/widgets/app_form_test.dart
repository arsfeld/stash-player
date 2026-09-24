import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_form.dart';

void main() {
  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform: a group shows its title, rows and description, '
        'and a row its error under the field', (tester) async {
      await _pump(tester, platform);

      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Only if needed.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_urlKey)).decoration!.errorText,
        'Bad URL',
      );
      expect(find.text('Bad URL'), findsOneWidget);
      expect(find.byKey(_trailingKey), findsOneWidget);
    });
  }

  testWidgets('Adwaita: the row label is the field label, like AdwEntryRow', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.linux);
    expect(
      tester.widget<TextField>(find.byKey(_urlKey)).decoration!.labelText,
      'Server URL',
    );
  });

  testWidgets('macOS: the label sits in its own column, left of the field', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.macOS);
    expect(
      tester.getCenter(find.text('Server URL:')).dx,
      lessThan(tester.getCenter(find.byKey(_urlKey)).dx),
    );
  });
}

const _urlKey = Key('url');
const _trailingKey = Key('trailing');

Future<void> _pump(WidgetTester tester, TargetPlatform platform) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, platform: platform),
        home: Scaffold(
          body: AppPreferencesGroup(
            title: 'Server',
            description: 'Only if needed.',
            children: [
              AppEntryRow(
                fieldKey: _urlKey,
                label: 'Server URL',
                controller: TextEditingController(),
                errorText: 'Bad URL',
              ),
              AppEntryRow(
                label: 'API key',
                hint: 'Optional',
                controller: TextEditingController(),
                trailing: const SizedBox(key: _trailingKey, width: 20),
              ),
            ],
          ),
        ),
      ),
    );
