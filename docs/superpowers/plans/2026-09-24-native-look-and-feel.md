# Native Look and Feel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Flutter client look like a libadwaita app on Linux and an AppKit app on macOS: native popup menus and a macOS menu bar, from one Dart definition; per-platform drawn widgets, palettes, fonts, icons and toasts; and the OS accent colour, live.

**Architecture:** A `PlatformDialect` (`adwaita` | `macos`), derived from `Theme.of(context).platform`, drives everything drawn: `buildAppTheme` picks a palette, type scale, radii and component themes per dialect, and `lib/ui/` widgets (icons, spinner, toast) switch on it. Menus are described once as an `AppMenu` spec; a `NativeMenus` port renders it as a real `NSMenu` / `GtkMenu` over the `stash_player/menu` method channel, or as a drawn Material menu in tests and as a fallback. The OS accent and (Linux) UI font arrive over the `stash_player/appearance` event channel.

**Tech Stack:** Flutter 3 / Dart 3.11, Riverpod 2.6, `flutter_svg`, GTK3 + GIO (Linux runner, C++), AppKit (macOS runner, Swift), GNOME icon-development-kit (CC0) and Lucide (ISC) SVGs.

**Spec:** `docs/superpowers/specs/2026-09-24-native-look-and-feel-design.md`

## Global Constraints

