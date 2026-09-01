import 'package:flutter/material.dart';

/// Design values Material's [ThemeData] has no slot for.
///
/// Metrics and player colours are static consts: they never vary. Only
/// the four control/text colours are instance fields, because those are
/// the ones that differ between light and dark, and reading them through
/// `Theme.of(context).extension<AppTokens>()` is what makes a widget
/// brightness-correct without asking about brightness.
///
/// Player chrome sits over video and stays dark in both themes, which is
/// why its colours are consts here rather than fields.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.controlSurface,
    required this.controlHover,
    required this.controlActive,
    required this.textFaint,
  });

  // Spacing scale.
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 24;
  static const double space6 = 32;

  // Corner radii.
  static const double radiusControl = 7;
  static const double radiusPanel = 10;
  static const double radiusPlayerBar = 13;

  /// The top strip's total height, and the control band inside it. The
  /// band is 28 because that is the height of the macOS system titlebar
  /// the traffic lights are centred in. See [AppWindowChrome].
  static const double stripHeight = 44;
  static const double controlBandHeight = 28;

  /// Horizontal space reserved before the strip's first control: enough
  /// to clear the macOS traffic lights, or ordinary padding elsewhere.
  static const double trafficLightInset = 78;
  static const double stripInset = space3;

  static const double sceneTileMaxWidth = 280;
  static const double drawerMaxWidth = 420;

  static const Duration hoverDuration = Duration(milliseconds: 120);
  static const Duration controlsFadeDuration = Duration(milliseconds: 200);
  static const Duration drawerDuration = Duration(milliseconds: 220);

  // Player chrome, always dark.
  static const Color playerPanel = Color(0xCC16181C);
  static const Color playerHairline = Color(0x1CFFFFFF);
  static const Color playerControl = Color(0x21FFFFFF);
  static const Color playerText = Color(0xFFFFFFFF);
  static const Color playerTextDim = Color(0xD1FFFFFF);
  static const Color playerTrack = Color(0x42FFFFFF);

  final Color controlSurface;
  final Color controlHover;
  final Color controlActive;
  final Color textFaint;

  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>()!;

  @override
  AppTokens copyWith({
    Color? controlSurface,
    Color? controlHover,
    Color? controlActive,
    Color? textFaint,
  }) => AppTokens(
    controlSurface: controlSurface ?? this.controlSurface,
    controlHover: controlHover ?? this.controlHover,
    controlActive: controlActive ?? this.controlActive,
    textFaint: textFaint ?? this.textFaint,
  );

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      controlSurface: Color.lerp(controlSurface, other.controlSurface, t)!,
      controlHover: Color.lerp(controlHover, other.controlHover, t)!,
      controlActive: Color.lerp(controlActive, other.controlActive, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
    );
  }
}
