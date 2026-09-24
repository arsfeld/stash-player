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

  test('the strip is taller on macOS, where it is also the titlebar', () {
    expect(
      AppWindowChrome.stripHeightFor(TargetPlatform.macOS),
      AppTokens.macOSStripHeight,
    );
    expect(
      AppWindowChrome.stripHeightFor(TargetPlatform.linux),
      AppTokens.stripHeight,
    );
  });

  testWidgets('on macOS the band is centred on the traffic lights', (
    tester,
  ) async {
    await _pumpChrome(tester, TargetPlatform.macOS);

    final probe = find.byKey(const Key('probe'));
    expect(tester.getTopLeft(probe).dx, AppTokens.trafficLightInset);
    // The lights' own centre line, measured off the running window: 25.5.
    // Anything that pins the band to the top of the strip again, which is
    // what made every control touch the window edge, fails here.
    expect(tester.getCenter(probe).dy, closeTo(25.5, 1));
  });

  testWidgets('on macOS the first control clears the lights', (tester) async {
    await _pumpChrome(tester, TargetPlatform.macOS);

    // The rightmost light ends at x=78. Butting the first control against
    // that exact edge is what left the two visibly touching.
    expect(
      tester.getTopLeft(find.byKey(const Key('probe'))).dx,
      greaterThan(78),
    );
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

  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets('the strip is exactly its platform height on $platform', (
      tester,
    ) async {
      await _pumpChrome(tester, platform);

      expect(
        tester.getSize(find.byType(AppWindowChrome)).height,
        AppWindowChrome.stripHeightFor(platform),
      );
    });
  }
}
