import 'package:flutter/widgets.dart';

import 'app_menu.dart';
import 'drawn_menus.dart';

/// Shows an [AppMenu] as a popup.
abstract interface class NativeMenus {
  /// Shows [menu] just below [anchor], in global logical coordinates, and
  /// completes once it has closed, after running the chosen action's
  /// callback (if one was chosen).
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor);
}

/// Provides the app's [NativeMenus] renderer to `lib/ui/` widgets, which
/// cannot reach Riverpod. With no scope (as in most widget tests) the
/// drawn renderer is used.
class NativeMenusScope extends InheritedWidget {
  const NativeMenusScope({
    required this.menus,
    required super.child,
    super.key,
  });

  final NativeMenus menus;

  /// Read from tap handlers, so it registers no dependency.
  static NativeMenus of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NativeMenusScope>()?.menus ??
      const DrawnMenus();

  @override
  bool updateShouldNotify(NativeMenusScope oldWidget) =>
      menus != oldWidget.menus;
}

/// [context]'s render box in global logical coordinates: the anchor a
/// menu opened from that widget should hang below.
Rect globalRectOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}
