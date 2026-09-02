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
  /// band is 28 because that is the height a compact control reads well
  /// at; the strip is what surrounds it with padding. See
  /// [AppWindowChrome].
  static const double stripHeight = 44;
  static const double controlBandHeight = 28;

  /// The strip's height on macOS, where it doubles as the window's
  /// titlebar.
  ///
  /// `MainFlutterWindow` gives the window an empty toolbar in the unified
  /// style, which makes AppKit treat the titlebar as a taller band and
  /// re-centre the traffic lights inside it. Measured from a screenshot
  /// of that window rather than derived from a published constant, since
  /// AppKit publishes none: the lights occupy rows 19 to 32, so their
  /// centre line is 25.5. A 28px band centred in 52 puts our controls at
  /// 26, half a pixel off the lights and with 12px of clearance above and
  /// below.
  ///
  /// If this ever drifts, re-measure rather than nudging it: the whole
  /// point is that the number describes where the system actually draws
  /// the lights.
  static const double macOSStripHeight = 52;

  /// Horizontal space reserved before the strip's first control.
  ///
  /// On macOS the traffic lights end at x=78 (measured the same way as
  /// [macOSStripHeight]), so the first control clears them by the same
  /// [stripInset] every other edge of the strip uses. Butting it up
  /// against 78 exactly, which is what this was, left the lights and the
  /// first control visibly touching.
  static const double trafficLightInset = 78 + stripInset;
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

  /// The [AppTokens] registered on the ambient theme.
  ///
  /// Asserts rather than letting the bare null check speak for itself: a
  /// missing extension surfaces as "Null check operator used on a null
  /// value" pointing into this file, which says nothing about the cause
  /// or the fix and has already cost several people the time to work it
  /// out from scratch.
  static AppTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>();
    assert(
      tokens != null,
      'No AppTokens in the ambient Theme. Widgets under lib/ui/ need a '
      'theme built by buildAppTheme(); a bare MaterialApp or ThemeData() '
      'does not register the extension.',
    );
    return tokens!;
  }

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
