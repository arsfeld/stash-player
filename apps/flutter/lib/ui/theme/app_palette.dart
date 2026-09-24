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
