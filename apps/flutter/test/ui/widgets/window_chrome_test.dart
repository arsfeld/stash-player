import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';
import 'package:stash_player_flutter/ui/widgets/window_chrome.dart';

Future<void> _pumpChrome(WidgetTester tester, TargetPlatform platform) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark).copyWith(platform: platform),
        home: const Scaffold(
          body: AppWindowChrome(
            children: [
              SizedBox(
                key: Key('probe'),
                width: 40,
                height: AppTokens.controlBandHeight,
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  test('leading inset clears the traffic lights only on macOS', () {
    expect(
      AppWindowChrome.leadingInsetFor(TargetPlatform.macOS),
      AppTokens.trafficLightInset,
    );
    expect(
      AppWindowChrome.leadingInsetFor(TargetPlatform.linux),
      AppTokens.stripInset,
    );
  });

  test('the control band is top-aligned only on macOS', () {
    expect(
      AppWindowChrome.alignmentFor(TargetPlatform.macOS),
      Alignment.topCenter,
    );
    expect(AppWindowChrome.alignmentFor(TargetPlatform.linux), Alignment.center);
  });

  testWidgets('on macOS the band starts at the top, inset for the lights', (
    tester,
  ) async {
    await _pumpChrome(tester, TargetPlatform.macOS);

    final topLeft = tester.getTopLeft(find.byKey(const Key('probe')));
    expect(topLeft.dx, AppTokens.trafficLightInset);
    // Top-aligned so our controls share the system titlebar's centre line.
    expect(topLeft.dy, 0);
  });

  testWidgets('elsewhere the band is centred with ordinary padding', (
    tester,
  ) async {
    await _pumpChrome(tester, TargetPlatform.linux);

    final topLeft = tester.getTopLeft(find.byKey(const Key('probe')));
    expect(topLeft.dx, AppTokens.stripInset);
    expect(
      topLeft.dy,
      (AppTokens.stripHeight - AppTokens.controlBandHeight) / 2,
    );
  });

  testWidgets('the strip is exactly stripHeight tall', (tester) async {
    await _pumpChrome(tester, TargetPlatform.linux);

    expect(
      tester.getSize(find.byType(AppWindowChrome)).height,
      AppTokens.stripHeight,
    );
  });
}
