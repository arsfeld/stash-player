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
