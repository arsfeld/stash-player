import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';
import '../theme/platform_dialect.dart';
import 'app_spinner.dart';

/// One of an [AppDialog]'s two buttons. A null [onPressed] disables it.
@immutable
class AppDialogAction {
  const AppDialogAction({
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Shows a spinner in place of [label] and stops the button, and Enter,
  /// from firing. Only meaningful on the confirm action.
  final bool busy;
}

/// A modal dialog drawn in the platform's shape: libadwaita's dialog (a
/// card with a header bar holding Cancel, the title and the suggested
/// action) or an AppKit sheet (title, body, then Cancel and the default
/// button bottom-right).
///
/// Escape runs [cancel] and Enter runs [confirm] on both. While [cancel]
/// is disabled the dialog can't be dismissed at all, barrier included, so
/// a caller can hold it open while work it can't abandon is in flight.
///
/// Shown through an [AppDialogPage], which supplies the barrier and the
/// per-dialect transition.
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    required this.cancel,
    required this.confirm,
    required this.child,
    super.key,
  });

  static const Key cancelKey = Key('app-dialog-cancel');
  static const Key confirmKey = Key('app-dialog-confirm');
  static const double maxWidth = 460;

  final String title;
  final AppDialogAction cancel;
  final AppDialogAction confirm;
  final Widget child;

  void _confirm() {
    if (!confirm.busy) confirm.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    return PopScope(
      canPop: cancel.onPressed != null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              cancel.onPressed?.call(),
          const SingleActivator(LogicalKeyboardKey.enter): _confirm,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _confirm,
        },
        // Key events travel up from the focused node, and a freshly pushed
        // route focuses its own scope, which sits above these bindings.
        // Taking focus here puts them on the path from the start.
        child: Focus(
          autofocus: true,
          child: adwaita ? _adwaita(context) : _macos(context),
        ),
      ),
    );
  }

  Widget _adwaita(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: _surface(
            context,
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 46,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space2,
                    ),
                    // NavigationToolbar centres the title on the bar itself,
                    // not on the space the two buttons leave, which is how
                    // a GTK header bar lays out its title.
                    child: NavigationToolbar(
                      leading: TextButton(
                        key: cancelKey,
                        onPressed: cancel.onPressed,
                        child: Text(cancel.label),
                      ),
                      middle: _title(theme),
                      trailing: _confirmButton(),
                      middleSpacing: AppTokens.space3,
                    ),
                  ),
                ),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppTokens.space5),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _macos(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        // A sheet hangs from the bottom of the titlebar, which on macOS is
        // the app's own strip.
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space5,
          AppTokens.macOSStripHeight,
          AppTokens.space5,
          AppTokens.space5,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: _surface(
            context,
            Padding(
              padding: const EdgeInsets.all(AppTokens.space5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _title(theme),
                  const SizedBox(height: AppTokens.space4),
                  Flexible(child: SingleChildScrollView(child: child)),
                  const SizedBox(height: AppTokens.space5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        key: cancelKey,
                        onPressed: cancel.onPressed,
                        child: Text(cancel.label),
                      ),
                      const SizedBox(width: AppTokens.space2),
                      _confirmButton(),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _surface(BuildContext context, Widget content) => Material(
    color: Theme.of(context).colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: const Color(0x80000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.of(context).radiusPanel),
    ),
    clipBehavior: Clip.antiAlias,
    child: content,
  );

  Widget _title(ThemeData theme) => Text(
    title,
    textAlign: TextAlign.center,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
  );

  Widget _confirmButton() => FilledButton(
    key: confirmKey,
    onPressed: confirm.busy ? null : confirm.onPressed,
    child: confirm.busy ? const AppSpinner(size: 16) : Text(confirm.label),
  );
}

/// Shows an [AppDialog] as a page in a declarative `Navigator.pages` list.
///
/// Adwaita fades and slightly scales the card in, and clicking the dimmed
/// window dismisses it. macOS slides a sheet down from the titlebar, and
/// clicking outside does nothing, as with an AppKit sheet.
class AppDialogPage<T> extends Page<T> {
  const AppDialogPage({required this.child, super.key, super.name});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) {
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    return RawDialogRoute<T>(
      settings: this,
      barrierDismissible: adwaita,
      barrierColor: const Color(0x52000000),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => child,
      transitionBuilder: adwaita ? _fadeScale : _slideDown,
    );
  }
}

Widget _fadeScale(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.95, end: 1).animate(curved),
      child: child,
    ),
  );
}

Widget _slideDown(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) => SlideTransition(
  position: Tween<Offset>(
    begin: const Offset(0, -0.3),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
  child: FadeTransition(opacity: animation, child: child),
);
