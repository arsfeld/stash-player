import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// The app's top strip: the row carrying a screen's controls, in place of
/// an `AppBar`.
///
/// On macOS the window's titlebar is transparent and the Flutter view
/// draws underneath it, so this strip *is* the titlebar. Two things follow,
/// and both are derived from `Theme.of(context).platform` rather than
/// `Platform.isMacOS` so a widget test can pin either layout:
///
/// - A leading inset clears the traffic lights.
/// - The control band is pinned to the top. The system centres the lights
///   in a 28pt band at the very top of the window, so a 28px band pinned
///   to the top puts our controls on the same centre line as the lights.
///   Centring the band in the full 44px strip instead would sit them
///   visibly lower than the lights.
///
/// Every control placed in [children] should be built to
/// [AppTokens.controlBandHeight]; the band does not resize to fit.
///
/// The children are laid out in a plain [Row] with no overflow
/// protection, deliberately: the strip cannot know which of them should
/// give way when the window is narrow. Any child whose intrinsic width
/// grows with its content (a title, a search field) must therefore
/// arrive already wrapped in [Flexible] or [Expanded] and carry its own
/// `overflow` behaviour, or the strip will render a `RenderFlex
/// overflowed` at a width the rest of the app supports. The library
/// toolbar flexes its search field; the connection screen flexes its
/// title.
class AppWindowChrome extends StatelessWidget {
  const AppWindowChrome({required this.children, super.key});

  final List<Widget> children;

  /// Horizontal space reserved before the first child.
  static double leadingInsetFor(TargetPlatform platform) =>
      platform == TargetPlatform.macOS
      ? AppTokens.trafficLightInset
      : AppTokens.stripInset;

  /// Where the control band sits within the strip.
  static Alignment alignmentFor(TargetPlatform platform) =>
      platform == TargetPlatform.macOS ? Alignment.topCenter : Alignment.center;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SizedBox(
        height: AppTokens.stripHeight,
        child: Align(
          alignment: alignmentFor(theme.platform),
          child: Padding(
            padding: EdgeInsets.only(
              left: leadingInsetFor(theme.platform),
              right: AppTokens.stripInset,
            ),
            child: SizedBox(
              height: AppTokens.controlBandHeight,
              child: Row(children: children),
            ),
          ),
        ),
      ),
    );
  }
}
