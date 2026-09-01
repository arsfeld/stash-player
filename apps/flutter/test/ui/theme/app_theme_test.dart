import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';

void main() {
  test('dark theme is neutral, not the starter purple', () {
    final theme = buildAppTheme(Brightness.dark);

    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.surface, AppPalette.darkBackground);
    expect(theme.scaffoldBackgroundColor, AppPalette.darkBackground);
    expect(theme.colorScheme.primary, AppPalette.accent);
    expect(theme.useMaterial3, isTrue);
  });

  test('light theme is neutral and shares the accent', () {
    final theme = buildAppTheme(Brightness.light);

    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.surface, AppPalette.lightBackground);
    expect(theme.colorScheme.primary, AppPalette.accent);
  });

  test('both themes register AppTokens with brightness-correct controls', () {
    expect(
      buildAppTheme(Brightness.dark).extension<AppTokens>()?.controlSurface,
      AppPalette.darkControl,
    );
    expect(
      buildAppTheme(Brightness.light).extension<AppTokens>()?.controlSurface,
      AppPalette.lightControl,
    );
  });

  test('AppTokens lerp interpolates every colour field', () {
    final dark = buildAppTheme(Brightness.dark).extension<AppTokens>()!;
    final light = buildAppTheme(Brightness.light).extension<AppTokens>()!;

    expect(dark.lerp(light, 0).controlSurface, dark.controlSurface);
    expect(dark.lerp(light, 1).controlSurface, light.controlSurface);
    expect(dark.lerp(light, 1).textFaint, light.textFaint);
  });
}
