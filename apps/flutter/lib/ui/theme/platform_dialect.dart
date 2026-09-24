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