- All work is under `apps/flutter/` except the plan/spec docs and `CLAUDE.md`. Run every command below from `apps/flutter/` inside `nix develop .#flutter` (or use the `just` recipes from the repo root).
- `just flutter-check` (format + `flutter analyze --fatal-infos --fatal-warnings` + `flutter test`) must pass at the end of every task.
- Dialect is always derived from `Theme.of(context).platform` via `PlatformDialect.of(context)`, never from `Platform.isMacOS`, so widget tests can pin either dialect with `buildAppTheme(..., platform: TargetPlatform.macOS)` or `ThemeData.copyWith(platform: ...)`.
- `TargetPlatform.macOS` → `PlatformDialect.macos`; every other platform (Linux, Windows, and Android, which is `flutter_test`'s default) → `PlatformDialect.adwaita`.
- Native where the OS shows its own popup (context/dropdown menus, the macOS menu bar); drawn per dialect inside the content. No platform views.
- Feature code never picks a platform: it builds an `AppMenu` or a `lib/ui/` widget.
- `lib/ui/` must not import Riverpod or anything under `lib/app/`, `lib/features/`, `lib/services/`.
- New native macOS code goes into `macos/Runner/MainFlutterWindow.swift` (next to `LegacySecretChannel`), so no Xcode project edits are needed. New Linux native code goes into new files under `linux/runner/` listed in `linux/runner/CMakeLists.txt`.
- Fallback accent `#3584E4`. Channel names: `stash_player/menu` (method), `stash_player/appearance` (event), `stash_player/updates` (method).
- No `Icons.*` may remain in `lib/` after Task 3 (enforced by a test).
- If `flutter analyze` reports `unnecessary_import` for an import this plan lists, drop that import; the plan errs on the side of listing them.
- Comment style: match the surrounding code — explain *why*, in full sentences, no em dashes in new comments.
- Commit after each task's final step with a conventional message (`feat(flutter): ...`). Don't push.

## File Structure

| File | Responsibility |
|---|---|
| `lib/ui/theme/platform_dialect.dart` (new) | `PlatformDialect` enum + `of(context)` |
| `lib/ui/theme/app_palette.dart` (new) | Four palettes (dialect × brightness) + fallback accent |
| `lib/ui/theme/app_theme.dart` (rewrite) | `buildAppTheme(brightness, {platform, accent, fontFamily, bodyFontPt})` |
| `lib/ui/theme/app_tokens.dart` (modify) | `radiusControl`/`radiusPanel` become per-dialect instance fields |
| `lib/domain/system_appearance.dart` (new) | `SystemAppearance` value + event/font-name decoding |
| `lib/services/system_appearance_channel.dart` (new) | `watchSystemAppearance()` over the event channel |
| `lib/app/providers.dart` (modify) | `systemAppearanceProvider`, `nativeMenusProvider`, `updatesChannelProvider` |
| `linux/runner/appearance_channel.{h,cc}` (new) | Portal `accent-color` + `font-name` → event channel |
| `macos/Runner/MainFlutterWindow.swift` (modify) | Appearance stream, native menu channel, updates channel |
| `tool/fetch_icons.py` (new) | Fetches + sanitizes the pinned icon SVGs |
| `assets/icons/gnome/*.svg`, `assets/icons/lucide/*.svg` (new) | Bundled icons + licence files |
| `lib/ui/icons/app_icons.dart` (new) | `AppIcon` enum (meaning → per-dialect asset) + `AppIconView` |
| `lib/ui/widgets/app_spinner.dart` (new) | Adwaita arc / macOS spokes spinner |
| `lib/ui/widgets/app_toast.dart` (new) | Drawn toast (Adwaita pill / macOS HUD) |
| `lib/app/toast_host.dart` (new) | Shows `globalNoticeProvider` notices as `AppToast`s |
| `lib/ui/menu/app_menu.dart` (new) | `AppMenu`, `AppMenuEntry`, `AppMenuAction`, `AppMenuSeparator` |
| `lib/ui/menu/native_menus.dart` (new) | `NativeMenus` port, `NativeMenusScope`, `globalRectOf` |
| `lib/ui/menu/drawn_menus.dart` (new) | `DrawnMenus` (Material `showMenu` renderer) |
| `lib/services/channel_native_menus.dart` (new) | `ChannelNativeMenus` (method channel + fallback) |
| `linux/runner/native_menu_channel.{h,cc}` (new) | `GtkMenu` popup renderer |
| `lib/ui/menu/platform_menu_adapter.dart` (new) | `AppMenu` → `PlatformMenu` |
| `lib/features/player/playback_menu.dart` (new) | The Playback/View `AppMenu`s |
| `lib/app/app_menu_bar.dart` (new) | macOS `PlatformMenuBar` |
| `test/support/app_icons.dart` (new) | `findAppIcon` / `findWidgetWithAppIcon` finders |

---

### Task 1: Dialects, palettes, type scale and component themes

**Files:**
- Create: `lib/ui/theme/platform_dialect.dart`, `lib/ui/theme/app_palette.dart`
- Rewrite: `lib/ui/theme/app_theme.dart`
- Modify: `lib/ui/theme/app_tokens.dart`, `lib/ui/widgets/filter_controls.dart`, `lib/ui/widgets/scene_tile.dart`, `lib/ui/widgets/status_views.dart`, `lib/features/library/tasks_popover.dart`, `lib/features/player/player_icon_button.dart`
- Test: `test/ui/theme/app_theme_test.dart` (rewrite), `test/ui/theme/platform_dialect_test.dart` (new)

**Interfaces:**
- Produces:
  - `enum PlatformDialect { adwaita, macos }` with `static PlatformDialect forPlatform(TargetPlatform)` and `static PlatformDialect of(BuildContext)`.
  - `class AppPalette` with fields `background, chrome, control, controlHover, controlActive, buttonFace, outline, text, textDim, textFaint, error, onError` (all `Color`), constants `AppPalette.adwaitaLight/adwaitaDark/macosLight/macosDark`, `static AppPalette resolve(PlatformDialect, Brightness)`, `static const Color fallbackAccent`, `static const Color onAccent`.
  - `ThemeData buildAppTheme(Brightness brightness, {TargetPlatform? platform, Color? accent, String? fontFamily, double? bodyFontPt})`. The result's `platform` is `platform ?? defaultTargetPlatform`.
  - `AppTokens` gains instance fields `double radiusControl`, `double radiusPanel` (the static consts of those names are removed) and a static `radiusPlayerControl = 7`.

- [ ] **Step 1: Write the failing dialect test**

Create `test/ui/theme/platform_dialect_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/platform_dialect.dart';

void main() {
  test('only macOS speaks the macOS dialect', () {
    expect(
      PlatformDialect.forPlatform(TargetPlatform.macOS),
      PlatformDialect.macos,
    );
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.android,
    ]) {
      expect(PlatformDialect.forPlatform(platform), PlatformDialect.adwaita);
    }
  });

  testWidgets('of(context) follows the ambient theme platform', (
    tester,
  ) async {
    late PlatformDialect seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) {
            seen = PlatformDialect.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, PlatformDialect.macos);
  });
}
```

- [ ] **Step 2: Rewrite the theme test to describe the new behaviour**

Replace `test/ui/theme/app_theme_test.dart` with:

```dart
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
        expect(
          theme.extension<AppTokens>()?.controlSurface,
          palette.control,
        );
        expect(theme.useMaterial3, isTrue);
      });

      test('$platform $brightness text is legible', () {
        expect(contrastRatio(palette.text, palette.background), >= 4.5);
        expect(contrastRatio(palette.textDim, palette.background), >= 4.5);
        expect(contrastRatio(palette.textDim, palette.chrome), >= 4.5);
        expect(contrastRatio(palette.error, palette.background), >= 4.5);
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
    expect(
      theme.filledButtonTheme.style?.backgroundColor?.resolve({}),
      accent,
    );
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
      final text =
          buildAppTheme(Brightness.light, platform: _linux).textTheme;
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
```

- [ ] **Step 3: Run the two tests to verify they fail**

Run: `flutter test test/ui/theme/`
Expected: compilation errors (`platform_dialect.dart` not found, `AppPalette.adwaitaLight` / `radiusControl` undefined).

- [ ] **Step 4: Create `lib/ui/theme/platform_dialect.dart`**

```dart
import 'package:flutter/material.dart';

/// Which platform's visual language the drawn widgets speak.
///
/// Derived from the theme's platform rather than `Platform.isMacOS`, the
/// same way `AppWindowChrome` picks its layout, so a widget test can pin
/// either dialect by setting `ThemeData.platform`.
enum PlatformDialect {
  /// GNOME's libadwaita, used everywhere except macOS.
  adwaita,

  /// AppKit.
  macos;

  static PlatformDialect forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.macOS ? macos : adwaita;

  static PlatformDialect of(BuildContext context) =>
      forPlatform(Theme.of(context).platform);
}
```

- [ ] **Step 5: Create `lib/ui/theme/app_palette.dart`**

```dart
import 'package:flutter/material.dart';

import 'platform_dialect.dart';

/// Every colour the app's own chrome uses, for one dialect and brightness.
///
/// The Adwaita values are libadwaita 1.6's named colours (`window_bg`,
/// `headerbar_bg`, the 10/15/30% `currentColor` button washes composited
/// over the window) and the macOS ones are AppKit's semantic colours
/// (`windowBackgroundColor`, `controlBackgroundColor`, `labelColor`,
/// `secondaryLabelColor`, `separatorColor`) sampled on Sonoma. Only the
/// accent comes from the OS at runtime; see `buildAppTheme`.
@immutable
class AppPalette {
  const AppPalette({
    required this.background,
    required this.chrome,
    required this.control,
    required this.controlHover,
    required this.controlActive,
    required this.buttonFace,
    required this.outline,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.error,
    required this.onError,
  });

  /// GNOME's default blue, used until the OS reports its own accent. It
  /// also sits close to the macOS default accent.
  static const Color fallbackAccent = Color(0xFF3584E4);
  static const Color onAccent = Color(0xFFFFFFFF);

  static const adwaitaLight = AppPalette(
    background: Color(0xFFFAFAFB),
    chrome: Color(0xFFFFFFFF),
    control: Color(0xFFE1E1E2),
    controlHover: Color(0xFFD5D5D6),
    controlActive: Color(0xFFAFAFB0),
    buttonFace: Color(0xFFE1E1E2),
    outline: Color(0xFFD9D9DA),
    text: Color(0xFF323234),
    textDim: Color(0xFF6E6E70),
    textFaint: Color(0xFF8E8E90),
    error: Color(0xFFC01C28),
    onError: Color(0xFFFFFFFF),
  );

  static const adwaitaDark = AppPalette(
    background: Color(0xFF222226),
    chrome: Color(0xFF2E2E32),
    control: Color(0xFF38383C),
    controlHover: Color(0xFF434347),
    controlActive: Color(0xFF646467),
    buttonFace: Color(0xFF38383C),
    outline: Color(0xFF3D3D41),
    text: Color(0xFFFFFFFF),
    textDim: Color(0xFF9C9C9E),
    textFaint: Color(0xFF808083),
    error: Color(0xFFFF938C),
    onError: Color(0xFF222226),
  );

  static const macosLight = AppPalette(
    background: Color(0xFFFFFFFF),
    chrome: Color(0xFFF6F6F6),
    control: Color(0xFFE8E8E8),
    controlHover: Color(0xFFDDDDDD),
    controlActive: Color(0xFFD0D0D0),
    buttonFace: Color(0xFFFFFFFF),
    outline: Color(0xFFDCDCDC),
    text: Color(0xFF262626),
    textDim: Color(0xFF6E6E73),
    textFaint: Color(0xFF8E8E93),
    error: Color(0xFFD70015),
    onError: Color(0xFFFFFFFF),
  );

  static const macosDark = AppPalette(
    background: Color(0xFF1E1E1E),
    chrome: Color(0xFF2A2A2A),
    control: Color(0xFF3A3A3A),
    controlHover: Color(0xFF454545),
    controlActive: Color(0xFF505050),
    buttonFace: Color(0xFF5C5C5E),
    outline: Color(0xFF3D3D3D),
    text: Color(0xFFDFDFDF),
    textDim: Color(0xFF98989D),
    textFaint: Color(0xFF7C7C80),
    error: Color(0xFFFF6961),
    onError: Color(0xFF1E1E1E),
  );

  static AppPalette resolve(PlatformDialect dialect, Brightness brightness) =>
      switch ((dialect, brightness)) {
        (PlatformDialect.adwaita, Brightness.light) => adwaitaLight,
        (PlatformDialect.adwaita, Brightness.dark) => adwaitaDark,
        (PlatformDialect.macos, Brightness.light) => macosLight,
        (PlatformDialect.macos, Brightness.dark) => macosDark,
      };

  /// Window and scroll-view background.
  final Color background;

  /// The top strip and popover panels (the header bar / titlebar band).
  final Color chrome;

  /// Resting, hovered and pressed fill of the strip's compact controls.
  final Color control;
  final Color controlHover;
  final Color controlActive;

  /// The face of a standard (non-default) push button. Equal to [control]
  /// on Adwaita, where buttons are a wash; white or grey on macOS, where
  /// they are raised bezels.
  final Color buttonFace;

  final Color outline;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color error;
  final Color onError;
}
```

- [ ] **Step 6: Make the radii per-dialect instance fields in `lib/ui/theme/app_tokens.dart`**

Replace the constructor and the `// Corner radii.` block:

```dart
  const AppTokens({
    required this.controlSurface,
    required this.controlHover,
    required this.controlActive,
    required this.textFaint,
    required this.radiusControl,
    required this.radiusPanel,
  });
```

```dart
  // Corner radii that do not vary by dialect. The player's chrome sits
  // over video and keeps one look on every platform.
  static const double radiusPlayerControl = 7;
  static const double radiusPlayerBar = 16;
```

Add the fields next to the colour fields, with a doc comment:

```dart
  /// Corner radius of compact controls and of panels (popovers, banners).
  /// Per dialect: libadwaita uses 6/12, AppKit 5/10.
  final double radiusControl;
  final double radiusPanel;
```

Extend `copyWith` with `double? radiusControl, double? radiusPanel` (same `?? this.x` pattern) and `lerp` with:

```dart
      radiusControl: lerpDouble(radiusControl, other.radiusControl, t)!,
      radiusPanel: lerpDouble(radiusPanel, other.radiusPanel, t)!,
```

Add `import 'dart:ui' show lerpDouble;` at the top.

- [ ] **Step 7: Rewrite `lib/ui/theme/app_theme.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_tokens.dart';
import 'platform_dialect.dart';

export 'app_palette.dart';

/// Builds the app's theme for [brightness] in [platform]'s dialect.
///
/// [platform] defaults to the host's. [accent] is the OS accent colour
/// when one is known. [fontFamily] and [bodyFontPt] are the desktop's UI
/// font as GNOME reports it (`"Adwaita Sans 11"` → `"Adwaita Sans"`,
/// `11`); they only apply to the Adwaita dialect, since macOS always uses
/// its system font.
///
/// Component themes are set for every Material surface the app does not
/// hand-build (buttons, inputs, tooltips, popup menus, chips, sliders,
/// scrollbars) so they speak the same dialect as the hand-built ones.
ThemeData buildAppTheme(
  Brightness brightness, {
  TargetPlatform? platform,
  Color? accent,
  String? fontFamily,
  double? bodyFontPt,
}) {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final dialect = PlatformDialect.forPlatform(resolvedPlatform);
  final adwaita = dialect == PlatformDialect.adwaita;
  final palette = AppPalette.resolve(dialect, brightness);
  final accentColor = accent ?? AppPalette.fallbackAccent;

  final radiusControl = adwaita ? 6.0 : 5.0;
  final radiusPanel = adwaita ? 12.0 : 10.0;

  final family = adwaita ? (fontFamily ?? 'Adwaita Sans') : '.AppleSystemUIFont';
  final fallbackFamilies = adwaita
      ? const ['Cantarell', 'Inter', 'sans-serif']
      : const <String>[];
  final textTheme = _textTheme(
    dialect,
    bodyFontPt: bodyFontPt,
  ).apply(bodyColor: palette.text, displayColor: palette.text);

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: accentColor,
    onPrimary: AppPalette.onAccent,
    secondary: accentColor,
    onSecondary: AppPalette.onAccent,
    error: palette.error,
    onError: palette.onError,
    surface: palette.background,
    onSurface: palette.text,
    onSurfaceVariant: palette.textDim,
    surfaceContainer: palette.chrome,
    surfaceContainerHigh: palette.control,
    surfaceContainerHighest: palette.controlActive,
    outline: palette.outline,
    outlineVariant: palette.outline,
  );

  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radiusControl),
  );
  final panelShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radiusPanel),
  );
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(radiusControl),
    borderSide: BorderSide.none,
  );

  // libadwaita sets every button label in bold and sizes buttons to 34px;
  // AppKit's regular push button is 22-24pt tall with a regular-weight
  // label.
  final buttonText = textTheme.labelMedium?.copyWith(
    fontWeight: adwaita ? FontWeight.w700 : FontWeight.w400,
  );
  final buttonMinimum = Size(0, adwaita ? 34 : 24);
  final buttonPadding = EdgeInsets.symmetric(horizontal: adwaita ? 17 : 12);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    platform: resolvedPlatform,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: palette.background,
    fontFamily: family,
    fontFamilyFallback: fallbackFamilies,
    textTheme: textTheme,
    extensions: [
      AppTokens(
        controlSurface: palette.control,
        controlHover: palette.controlHover,
        controlActive: palette.controlActive,
        textFaint: palette.textFaint,
        radiusControl: radiusControl,
        radiusPanel: radiusPanel,
      ),
    ],
    dividerTheme: DividerThemeData(
      color: palette.outline,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.control,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space3,
        vertical: AppTokens.space2,
      ),
      hintStyle: textTheme.labelMedium?.copyWith(color: palette.textFaint),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      // Adwaita draws a solid 2px accent focus ring; AppKit a softer 3px
      // one at half opacity.
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusControl),
        borderSide: BorderSide(
          color: adwaita ? accentColor : accentColor.withValues(alpha: 0.5),
          width: adwaita ? 2 : 3,
        ),
      ),
    ),
    tooltipTheme: adwaita
        ? TooltipThemeData(
            decoration: BoxDecoration(
              color: const Color(0xE6000000),
              borderRadius: BorderRadius.circular(radiusControl),
            ),
            textStyle: textTheme.bodySmall?.copyWith(
              color: const Color(0xFFFFFFFF),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            waitDuration: const Duration(milliseconds: 500),
          )
        : TooltipThemeData(
            decoration: BoxDecoration(
              color: palette.chrome,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: palette.outline, width: 0.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            textStyle: TextStyle(fontSize: 11, color: palette.text),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            waitDuration: const Duration(seconds: 1),
          ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.chrome,
      surfaceTintColor: Colors.transparent,
      shape: panelShape,
      textStyle: textTheme.labelMedium?.copyWith(color: palette.text),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.chrome,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: palette.text),
      shape: panelShape,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.control,
      side: BorderSide.none,
      labelStyle: textTheme.labelMedium?.copyWith(color: palette.text),
      shape: const StadiumBorder(),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(
        palette.textFaint.withValues(alpha: 0.5),
      ),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accentColor,
      inactiveTrackColor: palette.control,
      thumbColor: accentColor,
      trackHeight: 4,
    ),
    // The default action: Adwaita's "suggested-action", AppKit's default
    // push button.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accentColor,
        foregroundColor: AppPalette.onAccent,
        textStyle: buttonText,
        shape: controlShape,
        minimumSize: buttonMinimum,
        padding: buttonPadding,
      ),
    ),
    // A standard button: a wash on Adwaita, a hairline-bordered bezel on
    // macOS.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: palette.buttonFace,
        foregroundColor: palette.text,
        side: adwaita
            ? BorderSide.none
            : BorderSide(color: palette.outline, width: 0.5),
        textStyle: buttonText,
        shape: controlShape,
        minimumSize: buttonMinimum,
        padding: buttonPadding,
      ),
    ),
    // A flat button: text-coloured on Adwaita, accent-coloured (link
    // style) on macOS.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: adwaita ? palette.text : accentColor,
        textStyle: buttonText,
        shape: controlShape,
        minimumSize: buttonMinimum,
        padding: buttonPadding,
      ),
    ),
  );
}

/// The type scale, without colours or family (both applied by the caller).
///
/// Adwaita sizes follow GTK, which specifies fonts in points at 96 dpi:
/// one point is 4/3 of a logical pixel, so the default 11pt body is
/// 14.67px. Caption is 82% and caption-heading 75% of body, bold, as in
/// libadwaita's stylesheet. macOS uses AppKit's fixed sizes: 13pt body,
/// 11pt small, 10pt mini.
TextTheme _textTheme(PlatformDialect dialect, {double? bodyFontPt}) {
  switch (dialect) {
    case PlatformDialect.adwaita:
      final body = (bodyFontPt ?? 11) * 4 / 3;
      return TextTheme(
        titleMedium: TextStyle(fontSize: body * 1.1, fontWeight: FontWeight.w700),
        titleSmall: TextStyle(
          fontSize: body,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        bodyMedium: TextStyle(fontSize: body),
        bodySmall: TextStyle(fontSize: body * 0.82, height: 1.3),
        labelMedium: TextStyle(fontSize: body),
        labelSmall: TextStyle(
          fontSize: body * 0.75,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
        ),
      );
    case PlatformDialect.macos:
      return const TextTheme(
        titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        bodyMedium: TextStyle(fontSize: 13),
        bodySmall: TextStyle(fontSize: 11, height: 1.3),
        labelMedium: TextStyle(fontSize: 13),
        labelSmall: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.7,
        ),
      );
  }
}
```

(`snackBarTheme` stays until Task 4 removes `SnackBar`.)

- [ ] **Step 8: Migrate radius call sites**

Every `AppTokens.radiusControl` / `AppTokens.radiusPanel` outside `app_tokens.dart` becomes an instance read:

- `lib/ui/widgets/filter_controls.dart` lines 102, 119, 197, 222, 291, 308: `AppTokens.radiusControl` → `tokens.radiusControl` (each build method already has `final tokens = AppTokens.of(context);`).
- `lib/ui/widgets/scene_tile.dart` lines 154, 183, 193, 281: `AppTokens.radiusControl` → `AppTokens.of(context).radiusControl`. Where the expression sits inside a `const` constructor, remove that `const` (the analyzer points at each one).
- `lib/ui/widgets/status_views.dart:138` and `lib/features/library/tasks_popover.dart:149`: `AppTokens.radiusPanel` → `AppTokens.of(context).radiusPanel` (`tasks_popover.dart` already has `tokens`; use `tokens.radiusPanel`).
- `lib/features/player/player_icon_button.dart:58`: `AppTokens.radiusControl` → `AppTokens.radiusPlayerControl`.

Run: `grep -rn "AppTokens.radius\(Control\|Panel\)" lib test`
Expected: no output.

- [ ] **Step 9: Run the theme tests**

Run: `flutter test test/ui/theme/`
Expected: PASS. If a contrast assertion fails, move the failing palette token (`textDim` or `error`) the minimum distance away from the background that passes 4.5:1, and say so in the commit message.

- [ ] **Step 10: Run the whole suite and fix fallout**

Run: `flutter analyze --fatal-infos --fatal-warnings && flutter test`

Expected fallout and the rule for each:
- Tests that pinned `AppPalette.darkBackground`, `AppPalette.accent` and similar old constants: switch them to `AppPalette.adwaitaDark.background`, `AppPalette.fallbackAccent`, and so on. (`flutter_test` runs as Android, so an unpinned theme is the Adwaita dialect.)
- A `RenderFlex overflowed` caused by the larger Adwaita type at a width the test deliberately exercises: fix the widget (a `Flexible` + `TextOverflow.ellipsis` on the text that grew), never widen the test's viewport.
- Any other failure: stop and investigate; it is not expected.

- [ ] **Step 11: Format, check, commit**

```bash
dart format .
just flutter-check   # from the repo root
git add -A lib test
git commit -m "feat(flutter): add Adwaita and macOS dialects to the theme"
```

---

### Task 2: OS accent colour and UI font, live

**Files:**
- Create: `lib/domain/system_appearance.dart`, `lib/services/system_appearance_channel.dart`, `linux/runner/appearance_channel.h`, `linux/runner/appearance_channel.cc`
- Modify: `lib/app/providers.dart`, `lib/app/app.dart`, `linux/runner/CMakeLists.txt`, `linux/runner/my_application.cc`, `macos/Runner/MainFlutterWindow.swift`
- Test: `test/domain/system_appearance_test.dart` (new), `test/app/app_smoke_test.dart` (add a test)

**Interfaces:**
- Consumes: `buildAppTheme(brightness, {accent, fontFamily, bodyFontPt})` from Task 1.
- Produces: `class SystemAppearance { Color? accent; String? fontFamily; double? fontSizePt; static const none; static SystemAppearance fromEvent(Object?); static ({String family, double? sizePt})? parseFontName(String?) }`; `Stream<SystemAppearance> watchSystemAppearance({EventChannel channel})`; `final systemAppearanceProvider = StreamProvider<SystemAppearance>`.
- Channel contract (`stash_player/appearance`, event channel, standard codec): each event is a map `{"accent": int ARGB or null, "fontName": String or null}`. The first event is sent on listen; later ones on every change.

- [ ] **Step 1: Write the failing decoding tests**

Create `test/domain/system_appearance_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/system_appearance.dart';

void main() {
  group('parseFontName', () {
    test('splits a Pango description into family and size', () {
      expect(
        SystemAppearance.parseFontName('Adwaita Sans 11'),
        (family: 'Adwaita Sans', sizePt: 11.0),
      );
      expect(
        SystemAppearance.parseFontName('Cantarell 10.5'),
        (family: 'Cantarell', sizePt: 10.5),
      );
    });

    test('a name with no size keeps the family only', () {
      expect(
        SystemAppearance.parseFontName('Inter'),
        (family: 'Inter', sizePt: null),
      );
    });

    test('empty or missing is unknown', () {
      expect(SystemAppearance.parseFontName(null), isNull);
      expect(SystemAppearance.parseFontName('   '), isNull);
    });
  });

  group('fromEvent', () {
    test('decodes accent and font', () {
      expect(
        SystemAppearance.fromEvent({
          'accent': 0xFFE66100,
          'fontName': 'Adwaita Sans 12',
        }),
        const SystemAppearance(
          accent: Color(0xFFE66100),
          fontFamily: 'Adwaita Sans',
          fontSizePt: 12,
        ),
      );
    });

    test('nulls stay unknown', () {
      expect(
        SystemAppearance.fromEvent({'accent': null, 'fontName': null}),
        SystemAppearance.none,
      );
    });

    test('malformed input decodes to unknown rather than throwing', () {
      expect(SystemAppearance.fromEvent('nonsense'), SystemAppearance.none);
      expect(
        SystemAppearance.fromEvent({'accent': 'blue', 'fontName': 7}),
        SystemAppearance.none,
      );
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/domain/system_appearance_test.dart`
Expected: FAIL, `system_appearance.dart` not found.

- [ ] **Step 3: Create `lib/domain/system_appearance.dart`**

```dart
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// What the desktop reports about its own look: the accent colour, and
/// (on GNOME) the UI font. Every field is null while unknown, which the
/// theme treats as "use the built-in default".
@immutable
class SystemAppearance {
  const SystemAppearance({this.accent, this.fontFamily, this.fontSizePt});

  static const none = SystemAppearance();

  final Color? accent;
  final String? fontFamily;
  final double? fontSizePt;

  /// Decodes one event from the `stash_player/appearance` channel: a map
  /// with an optional ARGB `accent` int and an optional Pango `fontName`
  /// such as `"Adwaita Sans 11"`. Anything malformed decodes to unknown
  /// rather than throwing, since a bad event must never take the theme
  /// down with it.
  static SystemAppearance fromEvent(Object? event) {
    if (event is! Map) return none;
    final accent = event['accent'];
    final fontName = event['fontName'];
    final font = parseFontName(fontName is String ? fontName : null);
    return SystemAppearance(
      accent: accent is int ? Color(accent) : null,
      fontFamily: font?.family,
      fontSizePt: font?.sizePt,
    );
  }

  /// Splits a Pango font description into its family and point size.
  /// Style words (`Bold`, `Italic`) are rare in a UI font setting and are
  /// left in the family, where font matching ignores what it can't use.
  static ({String family, double? sizePt})? parseFontName(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final match = RegExp(r'^(.*?)\s+(\d+(?:\.\d+)?)$').firstMatch(trimmed);
    if (match == null) return (family: trimmed, sizePt: null);
    return (family: match.group(1)!, sizePt: double.parse(match.group(2)!));
  }

  @override
  bool operator ==(Object other) =>
      other is SystemAppearance &&
      other.accent == accent &&
      other.fontFamily == fontFamily &&
      other.fontSizePt == fontSizePt;

  @override
  int get hashCode => Object.hash(accent, fontFamily, fontSizePt);

  @override
  String toString() =>
      'SystemAppearance(accent: $accent, font: $fontFamily $fontSizePt)';
}
```

- [ ] **Step 4: Run the decoding tests**

Run: `flutter test test/domain/system_appearance_test.dart`
Expected: PASS.

- [ ] **Step 5: Create the channel adapter and provider**

`lib/services/system_appearance_channel.dart`:

```dart
import 'package:flutter/services.dart';

import '../domain/system_appearance.dart';

/// The desktop's accent colour and UI font, as the native runner reports
/// them: once on listen, then on every change. See `appearance_channel.cc`
/// (Linux, from the XDG settings portal) and `AppearanceStreamHandler` in
/// `MainFlutterWindow.swift` (macOS, from `NSColor.controlAccentColor`).
Stream<SystemAppearance> watchSystemAppearance({
  EventChannel channel = const EventChannel('stash_player/appearance'),
}) => channel.receiveBroadcastStream().map(SystemAppearance.fromEvent);
```

In `lib/app/providers.dart`, add imports for `package:flutter/foundation.dart`, `../domain/system_appearance.dart`, `../services/system_appearance_channel.dart`, `../shared/diagnostics.dart`, then:

```dart
/// The desktop's accent colour and UI font. Only the Linux and macOS
/// runners implement the channel; everywhere else (including tests, which
/// run as Android) this is permanently unknown, and the theme uses its
/// built-in defaults. A channel error is logged and otherwise ignored for
/// the same reason.
final systemAppearanceProvider = StreamProvider<SystemAppearance>((ref) {
  if (defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.macOS) {
    return Stream.value(SystemAppearance.none);
  }
  return watchSystemAppearance().handleError(
    (Object error) => logDiagnostic(
      'appearance',
      'using the built-in accent and font: $error',
    ),
  );
});
```

- [ ] **Step 6: Write the failing app-level test**

In `test/app/app_smoke_test.dart`, give `_pumpApp` an `extraOverrides` parameter and append them to the `ProviderScope`'s overrides:

```dart
Future<void> _pumpApp(
  WidgetTester tester, {
  ConnectionConfig saved = const ConnectionConfig(),
  Future<ConnectionConfig>? loadFuture,
  List<Override> extraOverrides = const [],
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      // ...existing overrides unchanged...
      connectionControllerOverride,
      ...extraOverrides,
    ],
    child: const StashPlayerApp(),
  ),
);
```

Add the test inside `main()`:

```dart
  testWidgets('the OS accent recolours the theme', (tester) async {
    await _pumpApp(
      tester,
      extraOverrides: [
        systemAppearanceProvider.overrideWith(
          (ref) => Stream.value(
            const SystemAppearance(accent: Color(0xFFE66100)),
          ),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    final theme = Theme.of(tester.element(find.text('Connect to Stash')));
    expect(theme.colorScheme.primary, const Color(0xFFE66100));
  });
```

Add `import 'package:stash_player_flutter/domain/system_appearance.dart';`.

Run: `flutter test test/app/app_smoke_test.dart`
Expected: the new test FAILS (primary is still `#3584E4`).

- [ ] **Step 7: Feed the appearance into the theme in `lib/app/app.dart`**

In `build`, before `return MaterialApp(`:

```dart
    final appearance =
        ref.watch(systemAppearanceProvider).valueOrNull ??
        SystemAppearance.none;
    ThemeData themeFor(Brightness brightness) => buildAppTheme(
      brightness,
      accent: appearance.accent,
      fontFamily: appearance.fontFamily,
      bodyFontPt: appearance.fontSizePt,
    );
```

and use `theme: themeFor(Brightness.light), darkTheme: themeFor(Brightness.dark),`. Import `../domain/system_appearance.dart` and `providers.dart`.

Run: `flutter test test/app/app_smoke_test.dart`
Expected: PASS.

- [ ] **Step 8: Linux: create `linux/runner/appearance_channel.h`**

```cpp
#ifndef RUNNER_APPEARANCE_CHANNEL_H_
#define RUNNER_APPEARANCE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Streams the desktop's accent colour and UI font to Dart on
// `stash_player/appearance`, read from the XDG settings portal
// (org.freedesktop.appearance accent-color, org.gnome.desktop.interface
// font-name). The portal is reachable from inside the Flatpak sandbox
// without any extra permission.
typedef struct _AppearanceChannel AppearanceChannel;

AppearanceChannel* appearance_channel_new(FlBinaryMessenger* messenger);
void appearance_channel_free(AppearanceChannel* self);

#endif  // RUNNER_APPEARANCE_CHANNEL_H_
```

- [ ] **Step 9: Linux: create `linux/runner/appearance_channel.cc`**

```cpp
#include "appearance_channel.h"

#include <gio/gio.h>

struct _AppearanceChannel {
  FlEventChannel* channel;
  GDBusProxy* portal;
  GCancellable* cancellable;
  gboolean listening;
  // ARGB, or -1 while unknown or unset.
  gint64 accent;
  gchar* font_name;
};

static const gchar* kAppearanceNamespace = "org.freedesktop.appearance";
static const gchar* kInterfaceNamespace = "org.gnome.desktop.interface";

static void send_state(AppearanceChannel* self) {
  if (!self->listening) return;
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "accent",
                           self->accent >= 0 ? fl_value_new_int(self->accent)
                                             : fl_value_new_null());
  fl_value_set_string_take(event, "fontName",
                           self->font_name != nullptr
                               ? fl_value_new_string(self->font_name)
                               : fl_value_new_null());
  fl_event_channel_send(self->channel, event, nullptr, nullptr);
}

// The portal reports the accent as an sRGB (ddd) triple in [0, 1]. Any
// component outside that range means "no accent set", per the spec.
static gint64 accent_from_variant(GVariant* value) {
  if (value == nullptr ||
      !g_variant_is_of_type(value, G_VARIANT_TYPE("(ddd)"))) {
    return -1;
  }
  gdouble r, g, b;
  g_variant_get(value, "(ddd)", &r, &g, &b);
  if (r < 0 || r > 1 || g < 0 || g > 1 || b < 0 || b > 1) return -1;
  auto channel = [](gdouble c) { return static_cast<gint64>(c * 255 + 0.5); };
  return (static_cast<gint64>(0xFF) << 24) | (channel(r) << 16) |
         (channel(g) << 8) | channel(b);
}

static void apply_setting(AppearanceChannel* self, const gchar* ns,
                          const gchar* key, GVariant* value) {
  if (g_strcmp0(ns, kAppearanceNamespace) == 0 &&
      g_strcmp0(key, "accent-color") == 0) {
    self->accent = accent_from_variant(value);
    send_state(self);
  } else if (g_strcmp0(ns, kInterfaceNamespace) == 0 &&
             g_strcmp0(key, "font-name") == 0) {
    g_clear_pointer(&self->font_name, g_free);
    if (value != nullptr &&
        g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
      self->font_name = g_variant_dup_string(value, nullptr);
    }
    send_state(self);
  }
}

typedef struct {
  AppearanceChannel* self;
  gchar* ns;
  gchar* key;
} ReadRequest;

static void read_one_cb(GObject* source, GAsyncResult* result,
                        gpointer user_data) {
  ReadRequest* request = static_cast<ReadRequest*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_proxy_call_finish(G_DBUS_PROXY(source), result, &error);
  // A cancelled call means the channel was freed; `self` is gone.
  if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) &&
      reply != nullptr) {
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    apply_setting(request->self, request->ns, request->key, value);
  }
  g_free(request->ns);
  g_free(request->key);
  g_free(request);
}

static void read_one(AppearanceChannel* self, const gchar* ns,
                     const gchar* key) {
  ReadRequest* request = g_new0(ReadRequest, 1);
  request->self = self;
  request->ns = g_strdup(ns);
  request->key = g_strdup(key);
  g_dbus_proxy_call(self->portal, "ReadOne", g_variant_new("(ss)", ns, key),
                    G_DBUS_CALL_FLAGS_NONE, -1, self->cancellable,
                    read_one_cb, request);
}

static void portal_signal_cb(GDBusProxy* proxy, const gchar* sender,
                             const gchar* signal, GVariant* parameters,
                             gpointer user_data) {
  if (g_strcmp0(signal, "SettingChanged") != 0) return;
  const gchar* ns;
  const gchar* key;
  g_autoptr(GVariant) value = nullptr;
  g_variant_get(parameters, "(&s&sv)", &ns, &key, &value);
  apply_setting(static_cast<AppearanceChannel*>(user_data), ns, key, value);
}

static void portal_ready_cb(GObject* source, GAsyncResult* result,
                            gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  GDBusProxy* portal = g_dbus_proxy_new_for_bus_finish(result, &error);
  if (portal == nullptr) {
    if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
      g_warning("Settings portal unavailable: %s", error->message);
    }
    return;
  }
  AppearanceChannel* self = static_cast<AppearanceChannel*>(user_data);
  self->portal = portal;
  g_signal_connect(portal, "g-signal", G_CALLBACK(portal_signal_cb), self);
  read_one(self, kAppearanceNamespace, "accent-color");
  read_one(self, kInterfaceNamespace, "font-name");
}

static FlMethodErrorResponse* listen_cb(FlEventChannel* channel,
                                        FlValue* args, gpointer user_data) {
  AppearanceChannel* self = static_cast<AppearanceChannel*>(user_data);
  self->listening = TRUE;
  send_state(self);
  return nullptr;
}

static FlMethodErrorResponse* cancel_cb(FlEventChannel* channel,
                                        FlValue* args, gpointer user_data) {
  static_cast<AppearanceChannel*>(user_data)->listening = FALSE;
  return nullptr;
}

AppearanceChannel* appearance_channel_new(FlBinaryMessenger* messenger) {
  AppearanceChannel* self = g_new0(AppearanceChannel, 1);
  self->accent = -1;
  self->cancellable = g_cancellable_new();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_event_channel_new(messenger, "stash_player/appearance",
                                       FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->channel, listen_cb, cancel_cb,
                                       self, nullptr);
  g_dbus_proxy_new_for_bus(
      G_BUS_TYPE_SESSION, G_DBUS_PROXY_FLAGS_NONE, nullptr,
      "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.Settings", self->cancellable, portal_ready_cb,
      self);
  return self;
}

void appearance_channel_free(AppearanceChannel* self) {
  g_cancellable_cancel(self->cancellable);
  g_clear_object(&self->cancellable);
  if (self->portal != nullptr) {
    g_signal_handlers_disconnect_by_data(self->portal, self);
    g_clear_object(&self->portal);
  }
  g_clear_object(&self->channel);
  g_clear_pointer(&self->font_name, g_free);
  g_free(self);
}
```

- [ ] **Step 10: Linux: wire it into the runner**

In `linux/runner/CMakeLists.txt`, add `"appearance_channel.cc"` to `add_executable` after `"my_application.cc"`.

In `linux/runner/my_application.cc`:
- `#include "appearance_channel.h"` after `#include "my_application.h"`.
- Add `AppearanceChannel* appearance_channel;` to `struct _MyApplication`.
- After the `legacy_secret_channel` handler is set, add:
  ```cpp
  self->appearance_channel = appearance_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)));
  ```
- In `my_application_dispose`, before the parent `dispose` call:
  ```cpp
  g_clear_pointer(&self->appearance_channel, appearance_channel_free);
  ```

Run (repo root): `just flutter-build`
Expected: the Linux debug build links with no warnings from the new file.

- [ ] **Step 11: macOS: add the appearance stream to `macos/Runner/MainFlutterWindow.swift`**

Add a stored property to `MainFlutterWindow`:

```swift
  // Retained for the window's lifetime: FlutterEventChannel holds its
  // handler weakly.
  private let appearance = AppearanceStreamHandler()
```

In `awakeFromNib`, after `LegacySecretChannel.register(...)`:

```swift
    FlutterEventChannel(
      name: "stash_player/appearance",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setStreamHandler(appearance)
```

At the end of the file:

```swift
/// Streams the system accent colour on `stash_player/appearance`, once on
/// listen and again whenever the user changes it in System Settings.
/// `fontName` is always nil: the app always uses the system font on macOS.
final class AppearanceStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    send()
    observer = NotificationCenter.default.addObserver(
      forName: NSColor.systemColorsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.send() }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    sink = nil
    return nil
  }

  private func send() {
    guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
      sink?(["accent": NSNull(), "fontName": NSNull()])
      return
    }
    func channel(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
    let argb = (0xFF << 24) | (channel(color.redComponent) << 16)
      | (channel(color.greenComponent) << 8) | channel(color.blueComponent)
    sink?(["accent": argb, "fontName": NSNull()])
  }
}
```

On a Mac, run (repo root): `just flutter-build`
Expected: builds. (On Linux, skip this step's build and note it for the manual gate in Task 8.)

- [ ] **Step 12: Check and commit**

```bash
just flutter-check
git add -A lib test linux macos
git commit -m "feat(flutter): follow the OS accent colour and GNOME UI font"
```

---

### Task 3: Per-dialect icons

**Files:**
- Create: `tool/fetch_icons.py`, `assets/icons/gnome/*.svg` + `COPYING.md`, `assets/icons/lucide/*.svg` + `LICENSE`, `lib/ui/icons/app_icons.dart`, `test/ui/icons/app_icons_test.dart`, `test/ui/no_material_icons_test.dart`, `test/support/app_icons.dart`
- Modify: `pubspec.yaml`, every file listed in Step 8, and the tests listed in Step 9

**Interfaces:**
- Consumes: `PlatformDialect.of(context)` (Task 1).
- Produces:
  - `enum AppIcon` with values `back, dropdown, sortAscending, sortDescending, organizedAny, organizedYes, organizedNo, eye, eyeOff, shuffle, scan, tasks, settings, filters, clock, warning, done, quality, info, volumeMuted, volumeHigh, skipPrevious, skipNext, seekBack10, seekForward10, play, pause, playFilled, oCounter, reset, close, video, emptyLibrary, error, star, search`, each with `String gnome`, `String lucide`, `String? lucideBadge`, and `String assetFor(PlatformDialect)`.
  - `class AppIconView extends StatelessWidget { const AppIconView(AppIcon icon, {double? size, Color? color, String? semanticLabel}); static Color colorOf(BuildContext, Color? explicit); }`.
  - `AppIconToggle.icon`, `AppIconAction.icon` and `PlayerIconButton.icon` change type from `IconData` to `AppIcon`.
  - Test helpers `Finder findAppIcon(AppIcon)` and `Finder findWidgetWithAppIcon(Type, AppIcon)`.

- [ ] **Step 1: Add the dependencies and asset folders**

```bash
flutter pub add flutter_svg
flutter pub add dev:vector_graphics_compiler
```

In `pubspec.yaml`, under `flutter:` (after `uses-material-design: true`), add:

```yaml
  # Per-dialect icon sets; see tool/fetch_icons.py for where they come
  # from and lib/ui/icons/app_icons.dart for how they are picked.
  assets:
    - assets/icons/gnome/
    - assets/icons/lucide/
```

Add a comment above the `vector_graphics_compiler` dev dependency: `# Parses every bundled SVG in app_icons_test.dart, so an icon flutter_svg can't draw fails a test instead of rendering blank.`

- [ ] **Step 2: Create `tool/fetch_icons.py`**

```python
#!/usr/bin/env python3
"""Fetches the app's icons into assets/icons/.

Linux (Adwaita dialect) icons come from GNOME's icon-development-kit, the
CC0 set libadwaita apps draw from; macOS icons come from Lucide (ISC).
Both are pinned. Rerun only when adding an icon to lib/ui/icons/app_icons.dart:

    python3 tool/fetch_icons.py

The GNOME icons are GTK "GPA" SVGs that carry several animation states
in one file, with the inactive states marked visibility="hidden". A
plain SVG renderer would draw every state on top of each other, so each
icon is flattened to one state here: "outline" by default, or the state
named after "@" (e.g. "star@filled").
"""

import pathlib
import urllib.request
import xml.etree.ElementTree as ET

GNOME_COMMIT = "e5857f6d796a96571a61030db40f35bfb8815a94"
GNOME_BASE = (
    "https://gitlab.gnome.org/Teams/Design/icon-development-kit/-/raw/"
    f"{GNOME_COMMIT}"
)
LUCIDE_VERSION = "1.48.0"
LUCIDE_BASE = f"https://cdn.jsdelivr.net/npm/lucide-static@{LUCIDE_VERSION}"

GNOME = [
    "go-previous", "pan-down", "view-sort-ascending", "view-sort-descending",
    "checkbox", "circle-check", "cross", "eye-open", "eye-crossed",
    "media-playlist-shuffle", "folder-plus", "list", "cogged-wheel",
    "sliders", "clock", "dialog-warning", "video-encode", "info-outline",
    "speaker-cross", "speaker-max", "media-skip-backward",
    "media-skip-forward", "arrow-left-10", "arrow-right-10",
    "media-playback-start", "media-playback-pause",
    "media-playback-start@filled", "raindrop", "edit-clear", "video",
    "clapper", "round-exclamation", "star@filled", "loupe",
]
LUCIDE = [
    "arrow-left", "chevron-down", "arrow-up-narrow-wide",
    "arrow-down-wide-narrow", "circle-dashed", "circle-check-big",
    "circle-x", "eye", "eye-off", "shuffle", "folder-plus", "list-checks",
    "settings", "sliders-horizontal", "clock", "triangle-alert",
    "monitor-play", "info", "volume-x", "volume-2", "skip-back",
    "skip-forward", "rotate-ccw", "rotate-cw", "play", "pause",
    "circle-play", "droplet", "delete", "x", "film", "clapperboard",
    "circle-alert", "star", "search",
]

SVG_NS = "http://www.w3.org/2000/svg"
GPA_NS = "https://www.gtk.org/grappa"
ROOT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "icons"


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as response:
        return response.read()


def flatten_gpa(svg: bytes, state: str) -> bytes:
    ET.register_namespace("", SVG_NS)
    root = ET.fromstring(svg)

    def prune(parent: ET.Element) -> None:
        for child in list(parent):
            local = child.tag.split("}")[-1]
            states = child.get(f"{{{GPA_NS}}}states")
            # <defs> may hold paint servers the kept paths reference, so it
            # is never pruned, whatever state it is tagged with.
            if local == "metadata" or (
                local != "defs"
                and states is not None
                and state not in states.split()
            ):
                parent.remove(child)
                continue
            child.attrib.pop("visibility", None)
            for key in [k for k in child.attrib if k.startswith(f"{{{GPA_NS}}}")]:
                del child.attrib[key]
            prune(child)

    prune(root)
    for key in [k for k in root.attrib if k.startswith(f"{{{GPA_NS}}}")]:
        del root.attrib[key]
    root.set("viewBox", root.get("viewBox", "0 0 16 16"))
    return ET.tostring(root, encoding="utf-8")


def main() -> None:
    gnome_dir = ROOT / "gnome"
    lucide_dir = ROOT / "lucide"
    for directory in (gnome_dir, lucide_dir):
        directory.mkdir(parents=True, exist_ok=True)
        for old in directory.glob("*.svg"):
            old.unlink()

    for entry in GNOME:
        name, _, state = entry.partition("@")
        svg = fetch(f"{GNOME_BASE}/icons/{name}.svg")
        out = f"{name}-{state}.svg" if state else f"{name}.svg"
        (gnome_dir / out).write_bytes(flatten_gpa(svg, state or "outline"))
    (gnome_dir / "COPYING.md").write_bytes(fetch(f"{GNOME_BASE}/COPYING.md"))

    for name in LUCIDE:
        (lucide_dir / f"{name}.svg").write_bytes(
            fetch(f"{LUCIDE_BASE}/icons/{name}.svg")
        )
    (lucide_dir / "LICENSE").write_bytes(fetch(f"{LUCIDE_BASE}/LICENSE"))


if __name__ == "__main__":
    main()
```

Run: `python3 tool/fetch_icons.py && ls assets/icons/gnome | wc -l && ls assets/icons/lucide | wc -l`
Expected: `35` and `36` (the SVGs plus one licence file each).

Run: `grep -l 'visibility="hidden"\|gpa:' assets/icons/gnome/*.svg`
Expected: no output.

- [ ] **Step 3: Write the failing icon tests**

`test/ui/icons/app_icons_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/platform_dialect.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart';

void main() {
  group('every icon has a drawable asset in both dialects', () {
    for (final dialect in PlatformDialect.values) {
      for (final icon in AppIcon.values) {
        test('${dialect.name} ${icon.name}', () {
          final file = File(icon.assetFor(dialect));
          expect(file.existsSync(), isTrue, reason: file.path);
          // Throws on anything flutter_svg can't render, which would
          // otherwise show up as a silently blank icon.
          encodeSvg(
            xml: file.readAsStringSync(),
            debugName: file.path,
            warningsAsErrors: true,
            enableClippingOptimizer: false,
            enableMaskingOptimizer: false,
            enableOverdrawOptimizer: false,
          );
        });
      }
    }
  });

  Future<SvgPicture> pumpIcon(
    WidgetTester tester,
    TargetPlatform platform, {
    Color? color,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, platform: platform),
        home: IconTheme(
          data: const IconThemeData(color: Color(0xFF123456), size: 20),
          child: AppIconView(AppIcon.play, color: color),
        ),
      ),
    );
    return tester.widget<SvgPicture>(find.byType(SvgPicture));
  }

  testWidgets('Adwaita draws the GNOME glyph', (tester) async {
    final svg = await pumpIcon(tester, TargetPlatform.linux);
    expect(
      (svg.bytesLoader as SvgAssetLoader).assetName,
      'assets/icons/gnome/media-playback-start.svg',
    );
  });

  testWidgets('macOS draws the Lucide glyph', (tester) async {
    final svg = await pumpIcon(tester, TargetPlatform.macOS);
    expect(
      (svg.bytesLoader as SvgAssetLoader).assetName,
      'assets/icons/lucide/play.svg',
    );
  });

  testWidgets('size and colour default to the ambient IconTheme', (
    tester,
  ) async {
    final svg = await pumpIcon(tester, TargetPlatform.linux);
    expect(svg.width, 20);
    expect(
      svg.colorFilter,
      const ColorFilter.mode(Color(0xFF123456), BlendMode.srcIn),
    );
  });

  testWidgets('an explicit colour wins', (tester) async {
    final svg = await pumpIcon(
      tester,
      TargetPlatform.linux,
      color: const Color(0xFFFF0000),
    );
    expect(
      svg.colorFilter,
      const ColorFilter.mode(Color(0xFFFF0000), BlendMode.srcIn),
    );
  });

  testWidgets('Lucide has no 10s seek glyph, so macOS badges one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, platform: TargetPlatform.macOS),
        home: const AppIconView(AppIcon.seekBack10, size: 24),
      ),
    );
    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('Adwaita has a real 10s glyph and no badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, platform: TargetPlatform.linux),
        home: const AppIconView(AppIcon.seekBack10, size: 24),
      ),
    );
    expect(find.text('10'), findsNothing);
  });
}
```

`test/ui/no_material_icons_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ uses AppIcon, never Material Icons', () {
    final offenders = <String>[];
    final pattern = RegExp(r'\bIcons\.');
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (pattern.hasMatch(line)) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
```

`test/support/app_icons.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';

/// Finds an [AppIconView] showing [icon]; the replacement for
/// `find.byIcon` now that the app draws no Material icons.
Finder findAppIcon(AppIcon icon) =>
    find.byWidgetPredicate((widget) => widget is AppIconView && widget.icon == icon);

/// The replacement for `find.widgetWithIcon`.
Finder findWidgetWithAppIcon(Type type, AppIcon icon) =>
    find.ancestor(of: findAppIcon(icon), matching: find.byType(type));
```

Run: `flutter test test/ui/icons test/ui/no_material_icons_test.dart`
Expected: FAIL (`app_icons.dart` not found; the grep test lists ~60 offenders).

- [ ] **Step 4: Create `lib/ui/icons/app_icons.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/platform_dialect.dart';

/// Every glyph the app draws, named by meaning, each with its GNOME
/// (Adwaita dialect) and Lucide (macOS dialect) source.
///
/// Assets live under `assets/icons/`; `tool/fetch_icons.py` fetches them.
/// Adding a value here means adding its names to that script too, and
/// `app_icons_test.dart` fails until the files exist.
enum AppIcon {
  back('go-previous', 'arrow-left'),
  dropdown('pan-down', 'chevron-down'),
  sortAscending('view-sort-ascending', 'arrow-up-narrow-wide'),
  sortDescending('view-sort-descending', 'arrow-down-wide-narrow'),
  organizedAny('checkbox', 'circle-dashed'),
  organizedYes('circle-check', 'circle-check-big'),
  organizedNo('cross', 'circle-x'),
  eye('eye-open', 'eye'),
  eyeOff('eye-crossed', 'eye-off'),
  shuffle('media-playlist-shuffle', 'shuffle'),
  scan('folder-plus', 'folder-plus'),
  tasks('list', 'list-checks'),
  settings('cogged-wheel', 'settings'),
  filters('sliders', 'sliders-horizontal'),
  clock('clock', 'clock'),
  warning('dialog-warning', 'triangle-alert'),
  done('circle-check', 'circle-check-big'),
  quality('video-encode', 'monitor-play'),
  info('info-outline', 'info'),
  volumeMuted('speaker-cross', 'volume-x'),
  volumeHigh('speaker-max', 'volume-2'),
  skipPrevious('media-skip-backward', 'skip-back'),
  skipNext('media-skip-forward', 'skip-forward'),
  // Lucide has no "seek 10 seconds" glyph; its rotate arrows carry a
  // drawn "10" instead.
  seekBack10('arrow-left-10', 'rotate-ccw', lucideBadge: '10'),
  seekForward10('arrow-right-10', 'rotate-cw', lucideBadge: '10'),
  play('media-playback-start', 'play'),
  pause('media-playback-pause', 'pause'),
  playFilled('media-playback-start-filled', 'circle-play'),
  oCounter('raindrop', 'droplet'),
  reset('edit-clear', 'delete'),
  close('cross', 'x'),
  video('video', 'film'),
  emptyLibrary('clapper', 'clapperboard'),
  error('round-exclamation', 'circle-alert'),
  star('star-filled', 'star'),
  search('loupe', 'search');

  const AppIcon(this.gnome, this.lucide, {this.lucideBadge});

  /// File name (without `.svg`) under `assets/icons/gnome/`.
  final String gnome;

  /// File name (without `.svg`) under `assets/icons/lucide/`.
  final String lucide;

  /// Text drawn inside the Lucide glyph, for meanings Lucide lacks.
  final String? lucideBadge;

  String assetFor(PlatformDialect dialect) => switch (dialect) {
    PlatformDialect.adwaita => 'assets/icons/gnome/$gnome.svg',
    PlatformDialect.macos => 'assets/icons/lucide/$lucide.svg',
  };
}

/// Draws an [AppIcon] in the ambient dialect. Sized and coloured like
/// [Icon]: explicit values win, otherwise the ambient [IconTheme] (so an
/// [IconButton]'s resolved foreground applies), otherwise 16px.
class AppIconView extends StatelessWidget {
  const AppIconView(
    this.icon, {
    this.size,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final AppIcon icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// The colour an [AppIconView] with [explicit] would paint in [context].
  static Color colorOf(BuildContext context, Color? explicit) =>
      explicit ?? IconTheme.of(context).color ?? const Color(0xFF000000);

  @override
  Widget build(BuildContext context) {
    final dialect = PlatformDialect.of(context);
    final extent = size ?? IconTheme.of(context).size ?? 16;
    final paint = colorOf(context, color);
    Widget glyph = SvgPicture.asset(
      icon.assetFor(dialect),
      width: extent,
      height: extent,
      colorFilter: ColorFilter.mode(paint, BlendMode.srcIn),
      excludeFromSemantics: true,
    );
    final badge = icon.lucideBadge;
    if (dialect == PlatformDialect.macos && badge != null) {
      glyph = Stack(
        alignment: Alignment.center,
        children: [
          glyph,
          Text(
            badge,
            style: TextStyle(
              color: paint,
              fontSize: extent * 0.34,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ],
      );
    }
    glyph = SizedBox.square(dimension: extent, child: glyph);
    return semanticLabel == null
        ? glyph
        : Semantics(label: semanticLabel, child: glyph);
  }
}
```

- [ ] **Step 5: Run the icon tests**

Run: `flutter test test/ui/icons`
Expected: PASS. If `encodeSvg` rejects a file, open it, find the unsupported element the warning names, and add a removal for it to `flatten_gpa` (GNOME) or pick a neighbouring Lucide glyph; rerun the fetch script.

- [ ] **Step 6: Change the icon-bearing widgets to take `AppIcon`**

- `lib/ui/widgets/filter_controls.dart`: in `AppIconToggle` and `AppIconAction`, `final IconData icon;` → `final AppIcon icon;`, and each `Icon(icon, size: 16, color: X)` → `AppIconView(icon, size: 16, color: X)`. In `AppMenuButton`, `Icon(Icons.arrow_drop_down, size: 16, color: tokens.textFaint)` → `AppIconView(AppIcon.dropdown, size: 12, color: tokens.textFaint)`. In `AppSearchField`, `prefixIcon: Icon(Icons.search, size: 16, color: tokens.textFaint)` → `prefixIcon: Center(widthFactor: 1, child: AppIconView(AppIcon.search, size: 16, color: tokens.textFaint))`.
- `lib/features/player/player_icon_button.dart`: `final IconData icon;` → `final AppIcon icon;`; the `Icon(` at line 107 becomes `AppIconView(` with the same `size:`/`color:` arguments.

Add `import '../icons/app_icons.dart';` (or the right relative path) wherever `AppIcon` is now used.

- [ ] **Step 7: Replace every `Icons.*` in `lib/`**

| Location | Replacement |
|---|---|
| `features/library/library_toolbar.dart` `Icons.arrow_upward` / `arrow_downward` | `AppIcon.sortAscending` / `AppIcon.sortDescending` |
| same, organized `check_circle_outline` / `check_circle` / `cancel` | `AppIcon.organizedAny` / `organizedYes` / `organizedNo` |
| same, `visibility_off` | `AppIcon.eyeOff` |
| same, `shuffle` | `AppIcon.shuffle` |
| same, `library_add_outlined` | `AppIcon.scan` |
| same, `list_alt` | `AppIcon.tasks` |
| same, `settings_outlined` | `AppIcon.settings` |
| same, `tune` | `AppIcon.filters` |
| `features/library/tasks_popover.dart` `Icon(Icons.schedule, ...)` | `AppIconView(AppIcon.clock, ...)` |
| same, `Icon(Icons.check_circle, ...)` | `AppIconView(AppIcon.done, ...)` |
| same, `Icon(Icons.warning_amber_rounded, ...)` | `AppIconView(AppIcon.warning, ...)` |
| same, `Center(child: Icon(Icons.circle, size: 8, color: c))` | `Center(child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)))` |
| `features/connection/connection_screen.dart:121` `Icons.arrow_back` | `AppIcon.back` |
| same, `Icon(_showApiKey ? Icons.visibility_off : Icons.visibility)` | `AppIconView(_showApiKey ? AppIcon.eyeOff : AppIcon.eye)` |
| `features/player/player_top_bar.dart` `Icons.arrow_back` / `Icons.info_outline` | `AppIcon.back` / `AppIcon.info` |
| same, `Icons.high_quality_outlined` and `Icons.check` inside the `PopupMenuButton` | `AppIconView(AppIcon.quality, color: AppTokens.playerText)` for the button's `icon:`; delete the check `Icon` and its `SizedBox`, leaving `Text(stream.label)` (Task 5 replaces this menu entirely) |
| `features/player/player_bar.dart` volume `Icons.volume_off_rounded` / `volume_up_rounded` | `AppIcon.volumeMuted` / `AppIcon.volumeHigh` |
| same, `skip_previous_rounded`, `replay_10_rounded`, `pause_rounded`, `play_arrow_rounded`, `forward_10_rounded`, `skip_next_rounded` | `skipPrevious`, `seekBack10`, `pause`, `play`, `seekForward10`, `skipNext` |
| same, `Icon(Icons.water_drop_outlined, size: 15, color: glyph)` | `AppIconView(AppIcon.oCounter, size: 15, color: glyph)` |
| same, `Icons.backspace_outlined` | `AppIcon.reset` |
| `features/player/scene_metadata_drawer.dart` `const Icon(Icons.close)` | `const AppIconView(AppIcon.close)` |
| `features/player/scene_screen.dart:823,877` `const Icon(Icons.error_outline, color: Colors.white, size: 40)` | `const AppIconView(AppIcon.error, color: Colors.white, size: 40)` |
| same, `Icon(Icons.error_outline, ...)` at 945 | `AppIconView(AppIcon.error, ...)` (same arguments) |
| `shared/scene_placeholder.dart` `Icon(Icons.movie_outlined, color: c)` | `AppIconView(AppIcon.video, size: 24, color: c)` |
| `ui/widgets/status_views.dart` `Icons.movie_filter_outlined` | `AppIcon.emptyLibrary` (keep size/colour) |
| same, both `Icons.error_outline` | `AppIcon.error` |
| `ui/widgets/scene_tile.dart` resume badge `Icon(Icons.play_circle_fill, size: 20, color: Colors.white, shadows: [Shadow(blurRadius: 4)])` | `DecoratedBox(decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 4)]), child: const AppIconView(AppIcon.playFilled, size: 20, color: Colors.white))` |
| same, `const Icon(Icons.star, size: 12, color: AppTokens.playerText)` | `const AppIconView(AppIcon.star, size: 12, color: AppTokens.playerText)` |

Run: `flutter test test/ui/no_material_icons_test.dart`
Expected: PASS.

- [ ] **Step 8: Migrate the tests that found Material icons**

- `test/ui/widgets/filter_controls_test.dart`: `Icons.visibility_off` → `AppIcon.eyeOff`, `Icons.library_add_outlined` → `AppIcon.scan`, `Icons.shuffle` → `AppIcon.shuffle`, `Icons.list_alt` → `AppIcon.tasks`; import `app_icons.dart`.
- `test/features/library/tasks_popover_test.dart:75-79`: `find.byIcon(Icons.schedule)` → `findAppIcon(AppIcon.clock)`, `Icons.check_circle` → `AppIcon.done`, `Icons.warning_amber_rounded` → `AppIcon.warning`; replace the `find.byIcon(Icons.circle)` line with `expect(find.byWidgetPredicate((w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 8, height: 8)), findsOneWidget);`.
- `test/features/library/library_screen_test.dart:1243,1314`: `find.widgetWithIcon(AppIconAction, Icons.library_add_outlined)` → `findWidgetWithAppIcon(AppIconAction, AppIcon.scan)`.
- `test/features/player/scene_metadata_drawer_test.dart`: rewrite `_iconColor`:

```dart
/// The colour an [AppIconView] paints its glyph in, which for an
/// [IconButton] comes from the button's own resolved foreground rather
/// than from the view's `color` field.
Color _iconColor(WidgetTester tester, AppIcon icon) {
  final finder = findAppIcon(icon);
  return AppIconView.colorOf(
    tester.element(finder),
    tester.widget<AppIconView>(finder).color,
  );
}
```

and change its three calls from `Icons.close` to `AppIcon.close`.

Import `../../support/app_icons.dart` where the finders are used.

- [ ] **Step 9: Run everything, check, commit**

```bash
flutter test
just flutter-check
git add -A pubspec.yaml pubspec.lock tool assets lib test
git commit -m "feat(flutter): draw GNOME icons on Linux and Lucide icons on macOS"
```

---

### Task 4: Spinner and toasts

**Files:**
- Create: `lib/ui/widgets/app_spinner.dart`, `lib/ui/widgets/app_toast.dart`, `lib/app/toast_host.dart`, `test/ui/widgets/app_spinner_test.dart`, `test/ui/widgets/app_toast_test.dart`, `test/app/toast_host_test.dart`
- Modify: `lib/ui/widgets/status_views.dart`, `lib/features/library/scene_grid.dart`, `lib/features/library/tasks_popover.dart`, `lib/features/connection/connection_screen.dart`, `lib/features/player/loading_overlay.dart`, `lib/features/player/scene_screen.dart`, `lib/app/app.dart`, `lib/ui/theme/app_theme.dart`, `test/app/app_smoke_test.dart`, and the tests that find `CircularProgressIndicator`

**Interfaces:**
- Consumes: `PlatformDialect.of`, `AppPalette` (Task 1); `globalNoticeProvider`, `AppNotice`, `AppNoticeSeverity` (`lib/app/notices.dart`).
- Produces: `AppSpinner({double size = 16, Color? color})` with `static const Key arcKey`, `static const Key spokesKey`; `AppToast({required String message, Color? background})`; `ToastHost({required Widget child})`.

- [ ] **Step 1: Write the failing spinner test**

`test/ui/widgets/app_spinner_test.dart`:

```dart
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
```

Run: `flutter test test/ui/widgets/app_spinner_test.dart`
Expected: FAIL, file not found.

- [ ] **Step 2: Create `lib/ui/widgets/app_spinner.dart`**

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/platform_dialect.dart';

/// An indeterminate progress indicator in the ambient dialect: libadwaita's
/// rotating arc, or AppKit's twelve fading spokes.
///
/// Coloured like an icon: [color] if given, otherwise the ambient
/// [IconTheme] (so inside a button it takes the button's foreground),
/// otherwise the theme's dimmed text colour.
class AppSpinner extends StatefulWidget {
  const AppSpinner({this.size = 16, this.color, super.key});

  @visibleForTesting
  static const Key arcKey = Key('app-spinner-arc');
  @visibleForTesting
  static const Key spokesKey = Key('app-spinner-spokes');

  final double size;
  final Color? color;

  @override
  State<AppSpinner> createState() => _AppSpinnerState();
}

class _AppSpinnerState extends State<AppSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        key: adwaita ? AppSpinner.arcKey : AppSpinner.spokesKey,
        painter: adwaita
            ? _ArcPainter(_turn, color)
            : _SpokesPainter(_turn, color),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.turn, this.color) : super(repaint: turn);

  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide / 8;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      paint..color = color.withValues(alpha: 0.15),
    );
    canvas.drawArc(
      rect,
      turn.value * 2 * math.pi,
      math.pi * 0.6,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

class _SpokesPainter extends CustomPainter {
  _SpokesPainter(this.turn, this.color) : super(repaint: turn);

  static const _spokes = 12;

  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..strokeWidth = size.shortestSide / 11
      ..strokeCap = StrokeCap.round;
    final lead = (turn.value * _spokes).floor();
    canvas.translate(size.width / 2, size.height / 2);
    for (var i = 0; i < _spokes; i++) {
      // The leading spoke is opaque and each one behind it fades, which
      // is what reads as rotation.
      final age = (lead - i) % _spokes;
      paint.color = color.withValues(alpha: 1 - age / _spokes * 0.85);
      final angle = i * 2 * math.pi / _spokes - math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(direction * radius * 0.45, direction * radius * 0.9, paint);
    }
  }

  @override
  bool shouldRepaint(_SpokesPainter old) => old.color != color;
}
```

Run: `flutter test test/ui/widgets/app_spinner_test.dart`
Expected: PASS.

- [ ] **Step 3: Replace every `CircularProgressIndicator` with `AppSpinner`**

| Location | Replacement |
|---|---|
| `ui/widgets/status_views.dart` `SizedBox(28×28, CircularProgressIndicator(strokeWidth: 2))` | `AppSpinner(size: 28)` (drop the `SizedBox`) |
| `features/library/scene_grid.dart:189` inside a 24×24 `SizedBox` | `AppSpinner(size: 24)` (drop the `SizedBox`) |
| `features/library/tasks_popover.dart:290` `Padding(all 2, CircularProgressIndicator(strokeWidth: 2))` | `Padding(padding: EdgeInsets.all(2), child: AppSpinner(size: 12))` |
| `features/connection/connection_screen.dart:256` in the 18×18 `SizedBox` | `AppSpinner(size: 18)` (the button's foreground colours it) |
| `features/player/loading_overlay.dart:115` 32×32, `color: Colors.white` | `AppSpinner(size: 32, color: Colors.white)` |
| `features/player/scene_screen.dart:809` `CircularProgressIndicator(color: Colors.white)` | `AppSpinner(size: 32, color: Colors.white)` |

The `tasks_popover.dart:252` `LinearProgressIndicator` stays; it already takes the theme accent.

In the tests, replace `find.byType(CircularProgressIndicator)` with `find.byType(AppSpinner)` in `test/ui/widgets/status_views_test.dart:17`, `test/features/connection/connection_screen_test.dart:163`, `test/features/library/library_screen_test.dart:198,243`, `test/features/library/tasks_popover_test.dart:76`, `test/features/player/loading_overlay_test.dart:99,109`, and update the two comments that name `CircularProgressIndicator` (`app_router_test.dart:294`, `library_screen_test.dart:187`) to say `AppSpinner`.

Run: `flutter test`
Expected: PASS.

- [ ] **Step 4: Write the failing toast tests**

`test/ui/widgets/app_toast_test.dart`:

```dart
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
      home: Center(child: AppToast(message: 'Saved', background: background)),
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
    expect(
      AppToast.alignmentFor(TargetPlatform.linux),
      Alignment.bottomCenter,
    );
    expect(AppToast.alignmentFor(TargetPlatform.macOS), Alignment.topCenter);
  });
}
```

Run: `flutter test test/ui/widgets/app_toast_test.dart`
Expected: FAIL, file not found.

- [ ] **Step 5: Create `lib/ui/widgets/app_toast.dart`**

```dart
import 'package:flutter/material.dart';

