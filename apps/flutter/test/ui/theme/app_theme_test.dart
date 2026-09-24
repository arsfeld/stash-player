import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';

import '../../support/contrast.dart';

const _linux = TargetPlatform.linux;
const _mac = TargetPlatform.macOS;

void main() {
  group('palette per dialect and brightness', () {
    final cases = {
      (_linux, Brightness.light): AppPalette.adwaitaLight,
      (_linux, Brightness.dark): AppPalette.adwaitaDark,
      (_mac, Brightness.light): AppPalette.macosLight,
      (_mac, Brightness.dark): AppPalette.macosDark,
    };
    for (final MapEntry(key: (platform, brightness), value: palette)
        in cases.entries) {
      test('$platform $brightness', () {
        final theme = buildAppTheme(brightness, platform: platform);
        expect(theme.platform, platform);
        expect(theme.brightness, brightness);
        expect(theme.colorScheme.surface, palette.background);
        expect(theme.scaffoldBackgroundColor, palette.background);
        expect(theme.colorScheme.surfaceContainer, palette.chrome);
        expect(theme.colorScheme.primary, AppPalette.fallbackAccent);
        expect(theme.extension<AppTokens>()?.controlSurface, palette.control);
        expect(theme.useMaterial3, isTrue);
      });

      test('$platform $brightness text is legible', () {
        expect(
          contrastRatio(palette.text, palette.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(palette.textDim, palette.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(palette.textDim, palette.chrome),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(palette.error, palette.background),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  test('an OS accent replaces the fallback everywhere it is used', () {
    const accent = Color(0xFFE66100);
    final theme = buildAppTheme(
      Brightness.dark,
      platform: _linux,
      accent: accent,
    );
    expect(theme.colorScheme.primary, accent);
    expect(theme.filledButtonTheme.style?.backgroundColor?.resolve({}), accent);
    final focused =
        theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
    expect(focused.borderSide.color, accent);
  });

  group('type scale', () {
    test('macOS uses the system UI font at 13pt body', () {
      final text = buildAppTheme(Brightness.light, platform: _mac).textTheme;
      expect(text.bodyMedium?.fontFamily, '.AppleSystemUIFont');
      expect(text.bodyMedium?.fontSize, 13);
    });

    test('Adwaita defaults to Adwaita Sans at 11pt body (14.67px)', () {
      final text = buildAppTheme(Brightness.light, platform: _linux).textTheme;
      expect(text.bodyMedium?.fontFamily, 'Adwaita Sans');
      expect(text.bodyMedium?.fontSize, closeTo(14.67, 0.01));
    });

    test('Adwaita follows the desktop font when one is known', () {
      final text = buildAppTheme(
        Brightness.light,
        platform: _linux,
        fontFamily: 'Cantarell',
        bodyFontPt: 12,
      ).textTheme;
      expect(text.bodyMedium?.fontFamily, 'Cantarell');
      expect(text.bodyMedium?.fontSize, 16);
    });

    test('macOS ignores a desktop font', () {
      final text = buildAppTheme(
        Brightness.light,
        platform: _mac,
        fontFamily: 'Cantarell',
      ).textTheme;
      expect(text.bodyMedium?.fontFamily, '.AppleSystemUIFont');
    });
  });

  test('radii follow the dialect', () {
    final adwaita = buildAppTheme(
      Brightness.dark,
      platform: _linux,
    ).extension<AppTokens>()!;
    final mac = buildAppTheme(
      Brightness.dark,
      platform: _mac,
    ).extension<AppTokens>()!;
    expect((adwaita.radiusControl, adwaita.radiusPanel), (6.0, 12.0));
    expect((mac.radiusControl, mac.radiusPanel), (5.0, 10.0));
  });

  test('AppTokens lerp interpolates every field', () {
    final dark = buildAppTheme(
      Brightness.dark,
      platform: _linux,
    ).extension<AppTokens>()!;
    final light = buildAppTheme(
      Brightness.light,
      platform: _mac,
    ).extension<AppTokens>()!;

    expect(dark.lerp(light, 0).controlSurface, dark.controlSurface);
    expect(dark.lerp(light, 1).controlSurface, light.controlSurface);
    expect(dark.lerp(light, 1).textFaint, light.textFaint);
    expect(dark.lerp(light, 1).radiusControl, light.radiusControl);
    expect(dark.lerp(light, 0.5).radiusPanel, 11);
  });
}
