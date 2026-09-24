import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_spinner.dart';

Future<void> _pump(WidgetTester tester, TargetPlatform platform) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, platform: platform),
        home: const Center(child: AppSpinner(size: 24)),
      ),
    );

void main() {
  testWidgets('Adwaita spins an arc', (tester) async {
    await _pump(tester, TargetPlatform.linux);
    expect(find.byKey(AppSpinner.arcKey), findsOneWidget);
    expect(find.byKey(AppSpinner.spokesKey), findsNothing);
    expect(tester.getSize(find.byType(AppSpinner)), const Size.square(24));
  });

  testWidgets('macOS spins spokes', (tester) async {
    await _pump(tester, TargetPlatform.macOS);
    expect(find.byKey(AppSpinner.spokesKey), findsOneWidget);
  });

  testWidgets('keeps animating', (tester) async {
    await _pump(tester, TargetPlatform.linux);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.hasRunningAnimations, isTrue);
  });
}