import '../theme/platform_dialect.dart';

/// A transient notice in the ambient dialect: libadwaita's `AdwToast` (a
/// dark pill near the bottom edge) or a macOS HUD panel near the top.
///
/// [background] overrides the dialect's neutral fill, which is how a
/// severity (error, success) is shown.
class AppToast extends StatelessWidget {
  const AppToast({required this.message, this.background, super.key});

  /// libadwaita's toast fill: the OSD colour, the same in light and dark.
  static const Color adwaitaFill = Color(0xEB242424);

  final String message;
  final Color? background;

  /// Where a host should place the toast inside the window.
  static Alignment alignmentFor(TargetPlatform platform) =>
      PlatformDialect.forPlatform(platform) == PlatformDialect.adwaita
      ? Alignment.bottomCenter
      : Alignment.topCenter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    final dark = theme.brightness == Brightness.dark;
    final fill =
        background ??
        (adwaita
            ? adwaitaFill
            : (dark ? const Color(0xE6323232) : const Color(0xF2F6F6F6)));
    final foreground = background != null || adwaita || dark
        ? const Color(0xFFFFFFFF)
        : theme.colorScheme.onSurface;
    return Material(
      color: fill,
      elevation: adwaita ? 0 : 6,
      shadowColor: const Color(0x66000000),
      shape: adwaita
          ? const StadiumBorder()
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 38, maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
          ),
        ),
      ),
    );
  }
}
```

Run: `flutter test test/ui/widgets/app_toast_test.dart`
Expected: PASS.

- [ ] **Step 6: Update the smoke test to expect a toast**

In `test/app/app_smoke_test.dart`, rename the test to `'a bootstrap-failure notice toast resolves the app theme, not the Material fallback'` and replace its body's SnackBar lookup:

```dart
      expect(find.text('Connect to Stash'), findsOneWidget);
      final toast = tester.widget<AppToast>(find.byType(AppToast));
      final themeContext = tester.element(find.byType(AppToast));
      expect(toast.background, Theme.of(themeContext).colorScheme.error);
      // AppTokens is only registered by this app's real theme, never by
      // the Material fallback ThemeData(), so its presence proves the
      // toast resolved through the app's own Theme.
      expect(Theme.of(themeContext).extension<AppTokens>(), isNotNull);
