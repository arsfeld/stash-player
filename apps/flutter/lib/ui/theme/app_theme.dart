import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// Every colour the app uses.
///
/// Neutral greys with a single blue accent, used only for focus rings,
/// active toggles and primary buttons. The accent is the GNOME blue the
/// GTK client already uses, which also sits close enough to the macOS
/// default accent that one value looks at home on both platforms.
abstract final class AppPalette {
  static const Color accent = Color(0xFF3584E4);
  static const Color onAccent = Color(0xFFFFFFFF);

  static const Color darkBackground = Color(0xFF131416);
  static const Color darkChrome = Color(0xFF1A1B1E);
  static const Color darkControl = Color(0xFF26272B);
  static const Color darkControlHover = Color(0xFF303236);
  static const Color darkControlActive = Color(0xFF3A3C41);
  static const Color darkOutline = Color(0xFF2E3033);
  static const Color darkText = Color(0xFFE8E9EA);
  static const Color darkTextDim = Color(0xFF9A9CA1);
  static const Color darkTextFaint = Color(0xFF75777C);
  static const Color darkError = Color(0xFFF2777A);
  static const Color onDarkError = Color(0xFF1A1B1E);

  static const Color lightBackground = Color(0xFFFAFAFA);
  static const Color lightChrome = Color(0xFFFFFFFF);
  static const Color lightControl = Color(0xFFEDEEF0);
  static const Color lightControlHover = Color(0xFFE4E6E8);
  static const Color lightControlActive = Color(0xFFD9DBDE);
  static const Color lightOutline = Color(0xFFE2E4E7);
  static const Color lightText = Color(0xFF1A1B1E);
  static const Color lightTextDim = Color(0xFF5F6368);
  static const Color lightTextFaint = Color(0xFF8A8D91);
  static const Color lightError = Color(0xFFB3261E);
  static const Color onLightError = Color(0xFFFFFFFF);
}

/// Builds the app's theme for [brightness].
///
/// Component themes are set for every Material surface the app does not
/// hand-build (inputs, popup menus, snackbars, chips, sliders, scrollbars,
/// buttons) so those still match the hand-built ones. `CardTheme` is
/// deliberately absent: no screen uses `Card` any more.
ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;

  final background = dark
      ? AppPalette.darkBackground
      : AppPalette.lightBackground;
  final chrome = dark ? AppPalette.darkChrome : AppPalette.lightChrome;
  final control = dark ? AppPalette.darkControl : AppPalette.lightControl;
  final controlHover = dark
      ? AppPalette.darkControlHover
      : AppPalette.lightControlHover;
  final controlActive = dark
      ? AppPalette.darkControlActive
      : AppPalette.lightControlActive;
  final outline = dark ? AppPalette.darkOutline : AppPalette.lightOutline;
  final text = dark ? AppPalette.darkText : AppPalette.lightText;
  final textDim = dark ? AppPalette.darkTextDim : AppPalette.lightTextDim;
  final textFaint = dark ? AppPalette.darkTextFaint : AppPalette.lightTextFaint;
  final error = dark ? AppPalette.darkError : AppPalette.lightError;
  final onError = dark ? AppPalette.onDarkError : AppPalette.onLightError;

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: AppPalette.accent,
    onPrimary: AppPalette.onAccent,
    secondary: AppPalette.accent,
    onSecondary: AppPalette.onAccent,
    error: error,
    onError: onError,
    surface: background,
    onSurface: text,
    onSurfaceVariant: textDim,
    surfaceContainer: chrome,
    surfaceContainerHigh: control,
    surfaceContainerHighest: controlActive,
    outline: outline,
    outlineVariant: outline,
  );

  final textTheme = const TextTheme(
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    titleSmall: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
    bodyMedium: TextStyle(fontSize: 13),
    bodySmall: TextStyle(fontSize: 12),
    labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    labelSmall: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.7,
    ),
  ).apply(bodyColor: text, displayColor: text);

  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppTokens.radiusControl),
  );
  final panelShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppTokens.radiusPanel),
  );
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppTokens.radiusControl),
    borderSide: BorderSide.none,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    textTheme: textTheme,
    extensions: [
      AppTokens(
        controlSurface: control,
        controlHover: controlHover,
        controlActive: controlActive,
        textFaint: textFaint,
      ),
    ],
    dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: control,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space3,
        vertical: AppTokens.space2,
      ),
      hintStyle: textTheme.labelMedium?.copyWith(color: textFaint),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusControl),
        borderSide: const BorderSide(color: AppPalette.accent, width: 2),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: chrome,
      surfaceTintColor: Colors.transparent,
      shape: panelShape,
      textStyle: textTheme.labelMedium?.copyWith(color: text),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: chrome,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: text),
      shape: panelShape,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: control,
      side: BorderSide.none,
      labelStyle: textTheme.labelMedium?.copyWith(color: text),
      shape: const StadiumBorder(),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(textFaint.withValues(alpha: 0.5)),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AppPalette.accent,
      inactiveTrackColor: control,
      thumbColor: AppPalette.accent,
      trackHeight: 4,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppPalette.accent,
        foregroundColor: AppPalette.onAccent,
        textStyle: textTheme.labelMedium,
        shape: controlShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppPalette.accent,
        textStyle: textTheme.labelMedium,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: BorderSide(color: outline),
        textStyle: textTheme.labelMedium,
        shape: controlShape,
      ),
    ),
  );
}
