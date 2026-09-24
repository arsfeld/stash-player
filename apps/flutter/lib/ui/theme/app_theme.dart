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

  final family = adwaita
      ? (fontFamily ?? 'Adwaita Sans')
      : '.AppleSystemUIFont';
  final fallbackFamilies = adwaita
      ? const ['Cantarell', 'Inter', 'sans-serif']
      : const <String>[];
  // GNOME's font-name portal setting is free text and has been observed
  // reporting nonsensical sizes; clamp to a sane desktop UI-font range so
  // a bad value can't blow up the type scale (or collapse it to nothing)
  // instead of just looking a little off.
  final clampedBodyFontPt = bodyFontPt?.clamp(8, 20).toDouble();
  final textTheme = _textTheme(
    dialect,
    bodyFontPt: clampedBodyFontPt,
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
        titleMedium: TextStyle(
          fontSize: body * 1.1,
          fontWeight: FontWeight.w700,
        ),
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