```

Update the step comments above it from "SnackBar" to "toast". Import `package:stash_player_flutter/ui/widgets/app_toast.dart`.

Run: `flutter test test/app/app_smoke_test.dart`
Expected: that test FAILS (no `AppToast`).

- [ ] **Step 7: Create `lib/app/toast_host.dart`**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/widgets/app_toast.dart';
import 'notices.dart';

/// Shows each [globalNoticeProvider] notice as an [AppToast] over [child]
/// for [duration], replacing whatever toast is already up.
///
/// Mounted from `MaterialApp.builder`, so its context sits under the
/// app's Theme and a toast resolves the app's colours rather than
/// Flutter's fallback ones.
class ToastHost extends ConsumerStatefulWidget {
  const ToastHost({required this.child, super.key});

  static const Duration duration = Duration(seconds: 4);

  final Widget child;

  @override
  ConsumerState<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends ConsumerState<ToastHost> {
  AppNotice? _notice;
  Timer? _dismiss;

  @override
  void dispose() {
    _dismiss?.cancel();
    super.dispose();
  }

  void _show(AppNotice notice) {
    _dismiss?.cancel();
    setState(() => _notice = notice);
    _dismiss = Timer(ToastHost.duration, () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppNotice?>(globalNoticeProvider, (previous, next) {
      if (next == null || next.id == previous?.id) return;
      _show(next);
    });
    final theme = Theme.of(context);
    final notice = _notice;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: AppToast.alignmentFor(theme.platform),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: notice == null
                      ? const SizedBox.shrink()
                      : AppToast(
                          key: ValueKey(notice.id),
                          message: notice.message,
                          background: _colorFor(notice.severity, theme),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Color? _colorFor(AppNoticeSeverity severity, ThemeData theme) =>
      switch (severity) {
        AppNoticeSeverity.error => theme.colorScheme.error,
        AppNoticeSeverity.success => theme.colorScheme.primary,
        AppNoticeSeverity.warning || AppNoticeSeverity.info => null,
      };
}
```

