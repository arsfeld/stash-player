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
/// - The strip is taller, because `MainFlutterWindow` gives the window an
///   empty unified toolbar and AppKit re-centres the lights in the taller
///   titlebar that produces. The control band is centred in the strip on
///   every platform; on macOS that lands it on the lights' own centre
///   line (see [AppTokens.macOSStripHeight]) *and* leaves it padding above
///   and below. An earlier version pinned the band to the very top of a
///   44px strip, which was the only way to meet the lights while they
///   still sat in a 28pt titlebar, and it left every control touching the
///   window's top edge.
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

  /// The strip's total height. Taller on macOS, where it has a titlebar's
  /// worth of traffic lights to sit around.
  static double stripHeightFor(TargetPlatform platform) =>
      platform == TargetPlatform.macOS
      ? AppTokens.macOSStripHeight
      : AppTokens.stripHeight;

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
        height: stripHeightFor(theme.platform),
        child: Align(
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
