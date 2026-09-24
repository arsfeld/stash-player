import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_toast.dart';

Future<Material> _pump(
  WidgetTester tester,
  TargetPlatform platform, {
  Color? background,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light, platform: platform),
      home: Center(
        child: AppToast(message: 'Saved', background: background),
      ),
    ),
  );
  return tester.widget<Material>(
    find.descendant(of: find.byType(AppToast), matching: find.byType(Material)),
  );
}

void main() {
  testWidgets('Adwaita toasts are dark pills', (tester) async {
    final material = await _pump(tester, TargetPlatform.linux);
    expect(material.shape, const StadiumBorder());
    expect(material.color, AppToast.adwaitaFill);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('the toast announces itself to screen readers', (tester) async {
    await _pump(tester, TargetPlatform.linux);
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(of: find.byType(Material), matching: find.byType(Semantics))
          .first,
    );
    expect(semantics.properties.liveRegion, isTrue);
  });

  testWidgets('macOS toasts are rounded HUD panels', (tester) async {
    final material = await _pump(tester, TargetPlatform.macOS);
    expect(
      material.shape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  });

  testWidgets('a severity colour replaces the fill', (tester) async {
    final material = await _pump(
      tester,
      TargetPlatform.linux,
      background: const Color(0xFFC01C28),
    );
    expect(material.color, const Color(0xFFC01C28));
  });

  test('Adwaita toasts sit at the bottom, macOS ones at the top', () {
    expect(AppToast.alignmentFor(TargetPlatform.linux), Alignment.bottomCenter);
    expect(AppToast.alignmentFor(TargetPlatform.macOS), Alignment.topCenter);
  });
}