The overlay layer does not block the app underneath: `Align` only reports a hit inside its child, so a pointer anywhere except on the toast itself falls through to `widget.child`. `toast_host_test` below would catch a regression.

Create `test/app/toast_host_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/toast_host.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_toast.dart';

void main() {
  late ProviderContainer container;
  late int taps;

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    taps = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          builder: (context, child) => ToastHost(child: child!),
          home: Scaffold(
            body: SizedBox.expand(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('behind'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows a notice, then dismisses it', (tester) async {
    await pump(tester);
    container
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: 'Reconnected'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Reconnected'), findsOneWidget);

    await tester.pump(ToastHost.duration);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AppToast), findsNothing);
  });

  testWidgets('an error notice is tinted with the theme error colour', (
    tester,
  ) async {
    await pump(tester);
    container
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: 'Failed', severity: AppNoticeSeverity.error));
    await tester.pump();
    final toast = tester.widget<AppToast>(find.byType(AppToast));
    expect(
      toast.background,
      Theme.of(tester.element(find.byType(AppToast))).colorScheme.error,
    );
  });

  testWidgets('the app underneath still takes taps while a toast is up', (
    tester,
  ) async {
    await pump(tester);
    container
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: 'Reconnected'));
    await tester.pump();
    await tester.tapAt(const Offset(20, 300));
    expect(taps, 1);
  });
}
```

Run: `flutter test test/app/toast_host_test.dart`
Expected: PASS.

- [ ] **Step 8: Swap the SnackBar plumbing for the host in `lib/app/app.dart`**

Remove `_scaffoldMessengerKey`, the `ref.listen<AppNotice?>(globalNoticeProvider, ...)` block, `_colorFor`, and `scaffoldMessengerKey:`. Add to the `MaterialApp`:

```dart
      builder: (context, child) => ToastHost(child: child!),
```

Import `toast_host.dart`; drop the now-unused `notices.dart` import if the analyzer flags it. In `lib/ui/theme/app_theme.dart`, delete the `snackBarTheme:` entry. Update the doc comment on `AppNoticeSeverity` in `notices.dart` ("tint the resulting `SnackBar`" → "tint the resulting toast") and on `AppNotice` ("surfaced through the root `ScaffoldMessenger`" → "surfaced by `ToastHost`").

Run: `flutter test`
Expected: PASS.

- [ ] **Step 9: Check and commit**

```bash
just flutter-check
git add -A lib test
git commit -m "feat(flutter): add dialect spinners and toasts"
```

---

### Task 5: Menu spec, drawn renderer, and the two menu call sites

**Files:**
- Create: `lib/ui/menu/app_menu.dart`, `lib/ui/menu/native_menus.dart`, `lib/ui/menu/drawn_menus.dart`, `test/ui/menu/drawn_menus_test.dart`, `test/support/recording_menus.dart`
- Modify: `lib/ui/widgets/filter_controls.dart` (`AppMenuButton`), `lib/features/player/player_top_bar.dart`, `test/ui/widgets/filter_controls_test.dart`, `test/features/player/player_top_bar_test.dart`

