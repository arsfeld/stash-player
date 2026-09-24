import 'package:flutter/widgets.dart';

import 'app_toolbar.dart';

/// Shows an [AppToolbar] as the window's own toolbar.
abstract interface class NativeToolbar {
  /// Replaces the toolbar's items with [toolbar]. [AppToolbar.empty]
  /// leaves the bare titlebar.
  ///
  /// Completes with false when the native side is unavailable; the caller
  /// then draws its own controls instead.
  Future<bool> set(AppToolbar toolbar);
}

/// Provides the app's [NativeToolbar] to `lib/ui/` and feature widgets
/// without Riverpod. With no scope (Linux, and most widget tests)
/// [maybeOf] is null and the toolbar is drawn in Flutter.
class NativeToolbarScope extends InheritedWidget {
  const NativeToolbarScope({
    required this.toolbar,
    required super.child,
    super.key,
  });

  final NativeToolbar toolbar;

  /// Registers no dependency: the scope is fixed for the app's lifetime.
  static NativeToolbar? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NativeToolbarScope>()?.toolbar;

  @override
  bool updateShouldNotify(NativeToolbarScope oldWidget) =>
      toolbar != oldWidget.toolbar;
}