**Interfaces:**
- Produces:
  ```dart
  sealed class AppMenuEntry { const AppMenuEntry(); }
  final class AppMenuAction extends AppMenuEntry {
    const AppMenuAction({required String label, required VoidCallback onSelected,
      bool enabled = true, bool? checked, SingleActivator? shortcut});
  }
  final class AppMenuSeparator extends AppMenuEntry { const AppMenuSeparator(); }
  class AppMenu { const AppMenu(List<AppMenuEntry> entries); }
  abstract interface class NativeMenus {
    Future<void> show(BuildContext context, AppMenu menu, Rect anchor);
  }
  class NativeMenusScope extends InheritedWidget { static NativeMenus of(BuildContext); }
  Rect globalRectOf(BuildContext context);
  class DrawnMenus implements NativeMenus { const DrawnMenus(); }
  ```
  `anchor` is in global logical coordinates (the Flutter view's own coordinate space). `show` completes after the menu closes and after the chosen action's `onSelected` has run. `checked: null` means "not a check item". `shortcut` is only used by the macOS menu bar (Task 7).
- The existing `AppMenuItem<T>` in `filter_controls.dart` (value + label for `AppMenuButton`) keeps its name and meaning.

- [ ] **Step 1: Write the failing DrawnMenus tests and the recording fake**

`test/support/recording_menus.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';
import 'package:stash_player_flutter/ui/menu/native_menus.dart';

/// A [NativeMenus] that records what was shown and "selects" the action
/// labelled [choose], if any, the way a native menu would.
class RecordingMenus implements NativeMenus {
  RecordingMenus({this.choose});

  String? choose;
  final List<AppMenu> shown = [];
  final List<Rect> anchors = [];

  @override
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor) async {
    shown.add(menu);
    anchors.add(anchor);
    for (final entry in menu.entries) {
      if (entry is AppMenuAction && entry.label == choose) {
        entry.onSelected();
      }
    }
  }
}
```

`test/ui/menu/drawn_menus_test.dart`:

```dart
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
      AppMenuAction(label: 'One', checked: true, onSelected: () => picked.add('One')),
      const AppMenuSeparator(),
      AppMenuAction(label: 'Two', onSelected: () => picked.add('Two')),
      AppMenuAction(label: 'Off', enabled: false, onSelected: () => picked.add('Off')),
    ]);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => const DrawnMenus().show(
              context,
              menu,
              globalRectOf(context),
            ),
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
```

Run: `flutter test test/ui/menu`
Expected: FAIL, files not found.

- [ ] **Step 2: Create `lib/ui/menu/app_menu.dart`**

```dart
import 'package:flutter/widgets.dart';

/// One row of an [AppMenu].
sealed class AppMenuEntry {
  const AppMenuEntry();
}

/// A command. [checked] null means "not a check item"; true/false shows or
/// hides the platform's check mark.
///
/// [shortcut] is shown and registered only by the macOS menu bar
/// (`platform_menu_adapter.dart`); popup menus ignore it, since nothing
/// the app shows as a popup has a shortcut.
final class AppMenuAction extends AppMenuEntry {
  const AppMenuAction({
    required this.label,
    required this.onSelected,
    this.enabled = true,
    this.checked,
    this.shortcut,
  });

  final String label;
  final VoidCallback onSelected;
  final bool enabled;
  final bool? checked;
  final SingleActivator? shortcut;
}

final class AppMenuSeparator extends AppMenuEntry {
  const AppMenuSeparator();
}

/// A menu described once, in Dart, and drawn by whichever [NativeMenus]
/// renderer is in scope: a real `NSMenu` or `GtkMenu`, or a Material menu
/// in tests.
@immutable
class AppMenu {
  const AppMenu(this.entries);

  final List<AppMenuEntry> entries;
}
```

- [ ] **Step 3: Create `lib/ui/menu/native_menus.dart`**

```dart
import 'package:flutter/widgets.dart';

import 'app_menu.dart';
import 'drawn_menus.dart';

/// Shows an [AppMenu] as a popup.
abstract interface class NativeMenus {
  /// Shows [menu] just below [anchor], in global logical coordinates, and
  /// completes once it has closed, after running the chosen action's
  /// callback (if one was chosen).
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor);
}

/// Provides the app's [NativeMenus] renderer to `lib/ui/` widgets, which
/// cannot reach Riverpod. With no scope (as in most widget tests) the
/// drawn renderer is used.
class NativeMenusScope extends InheritedWidget {
  const NativeMenusScope({
    required this.menus,
    required super.child,
    super.key,
  });

  final NativeMenus menus;

  /// Read from tap handlers, so it registers no dependency.
  static NativeMenus of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NativeMenusScope>()?.menus ??
      const DrawnMenus();

  @override
  bool updateShouldNotify(NativeMenusScope oldWidget) =>
      menus != oldWidget.menus;
}

/// [context]'s render box in global logical coordinates: the anchor a
/// menu opened from that widget should hang below.
Rect globalRectOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}
```

- [ ] **Step 4: Create `lib/ui/menu/drawn_menus.dart`**

```dart
import 'package:flutter/material.dart';

import 'app_menu.dart';
import 'native_menus.dart';

/// Renders an [AppMenu] as a Material popup menu styled by the theme's
/// `popupMenuTheme`. Used by widget tests, on platforms with no native
/// renderer, and as `ChannelNativeMenus`'s fallback.
class DrawnMenus implements NativeMenus {
  const DrawnMenus();

  @override
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = anchor.shift(-overlay.localToGlobal(Offset.zero));
    final position = RelativeRect.fromRect(
      Rect.fromPoints(local.bottomLeft, local.bottomRight),
      Offset.zero & overlay.size,
    );

    final actions = <int, AppMenuAction>{};
    final items = <PopupMenuEntry<int>>[];
    for (final entry in menu.entries) {
      switch (entry) {
        case AppMenuSeparator():
          items.add(const PopupMenuDivider());
        case AppMenuAction():
          final id = actions.length;
          actions[id] = entry;
          items.add(
            PopupMenuItem<int>(
              value: id,
              enabled: entry.enabled,
              height: 32,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: entry.checked == true ? const Text('✓') : null,
                  ),
                  Flexible(child: Text(entry.label)),
                ],
              ),
            ),
          );
      }
    }

    final chosen = await showMenu<int>(
      context: context,
      position: position,
      items: items,
    );
    if (chosen != null) actions[chosen]!.onSelected();
  }
}
```

Run: `flutter test test/ui/menu`
Expected: PASS.

- [ ] **Step 5: Route `AppMenuButton` through the port**

In `lib/ui/widgets/filter_controls.dart`, replace `_open` with:

```dart
  Future<void> _open() => NativeMenusScope.of(context).show(
    context,
    AppMenu([
      for (final item in widget.items)
        AppMenuAction(
          label: item.label,
          checked: item.value == widget.value,
          onSelected: () => widget.onChanged(item.value),
        ),
    ]),
    globalRectOf(context),
  );
```

Update the class doc comment's last paragraph: the menu now opens through `NativeMenusScope` (a native `NSMenu`/`GtkMenu` in the app, a drawn one in tests). Keep the `InkWell` + `FocusNode` rationale, and replace the `showMenu`/`MenuAnchor` sentences with: "A native popup menu takes keyboard focus itself while open, so the strip's Tab order is unaffected." Import `../menu/app_menu.dart` and `../menu/native_menus.dart`.

Add to `test/ui/widgets/filter_controls_test.dart`:

```dart
  testWidgets('AppMenuButton opens a checked menu through the scope', (
    tester,
  ) async {
    final menus = RecordingMenus(choose: 'Two');
    int? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: NativeMenusScope(
          menus: menus,
          child: Scaffold(
            body: AppMenuButton<int>(
              value: 1,
              tooltip: 'Pick',
              onChanged: (value) => chosen = value,
              items: const [
                AppMenuItem(value: 1, label: 'One'),
                AppMenuItem(value: 2, label: 'Two'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(AppMenuButton<int>));
    await tester.pump();

    final actions = menus.shown.single.entries.cast<AppMenuAction>();
    expect(actions.map((a) => (a.label, a.checked)), [
      ('One', true),
      ('Two', false),
    ]);
    expect(chosen, 2);
  });
```

(Import `recording_menus.dart`, `app_menu.dart`, `native_menus.dart`, `app_theme.dart` if missing.)

- [ ] **Step 6: Route the stream picker through the port**

In `lib/features/player/player_top_bar.dart`, replace the whole `PopupMenuButton<SceneStream>(...)` element with:

```dart
              if (streamOptions.length > 1)
                Builder(
                  builder: (anchor) => PlayerIconButton(
                    icon: AppIcon.quality,
                    tooltip: 'Video quality',
                    onPressed: () => _openQualityMenu(anchor),
                  ),
                ),
```

and add to the class:

```dart
  /// The top bar fades on the scene screen's auto-hide timer, so it is
  /// held open ([onMenuOpenChanged]) for as long as the menu is up. The
  /// choice is applied only after the menu has closed, so the bar is
  /// released before the stream switch starts, the same order as before.
  Future<void> _openQualityMenu(BuildContext anchor) async {
    SceneStream? chosen;
    onMenuOpenChanged(true);
    await NativeMenusScope.of(anchor).show(
      anchor,
      AppMenu([
        for (final stream in streamOptions)
          AppMenuAction(
            label: stream.label,
            checked: stream == currentStream,
            onSelected: () => chosen = stream,
          ),
      ]),
      globalRectOf(anchor),
    );
    onMenuOpenChanged(false);
    if (chosen case final stream?) onSelectStream(stream);
  }
```

Import `../../ui/icons/app_icons.dart`, `../../ui/menu/app_menu.dart`, `../../ui/menu/native_menus.dart`.

The four existing stream-menu tests in `test/features/player/player_top_bar_test.dart` run against `DrawnMenus` (no scope) and must pass unchanged. Add one that pins the spec:

```dart
  testWidgets('describes the streams as a checked menu', (tester) async {
    final menus = RecordingMenus(choose: 'HLS');
    SceneStream? chosen;
    final opens = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NativeMenusScope(
          menus: menus,
          child: Scaffold(
            body: PlayerTopBar(
              title: 'A scene',
              metadataOpen: false,
              onBack: () {},
              onToggleMetadata: () {},
              streamOptions: [_direct, _hls],
              currentStream: _direct,
              onSelectStream: (stream) => chosen = stream,
              onMenuOpenChanged: opens.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Video quality'));
    await tester.pump();

    final actions = menus.shown.single.entries.cast<AppMenuAction>();
    expect(actions.map((a) => (a.label, a.checked)), [
      ('Direct stream', true),
      ('HLS', false),
    ]);
    expect(opens, [true, false]);
    expect(chosen, _hls);
  });
```

Run: `flutter test`
Expected: PASS.

- [ ] **Step 7: Check and commit**

```bash
just flutter-check
git add -A lib test
git commit -m "feat(flutter): describe popup menus once as AppMenu specs"
```

---

### Task 6: Native popup menus on macOS and Linux

**Files:**
- Create: `lib/services/channel_native_menus.dart`, `test/services/channel_native_menus_test.dart`, `linux/runner/native_menu_channel.h`, `linux/runner/native_menu_channel.cc`
- Modify: `lib/app/providers.dart`, `lib/app/app.dart`, `linux/runner/CMakeLists.txt`, `linux/runner/my_application.cc`, `macos/Runner/MainFlutterWindow.swift`

**Interfaces:**
- Consumes: `AppMenu`, `AppMenuAction`, `AppMenuSeparator`, `NativeMenus`, `NativeMenusScope`, `DrawnMenus` (Task 5); `logDiagnostic` (`lib/shared/diagnostics.dart`).
- Produces: `class ChannelNativeMenus implements NativeMenus { ChannelNativeMenus({MethodChannel channel, NativeMenus fallback}); }`; `final nativeMenusProvider = Provider<NativeMenus>`.
- Channel contract (`stash_player/menu`, method `show`, standard codec):
  - Arguments: `{"anchor": {"x": double, "y": double, "width": double, "height": double}, "items": [{"type": "action", "id": int, "label": String, "enabled": bool, "checked": bool or null} | {"type": "separator"}]}`. `anchor` is in the Flutter view's logical coordinates, origin top-left.
  - Result: the chosen item's `id`, or null when dismissed. Errors: `bad-args`, `no-window`.

- [ ] **Step 1: Write the failing channel tests**

`test/services/channel_native_menus_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/channel_native_menus.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';

import '../support/recording_menus.dart';

const _channel = MethodChannel('stash_player/menu');

void main() {
  late List<String> picked;
  late AppMenu menu;
  late BuildContext context;

  setUp(() {
    picked = [];
    menu = AppMenu([
      AppMenuAction(label: 'One', checked: true, onSelected: () => picked.add('One')),
      const AppMenuSeparator(),
      AppMenuAction(label: 'Two', enabled: false, onSelected: () => picked.add('Two')),
    ]);
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  void answer(Object? Function(MethodCall call) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => handler(call));

  Future<void> pumpContext(WidgetTester tester) => tester.pumpWidget(
    Builder(
      builder: (c) {
        context = c;
        return const SizedBox();
      },
    ),
  );

  testWidgets('sends the spec and the anchor', (tester) async {
    await pumpContext(tester);
    MethodCall? sent;
    answer((call) {
      sent = call;
      return null;
    });

    await ChannelNativeMenus().show(
      context,
      menu,
      const Rect.fromLTWH(10, 20, 30, 40),
    );

    expect(sent?.method, 'show');
    expect(sent?.arguments, {
      'anchor': {'x': 10.0, 'y': 20.0, 'width': 30.0, 'height': 40.0},
      'items': [
        {'type': 'action', 'id': 0, 'label': 'One', 'enabled': true, 'checked': true},
        {'type': 'separator'},
        {'type': 'action', 'id': 1, 'label': 'Two', 'enabled': false, 'checked': null},
      ],
    });
    expect(picked, isEmpty);
  });

  testWidgets('runs the action whose id comes back', (tester) async {
    await pumpContext(tester);
    answer((_) => 0);
    await ChannelNativeMenus().show(context, menu, Rect.zero);
    expect(picked, ['One']);
  });

  testWidgets('an unknown id runs nothing', (tester) async {
    await pumpContext(tester);
    answer((_) => 7);
    await ChannelNativeMenus().show(context, menu, Rect.zero);
    expect(picked, isEmpty);
  });

  testWidgets('with no native side, falls back to the drawn renderer', (
    tester,
  ) async {
    await pumpContext(tester);
    final fallback = RecordingMenus(choose: 'One');
    await ChannelNativeMenus(fallback: fallback).show(
      context,
      menu,
      Rect.zero,
    );
    expect(fallback.shown, hasLength(1));
    expect(picked, ['One']);
  });

  testWidgets('a native error also falls back', (tester) async {
    await pumpContext(tester);
    answer((_) => throw PlatformException(code: 'no-window'));
    final fallback = RecordingMenus();
    await ChannelNativeMenus(fallback: fallback).show(
      context,
      menu,
      Rect.zero,
    );
    expect(fallback.shown, hasLength(1));
  });
}
```

Run: `flutter test test/services/channel_native_menus_test.dart`
Expected: FAIL, file not found.

- [ ] **Step 2: Create `lib/services/channel_native_menus.dart`**

```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../shared/diagnostics.dart';
import '../ui/menu/app_menu.dart';
import '../ui/menu/drawn_menus.dart';
import '../ui/menu/native_menus.dart';

/// Shows [AppMenu]s as the platform's own popup menus over the
/// `stash_player/menu` channel: an `NSMenu` on macOS
/// (`NativeMenuChannel` in `MainFlutterWindow.swift`) and a `GtkMenu` on
/// Linux (`native_menu_channel.cc`).
///
/// Only labels and state cross the channel. Each action gets an id that
/// is local to one [show] call, and its callback stays here, so a late or
/// stale reply can never run an action from a different menu.
///
/// If the native side is missing or fails, the menu is shown by
/// [fallback] instead and the failure is logged once per session.
class ChannelNativeMenus implements NativeMenus {
  ChannelNativeMenus({
    MethodChannel channel = const MethodChannel('stash_player/menu'),
    NativeMenus fallback = const DrawnMenus(),
  }) : _channel = channel,
       _fallback = fallback;

  final MethodChannel _channel;
  final NativeMenus _fallback;
  bool _loggedFallback = false;

  @override
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor) async {
    final actions = <int, AppMenuAction>{};
    final items = <Map<String, Object?>>[];
    for (final entry in menu.entries) {
      switch (entry) {
        case AppMenuSeparator():
          items.add({'type': 'separator'});
        case AppMenuAction():
          final id = actions.length;
          actions[id] = entry;
          items.add({
            'type': 'action',
            'id': id,
            'label': entry.label,
            'enabled': entry.enabled,
            'checked': entry.checked,
          });
      }
    }

    final int? chosen;
    try {
      chosen = await _channel.invokeMethod<int>('show', {
        'anchor': {
          'x': anchor.left,
          'y': anchor.top,
          'width': anchor.width,
          'height': anchor.height,
        },
        'items': items,
      });
    } on Object catch (error) {
      if (error is! MissingPluginException && error is! PlatformException) {
        rethrow;
      }
      if (!_loggedFallback) {
        _loggedFallback = true;
        logDiagnostic('menus', 'native menus unavailable, drawing: $error');
      }
      if (!context.mounted) return;
      return _fallback.show(context, menu, anchor);
    }
    if (chosen != null) actions[chosen]?.onSelected();
  }
}
```

Run: `flutter test test/services/channel_native_menus_test.dart`
Expected: PASS.

- [ ] **Step 3: Provide it at the app root**

In `lib/app/providers.dart` (imports: `../services/channel_native_menus.dart`, `../ui/menu/drawn_menus.dart`, `../ui/menu/native_menus.dart`):

```dart
/// How popup menus are shown: natively on the two desktop platforms the
/// runners implement the channel for, drawn everywhere else (including
/// tests, which run as Android).
final nativeMenusProvider = Provider<NativeMenus>(
  (ref) => switch (defaultTargetPlatform) {
    TargetPlatform.linux || TargetPlatform.macOS => ChannelNativeMenus(),
    _ => const DrawnMenus(),
  },
);
```

In `lib/app/app.dart`, change the builder to:

```dart
      builder: (context, child) => NativeMenusScope(
        menus: ref.watch(nativeMenusProvider),
        child: ToastHost(child: child!),
      ),
```

Run: `flutter test`
Expected: PASS.

- [ ] **Step 4: macOS: add `NativeMenuChannel` to `MainFlutterWindow.swift`**

Add a stored property to `MainFlutterWindow`:

```swift
  private var nativeMenus: NativeMenuChannel?
```

In `awakeFromNib`, after the appearance channel:

```swift
    nativeMenus = NativeMenuChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      view: flutterViewController.view
    )
```

At the end of the file:

```swift
/// Shows the menus Dart describes on `stash_player/menu` as real `NSMenu`
/// popups, and answers with the chosen item's id (nil when dismissed).
final class NativeMenuChannel: NSObject {
  private weak var view: NSView?
  private var chosen: Int?
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger, view: NSView) {
    self.view = view
    channel = FlutterMethodChannel(name: "stash_player/menu", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    guard call.method == "show" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let view,
      let args = call.arguments as? [String: Any],
      let anchor = args["anchor"] as? [String: Double],
      let items = args["items"] as? [[String: Any]]
    else {
      result(FlutterError(code: "bad-args", message: "show needs anchor and items", details: nil))
      return
    }

    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in items {
      if item["type"] as? String == "separator" {
        menu.addItem(.separator())
        continue
      }
      let entry = NSMenuItem(
        title: item["label"] as? String ?? "",
        action: #selector(select(_:)),
        keyEquivalent: ""
      )
      entry.target = self
      entry.tag = item["id"] as? Int ?? -1
      entry.isEnabled = item["enabled"] as? Bool ?? true
      if let checked = item["checked"] as? Bool {
        entry.state = checked ? .on : .off
      }
      menu.addItem(entry)
    }

    // Flutter's anchor is top-left-origin; AppKit views are usually
    // bottom-left. The menu's top-left corner goes at the anchor's
    // bottom-left.
    let bottom = (anchor["y"] ?? 0) + (anchor["height"] ?? 0)
    let point = NSPoint(
      x: anchor["x"] ?? 0,
      y: view.isFlipped ? bottom : view.bounds.height - bottom
    )
    chosen = nil
    // popUp runs its own tracking loop and only returns once the menu has
    // closed, so `chosen` is final by the next line.
    menu.popUp(positioning: nil, at: point, in: view)
    result(chosen)
  }

  @objc private func select(_ sender: NSMenuItem) {
    chosen = sender.tag
  }
}
```

On a Mac, run (repo root): `just flutter-build`
Expected: builds.

- [ ] **Step 5: Linux: create `linux/runner/native_menu_channel.h`**

```cpp
#ifndef RUNNER_NATIVE_MENU_CHANNEL_H_
#define RUNNER_NATIVE_MENU_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Shows the menus Dart describes on `stash_player/menu` as GtkMenu popups
// anchored in [view], and answers with the chosen item's id (null when
// dismissed). A GtkMenu opens as its own popup surface (an xdg_popup on
// Wayland), so it composes over the Flutter view.
typedef struct _NativeMenuChannel NativeMenuChannel;

NativeMenuChannel* native_menu_channel_new(FlView* view);
void native_menu_channel_free(NativeMenuChannel* self);

#endif  // RUNNER_NATIVE_MENU_CHANNEL_H_
```

- [ ] **Step 6: Linux: create `linux/runner/native_menu_channel.cc`**

```cpp
#include "native_menu_channel.h"

#include <gtk/gtk.h>

struct _NativeMenuChannel {
  FlMethodChannel* channel;
  FlView* view;
};

// One open menu: the pending call it answers and the item chosen so far.
typedef struct {
  FlMethodCall* call;
  GtkWidget* menu;
  gint64 chosen;
  gboolean answered;
} MenuSession;

static const gchar* kIdKey = "stash-player-menu-id";

static gboolean answer_idle(gpointer user_data) {
  MenuSession* session = static_cast<MenuSession*>(user_data);
  g_autoptr(FlValue) value = session->chosen >= 0
                                 ? fl_value_new_int(session->chosen)
                                 : fl_value_new_null();
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(session->call, response, nullptr);
  g_object_unref(session->call);
  gtk_widget_destroy(session->menu);
  g_object_unref(session->menu);
  g_free(session);
  return G_SOURCE_REMOVE;
}

static void item_activate_cb(GtkMenuItem* item, gpointer user_data) {
  static_cast<MenuSession*>(user_data)->chosen =
      GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), kIdKey));
}

// GTK emits the menu's "deactivate" before the chosen item's "activate"
// (gtk_menu_shell_activate_item deactivates first), so the answer is sent
// from an idle callback, after both have run.
static void menu_deactivate_cb(GtkMenuShell* shell, gpointer user_data) {
  MenuSession* session = static_cast<MenuSession*>(user_data);
  if (session->answered) return;
  session->answered = TRUE;
  g_idle_add(answer_idle, session);
}

static void respond_error(FlMethodCall* call, const gchar* code,
                          const gchar* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}

static gdouble lookup_double(FlValue* map, const gchar* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT
             ? fl_value_get_float(value)
             : 0;
}

static GtkWidget* build_item(FlValue* item, MenuSession* session) {
  FlValue* type = fl_value_lookup_string(item, "type");
  if (type != nullptr && g_strcmp0(fl_value_get_string(type), "separator") == 0) {
    return gtk_separator_menu_item_new();
  }
  FlValue* label = fl_value_lookup_string(item, "label");
  const gchar* text = label != nullptr ? fl_value_get_string(label) : "";
  FlValue* checked = fl_value_lookup_string(item, "checked");
  GtkWidget* widget;
  if (checked != nullptr && fl_value_get_type(checked) == FL_VALUE_TYPE_BOOL) {
    widget = gtk_check_menu_item_new_with_label(text);
    // Before "activate" is connected: set_active emits it.
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(widget),
                                   fl_value_get_bool(checked));
  } else {
    widget = gtk_menu_item_new_with_label(text);
  }
  FlValue* enabled = fl_value_lookup_string(item, "enabled");
  gtk_widget_set_sensitive(widget,
                           enabled == nullptr || fl_value_get_bool(enabled));
  FlValue* id = fl_value_lookup_string(item, "id");
  g_object_set_data(G_OBJECT(widget), kIdKey,
                    GINT_TO_POINTER(id != nullptr ? fl_value_get_int(id) : -1));
  g_signal_connect(widget, "activate", G_CALLBACK(item_activate_cb), session);
  return widget;
}

static void show_menu(NativeMenuChannel* self, FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  FlValue* anchor = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                        ? fl_value_lookup_string(args, "anchor")
                        : nullptr;
  FlValue* items = anchor != nullptr ? fl_value_lookup_string(args, "items")
                                     : nullptr;
  if (items == nullptr || fl_value_get_type(items) != FL_VALUE_TYPE_LIST) {
    respond_error(call, "bad-args", "show needs anchor and items");
    return;
  }
  GtkWidget* view = GTK_WIDGET(self->view);
  GdkWindow* window = gtk_widget_get_window(view);
  if (window == nullptr) {
    respond_error(call, "no-window", "the Flutter view is not realized");
    return;
  }

  MenuSession* session = g_new0(MenuSession, 1);
  session->call = FL_METHOD_CALL(g_object_ref(call));
  session->chosen = -1;
  session->menu = GTK_WIDGET(g_object_ref_sink(gtk_menu_new()));
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    GtkWidget* widget = build_item(fl_value_get_list_value(items, i), session);
    gtk_widget_show(widget);
    gtk_menu_shell_append(GTK_MENU_SHELL(session->menu), widget);
  }
  g_signal_connect(session->menu, "deactivate",
                   G_CALLBACK(menu_deactivate_cb), session);
  gtk_menu_attach_to_widget(GTK_MENU(session->menu), view, nullptr);

  // A no-window widget draws into its parent's GdkWindow, where its own
  // origin is its allocation's; a widget with its own window is at 0,0.
  gint origin_x = 0, origin_y = 0;
  if (!gtk_widget_get_has_window(view)) {
    GtkAllocation allocation;
    gtk_widget_get_allocation(view, &allocation);
    origin_x = allocation.x;
    origin_y = allocation.y;
  }
  GdkRectangle rect = {
      origin_x + static_cast<gint>(lookup_double(anchor, "x")),
      origin_y + static_cast<gint>(lookup_double(anchor, "y")),
      MAX(1, static_cast<gint>(lookup_double(anchor, "width"))),
      MAX(1, static_cast<gint>(lookup_double(anchor, "height"))),
  };
  gtk_menu_popup_at_rect(GTK_MENU(session->menu), window, &rect,
                         GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST,
                         nullptr);
}

static void method_cb(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(call), "show") == 0) {
    show_menu(static_cast<NativeMenuChannel*>(user_data), call);
    return;
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}

NativeMenuChannel* native_menu_channel_new(FlView* view) {
  NativeMenuChannel* self = g_new0(NativeMenuChannel, 1);
  self->view = view;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "stash_player/menu", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_cb, self,
                                            nullptr);
  return self;
}

void native_menu_channel_free(NativeMenuChannel* self) {
  g_clear_object(&self->channel);
  g_free(self);
}
```

- [ ] **Step 7: Linux: wire it into the runner**

- `linux/runner/CMakeLists.txt`: add `"native_menu_channel.cc"` to `add_executable`.
- `linux/runner/my_application.cc`: `#include "native_menu_channel.h"`; add `NativeMenuChannel* native_menus;` to `struct _MyApplication`; after the appearance channel is created, `self->native_menus = native_menu_channel_new(view);`; in `my_application_dispose`, `g_clear_pointer(&self->native_menus, native_menu_channel_free);`.

Run (repo root): `just flutter-build && just flutter-run`
Expected: builds and launches. Open the sort dropdown in the library strip and the video-quality menu on a scene with several streams: both appear as GTK menus below their buttons, the current value is checked, choosing an item applies it, Escape or clicking outside dismisses without a change. Repeat with the window moved and resized, and in the player's fullscreen mode.

- [ ] **Step 8: Check and commit**

```bash
just flutter-check
git add -A lib test linux macos
git commit -m "feat(flutter): show popup menus as native NSMenu and GtkMenu"
```

---

### Task 7: The macOS menu bar

**Files:**
- Create: `lib/ui/menu/platform_menu_adapter.dart`, `lib/features/player/playback_menu.dart`, `lib/app/app_menu_bar.dart`, `test/ui/menu/platform_menu_adapter_test.dart`, `test/features/player/playback_menu_test.dart`, `test/app/app_menu_bar_test.dart`
- Modify: `lib/app/app.dart`, `lib/app/providers.dart`, `macos/Runner/MainFlutterWindow.swift`, `macos/Runner/Base.lproj/MainMenu.xib`

**Interfaces:**
- Consumes: `AppMenu`/`AppMenuAction`/`AppMenuSeparator` (Task 5); `PlayerAction`, `PlaybackController.handleAction`, `PlaybackState` (`playing`, `muted`, `fullscreen`), `playerKeyBindings`, `playbackControllerProvider`, `appControllerProvider`, `SceneDestination`.
- Produces:
  - `PlatformMenu toPlatformMenu(String label, AppMenu menu)`.
  - `AppMenu playbackMenu(PlaybackState? state, void Function(PlayerAction) dispatch)` and `AppMenu viewMenu(PlaybackState? state, void Function(PlayerAction) dispatch)`; `state == null` means "not on the scene screen", and every item is then disabled.
  - `List<PlatformMenuItem> buildMacMenuBar({required AppMenu playback, required AppMenu view, required VoidCallback onCheckForUpdates})`.
  - `AppMenuBar({required Widget child})` (a `ConsumerWidget`; renders only `child` off macOS).
  - `final updatesChannelProvider = Provider<MethodChannel>` for `stash_player/updates` (`checkForUpdates`).

- [ ] **Step 1: Write the failing adapter test**

`test/ui/menu/platform_menu_adapter_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';
import 'package:stash_player_flutter/ui/menu/platform_menu_adapter.dart';

void main() {
  test('separators split the menu into groups', () {
    var ran = 0;
    final menu = toPlatformMenu(
      'Playback',
      AppMenu([
        AppMenuAction(
          label: 'Play',
          shortcut: const SingleActivator(LogicalKeyboardKey.space),
          onSelected: () => ran++,
        ),
        const AppMenuSeparator(),
        AppMenuAction(label: 'Mute', onSelected: () {}),
        AppMenuAction(label: 'Off', enabled: false, onSelected: () {}),
      ]),
    );

    expect(menu.label, 'Playback');
    final groups = menu.menus.cast<PlatformMenuItemGroup>();
    expect(groups.map((g) => g.members.length), [1, 2]);

    final play = groups.first.members.single as PlatformMenuItem;
    expect(play.label, 'Play');
    expect(play.shortcut, const SingleActivator(LogicalKeyboardKey.space));
    play.onSelected!();
    expect(ran, 1);

    final off = groups.last.members.last as PlatformMenuItem;
    expect(off.onSelected, isNull);
  });

  test('leading, trailing and doubled separators leave no empty group', () {
    final menu = toPlatformMenu(
      'X',
      AppMenu([
        const AppMenuSeparator(),
        AppMenuAction(label: 'A', onSelected: () {}),
        const AppMenuSeparator(),
        const AppMenuSeparator(),
        AppMenuAction(label: 'B', onSelected: () {}),
        const AppMenuSeparator(),
      ]),
    );
    expect(menu.menus, hasLength(2));
  });
}
```

Run: `flutter test test/ui/menu/platform_menu_adapter_test.dart`
Expected: FAIL, file not found.

- [ ] **Step 2: Create `lib/ui/menu/platform_menu_adapter.dart`**

```dart
import 'package:flutter/widgets.dart';

import 'app_menu.dart';

/// Converts an [AppMenu] into a menu for Flutter's [PlatformMenuBar] (the
/// macOS menu bar). Separators become group boundaries, a disabled action
/// becomes an item with no callback, and [AppMenuAction.shortcut] becomes
/// the item's key equivalent.
///
/// [AppMenuAction.checked] is dropped: [PlatformMenuItem] has no check
/// state. Menu-bar toggles say what they will do instead ("Mute" /
/// "Unmute"), which is also the macOS convention for them.
PlatformMenu toPlatformMenu(String label, AppMenu menu) {
  final groups = <List<PlatformMenuItem>>[[]];
  for (final entry in menu.entries) {
    switch (entry) {
      case AppMenuSeparator():
        if (groups.last.isNotEmpty) groups.add([]);
      case AppMenuAction():
        groups.last.add(
          PlatformMenuItem(
            label: entry.label,
            shortcut: entry.shortcut,
            onSelected: entry.enabled ? entry.onSelected : null,
          ),
        );
    }
  }
  return PlatformMenu(
    label: label,
    menus: [
      for (final group in groups)
        if (group.isNotEmpty) PlatformMenuItemGroup(members: group),
    ],
  );
}
```

Run: `flutter test test/ui/menu/platform_menu_adapter_test.dart`
Expected: PASS.

- [ ] **Step 3: Write the failing playback-menu test**

`test/features/player/playback_menu_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_menu.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/features/player/player_shortcuts.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';

Iterable<AppMenuAction> _actions(AppMenu menu) =>
    menu.entries.whereType<AppMenuAction>();

void main() {
  test('every shortcut a menu shows is the key bound to what it does', () {
    final dispatched = <PlayerAction>[];
    for (final menu in [
      playbackMenu(const PlaybackState(), dispatched.add),
      viewMenu(const PlaybackState(), dispatched.add),
    ]) {
      for (final action in _actions(menu)) {
        final shortcut = action.shortcut;
        if (shortcut == null) continue;
        dispatched.clear();
        action.onSelected();
        expect(
          playerKeyBindings[shortcut.trigger],
          dispatched.single,
          reason: action.label,
        );
        expect(shortcut.meta || shortcut.control || shortcut.alt, isFalse);
      }
    }
  });

  test('labels follow state', () {
    String label(AppMenu menu, int index) =>
        _actions(menu).elementAt(index).label;
    void noop(PlayerAction _) {}

    expect(label(playbackMenu(const PlaybackState(), noop), 0), 'Play');
    expect(
      label(playbackMenu(const PlaybackState(playing: true), noop), 0),
      'Pause',
    );
    expect(
      _actions(playbackMenu(const PlaybackState(muted: true), noop))
          .any((a) => a.label == 'Unmute'),
      isTrue,
    );
    expect(
      label(viewMenu(const PlaybackState(fullscreen: true), noop), 0),
      'Exit Full Screen',
    );
  });

  test('off the scene screen everything is disabled', () {
    void noop(PlayerAction _) {}
    for (final menu in [playbackMenu(null, noop), viewMenu(null, noop)]) {
      expect(_actions(menu).every((a) => !a.enabled), isTrue);
    }
  });
}
```

Run: `flutter test test/features/player/playback_menu_test.dart`
Expected: FAIL, file not found.

- [ ] **Step 4: Create `lib/features/player/playback_menu.dart`**

```dart
import 'package:flutter/widgets.dart';

import '../../ui/menu/app_menu.dart';
import 'playback_controller.dart';
import 'playback_state.dart';
import 'player_shortcuts.dart';

/// The macOS menu bar's Playback menu. [state] is null off the scene
/// screen, where every item is disabled.
///
/// Each item's shortcut is looked up from [playerKeyBindings], the one
/// source of truth for player keys, so the menu can never show a key that
/// does something else. The key itself is still handled by the scene
/// screen's own `Shortcuts`: Flutter sees a key before AppKit's menu does,
/// so the menu's key equivalent only fires for a key Flutter left
/// unhandled.
AppMenu playbackMenu(
  PlaybackState? state,
  void Function(PlayerAction) dispatch,
) {
  AppMenuAction item(String label, PlayerAction action) => AppMenuAction(
    label: label,
    enabled: state != null,
    shortcut: _shortcutFor(action),
    onSelected: () => dispatch(action),
  );

  return AppMenu([
    item(state?.playing ?? false ? 'Pause' : 'Play', PlayerAction.togglePlayPause),
    const AppMenuSeparator(),
    item('Back 5 Seconds', PlayerAction.seekBackward5),
    item('Forward 5 Seconds', PlayerAction.seekForward5),
    item('Back 10 Seconds', PlayerAction.seekBackward10),
    item('Forward 10 Seconds', PlayerAction.seekForward10),
    item('Back 1 Minute', PlayerAction.seekBackward60),
    item('Forward 1 Minute', PlayerAction.seekForward60),
    item('Go to Start', PlayerAction.seekToStart),
    item('Go to End', PlayerAction.seekToEnd),
    const AppMenuSeparator(),
    item('Volume Up', PlayerAction.volumeUp),
    item('Volume Down', PlayerAction.volumeDown),
    item(state?.muted ?? false ? 'Unmute' : 'Mute', PlayerAction.toggleMute),
  ]);
}

/// The macOS menu bar's View menu.
AppMenu viewMenu(PlaybackState? state, void Function(PlayerAction) dispatch) =>
    AppMenu([
      AppMenuAction(
        label: state?.fullscreen ?? false ? 'Exit Full Screen' : 'Enter Full Screen',
        enabled: state != null,
        shortcut: _shortcutFor(PlayerAction.toggleFullscreen),
        onSelected: () => dispatch(PlayerAction.toggleFullscreen),
      ),
    ]);

SingleActivator? _shortcutFor(PlayerAction action) {
  for (final MapEntry(:key, :value) in playerKeyBindings.entries) {
    if (value == action) return SingleActivator(key);
  }
  return null;
}
```

Run: `flutter test test/features/player/playback_menu_test.dart`
Expected: PASS. (`PlaybackState`'s constructor takes `playing`, `muted`, `fullscreen` as named parameters with defaults; if the test's `const PlaybackState(...)` does not compile, check `playback_state.dart` for required parameters and pass the minimum.)

- [ ] **Step 5: Write the failing menu-bar test**

`test/app/app_menu_bar_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_menu_bar.dart';
import 'package:stash_player_flutter/features/player/playback_menu.dart';

void main() {
  test('the bar is app, Edit, Playback, View, Window, in that order', () {
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      view: viewMenu(null, (_) {}),
      onCheckForUpdates: () {},
    );
    expect(bar.cast<PlatformMenu>().map((m) => m.label), [
      'Stash Player',
      'Edit',
      'Playback',
      'View',
      'Window',
    ]);
  });

  test('the app menu checks for updates', () {
    var checked = 0;
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      view: viewMenu(null, (_) {}),
      onCheckForUpdates: () => checked++,
    );
    final app = bar.first as PlatformMenu;
    final item = app.menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .whereType<PlatformMenuItem>()
        .singleWhere((item) => item.label == 'Check for Updates…');
    item.onSelected!();
    expect(checked, 1);
  });

  test('Edit carries the standard key equivalents', () {
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      view: viewMenu(null, (_) {}),
      onCheckForUpdates: () {},
    );
    final edit = bar[1] as PlatformMenu;
    final shortcuts = edit.menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .cast<PlatformMenuItem>()
        .map((item) => (item.shortcut! as SingleActivator).trigger);
    expect(shortcuts, [
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyA,
    ]);
  });
}
```

Run: `flutter test test/app/app_menu_bar_test.dart`
Expected: FAIL, file not found.

- [ ] **Step 6: Create `lib/app/app_menu_bar.dart`**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/player/playback_controller.dart';
import '../features/player/playback_menu.dart';
import '../ui/menu/app_menu.dart';
import '../ui/menu/platform_menu_adapter.dart';
import '../shared/diagnostics.dart';
import 'app_controller.dart';
import 'providers.dart';

/// The macOS menu bar. Everywhere else this is just [child]: Linux apps
/// following GNOME's conventions have no menu bar.
///
/// Playback and View items act on the scene screen's playback controller
/// and are disabled on every other screen.
class AppMenuBar extends ConsumerWidget {
  const AppMenuBar({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;

    final onScene = ref.watch(appControllerProvider) is SceneDestination;
    // Only watched on the scene screen: the controller is created lazily,
    // the first time a scene loads, and the menu bar must not be what
    // creates it.
    final controller = onScene ? ref.watch(playbackControllerProvider) : null;
    final state = controller?.state;
    void dispatch(PlayerAction action) {
      if (controller == null) return;
      unawaited(
        controller
            .handleAction(action)
            .catchError((Object _, StackTrace _) {}),
      );
    }

    return PlatformMenuBar(
      menus: buildMacMenuBar(
        playback: playbackMenu(state, dispatch),
        view: viewMenu(state, dispatch),
        onCheckForUpdates: () => unawaited(
          ref
              .read(updatesChannelProvider)
              .invokeMethod<void>('checkForUpdates')
              .catchError(
                (Object error) => logDiagnostic('updates', '$error'),
              ),
        ),
      ),
      child: child,
    );
  }
}

/// The whole menu bar, as data. `PlatformMenuBar` replaces the menu bar
/// `MainMenu.xib` loads, so everything the app menu needs is listed here,
/// including Sparkle's "Check for Updates…", which reaches the native side
/// over `stash_player/updates`.
List<PlatformMenuItem> buildMacMenuBar({
  required AppMenu playback,
  required AppMenu view,
  required VoidCallback onCheckForUpdates,
}) => [
  PlatformMenu(
    label: 'Stash Player',
    menus: [
      PlatformMenuItemGroup(
        members: [
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
          PlatformMenuItem(
            label: 'Check for Updates…',
            onSelected: onCheckForUpdates,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.servicesSubmenu,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.hideOtherApplications,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.showAllApplications,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ],
      ),
    ],
  ),
  PlatformMenu(
    label: 'Edit',
    menus: [
      PlatformMenuItemGroup(
        members: [
          _editItem(
            'Cut',
            LogicalKeyboardKey.keyX,
            const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          _editItem(
            'Copy',
            LogicalKeyboardKey.keyC,
            CopySelectionTextIntent.copy,
          ),
          _editItem(
            'Paste',
            LogicalKeyboardKey.keyV,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          _editItem(
            'Select All',
            LogicalKeyboardKey.keyA,
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
        ],
      ),
    ],
  ),
  toPlatformMenu('Playback', playback),
  toPlatformMenu('View', view),
  const PlatformMenu(
    label: 'Window',
    menus: [
      PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.minimizeWindow,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.zoomWindow,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ),
    ],
  ),
];

/// An Edit item that runs [intent] on whatever has focus: the same intent
/// the focused text field's own ⌘ shortcut would run. When Flutter handles
/// the key itself (a focused text field), AppKit never sees it, so the
/// item only fires from a mouse click or when nothing in Flutter wanted
/// the key.
PlatformMenuItem _editItem(
  String label,
  LogicalKeyboardKey key,
  Intent intent,
) => PlatformMenuItem(
  label: label,
  shortcut: SingleActivator(key, meta: true),
  onSelected: () {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null) Actions.maybeInvoke(focused, intent);
  },
);
```

In `lib/app/providers.dart` (import `package:flutter/services.dart`):

```dart
/// Asks the macOS runner to run Sparkle's "Check for Updates…" (see
/// `UpdatesChannel` in `MainFlutterWindow.swift`).
final updatesChannelProvider = Provider<MethodChannel>(
  (ref) => const MethodChannel('stash_player/updates'),
);
```

Run: `flutter test test/app/app_menu_bar_test.dart`
Expected: PASS.

- [ ] **Step 7: Mount the bar**

In `lib/app/app.dart`, wrap the returned `MaterialApp` in `AppMenuBar(child: MaterialApp(...))` and import `app_menu_bar.dart`.

Add a widget test to `test/app/app_menu_bar_test.dart` proving the bar is only mounted on macOS:

```dart
  testWidgets('only macOS gets a PlatformMenuBar', (tester) async {
    final sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.menu, (call) async {
          sent.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, null),
    );

    await tester.pumpWidget(
      const ProviderScope(child: AppMenuBar(child: SizedBox())),
    );
    expect(find.byType(PlatformMenuBar), findsNothing);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      const ProviderScope(child: AppMenuBar(child: SizedBox(key: Key('x')))),
    );
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
```

(Imports: `package:flutter/foundation.dart`, `package:flutter/material.dart`, `package:flutter_riverpod/flutter_riverpod.dart`.)

Run: `flutter test`
Expected: PASS.

- [ ] **Step 8: macOS: add the updates channel and trim `MainMenu.xib`**

In `MainFlutterWindow.swift`, in `awakeFromNib` after the native menu channel:

```swift
    UpdatesChannel.register(with: flutterViewController.engine.binaryMessenger)
```

and at the end of the file:

```swift
/// Runs Sparkle's "Check for Updates…" when the Dart menu bar asks, over
/// `stash_player/updates`. The menu bar itself is built in Dart
/// (`app_menu_bar.dart`), which replaces the one MainMenu.xib loads.
enum UpdatesChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "stash_player/updates", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "checkForUpdates" else {
        result(FlutterMethodNotImplemented)
        return
      }
      (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
      result(nil)
    }
  }
}
```

Update the comment on `AppDelegate.checkForUpdates` ("Target of the \"Check for Updates…\" item in MainMenu.xib…") to: "Called by `UpdatesChannel` when the Dart menu bar's \"Check for Updates…\" item is chosen."

Trim the xib to the app menu only (Flutter replaces the bar at startup; the xib's copy only shows for the first frame, and its template Edit/View/Window/Help items and the unwired Preferences… should not be what flashes):

```bash
python3 - <<'EOF'
import pathlib
path = pathlib.Path("macos/Runner/Base.lproj/MainMenu.xib")
lines = path.read_text().splitlines(keepends=True)
start = next(i for i, l in enumerate(lines) if 'id="5QF-Oa-p0T"' in l)  # Edit
end = next(i for i in range(start, len(lines)) if lines[i].strip() == "</items>")
del lines[start:end]
lines = [l for l in lines if 'id="BOF-NM-1cW"' not in l and 'id="wFC-TO-SCJ"' not in l]  # Preferences… + its separator
path.write_text("".join(lines))
EOF
xmllint --noout macos/Runner/Base.lproj/MainMenu.xib
grep -c '<menuItem title=' macos/Runner/Base.lproj/MainMenu.xib
```

Expected: `xmllint` prints nothing; the count is `8`: the top-level "Stash Player" item plus its About, Check for Updates…, Services, Hide, Hide Others, Show All and Quit.

On a Mac, run (repo root): `just flutter-build && just flutter-launch`
Expected: the menu bar shows Stash Player, Edit, Playback, View, Window. On the library screen Playback/View items are disabled. On a scene, Playback → Pause pauses, Mute ↔ Unmute toggles and relabels, View → Enter Full Screen works, and each item shows its key (Space, ←, →, J, L, ↓, ↑, Home, End, 0, 9, M, F). Pressing Space in the player toggles once (not twice). Typing in the connection screen's fields still inserts spaces and letters. ⌘C/⌘V in a field copy and paste once. Stash Player → Check for Updates… opens Sparkle.

- [ ] **Step 9: Check and commit**

```bash
just flutter-check
git add -A lib test macos
git commit -m "feat(flutter): build the macOS menu bar from the same menu specs"
```

---

### Task 8: Docs and manual gates

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `apps/flutter/README.md`, `docs/superpowers/specs/2026-09-24-native-look-and-feel-design.md`

- [ ] **Step 1: Update `CLAUDE.md`'s Flutter architecture section**

- In the `lib/` bullet list, add after `lib/services/`:
  - **`lib/ui/`** — the drawn widget layer, per `PlatformDialect` (`adwaita` | `macos`, from `Theme.of(context).platform`): `theme/` (palettes, type scale, component themes, `buildAppTheme`), `icons/` (`AppIcon` → GNOME icon-development-kit SVGs on Linux, Lucide on macOS, fetched by `tool/fetch_icons.py`), `menu/` (`AppMenu` specs; `NativeMenus` shows them natively via `ChannelNativeMenus`, drawn in tests), `widgets/` (strip controls, spinner, toast, tile). `lib/ui/` never imports Riverpod.
- In the "Native runners" bullet, add: the runners also implement `stash_player/menu` (`NSMenu` / `GtkMenu` popups; `native_menu_channel.cc` on Linux), `stash_player/appearance` (OS accent colour, plus GNOME's UI font via the settings portal; `appearance_channel.cc`), and on macOS `stash_player/updates` (Sparkle). The macOS menu bar is built in Dart (`lib/app/app_menu_bar.dart`) and replaces `MainMenu.xib`'s at startup.

- [ ] **Step 2: Attribution**

Add to the end of `README.md` (and the same sentence to `apps/flutter/README.md`):

```markdown
Icons: GNOME's [icon-development-kit](https://gitlab.gnome.org/Teams/Design/icon-development-kit) (CC0-1.0) on Linux and [Lucide](https://lucide.dev) (ISC) on macOS; licence texts ship in `apps/flutter/assets/icons/`.
```

- [ ] **Step 3: Record the manual gates in the spec**

Append to the spec's §5 a "Manual gate results" checklist with the Task 6 Step 7 and Task 7 Step 8 checks plus: on GNOME (Flatpak, `nix run .#flatpak`) changing the accent in Settings → Appearance recolours the running app, and changing the interface font changes its text; on macOS changing the accent in System Settings recolours it live. Leave the boxes unticked for whoever runs them.

- [ ] **Step 4: Check and commit**

```bash
just flutter-check
git add CLAUDE.md README.md apps/flutter/README.md docs/superpowers/specs/2026-09-24-native-look-and-feel-design.md
git commit -m "docs: describe the dialect layer, native menus and icon sources"
```
