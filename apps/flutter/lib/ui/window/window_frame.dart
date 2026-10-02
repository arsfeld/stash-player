import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The width the platform's own window buttons take at each end of the
/// view's top edge while they are drawn over it, in logical pixels.
@immutable
class WindowButtonInsets {
  const WindowButtonInsets({this.leading = 0, this.trailing = 0});

  static const zero = WindowButtonInsets();

  final double leading;
  final double trailing;

  bool get isZero => leading == 0 && trailing == 0;

  @override
  bool operator ==(Object other) =>
      other is WindowButtonInsets &&
      other.leading == leading &&
      other.trailing == trailing;

  @override
  int get hashCode => Object.hash(leading, trailing);

  @override
  String toString() => 'WindowButtonInsets($leading, $trailing)';
}

/// The window's own chrome, where the platform lets the app hide its
/// titlebar and draw the window buttons over the content (Linux; see
/// `window_channel.cc`).
abstract interface class WindowFrame {
  /// True hides the titlebar so the view fills the window, with the
  /// window buttons drawn over its top edge. False restores it.
  Future<void> setImmersive(bool immersive);

  /// Shows or hides the overlaid window buttons. Only has an effect
  /// while immersive.
  Future<void> setControlsVisible(bool visible);

  /// Starts moving the window with the pointer. Call while a mouse
  /// button is held.
  Future<void> startDrag();

  /// Zero unless immersive.
  ValueListenable<WindowButtonInsets> get insets;

  /// Whether the pointer is over an overlaid window button.
  ValueListenable<bool> get controlsHovered;
}

/// Provides the app's [WindowFrame] to `lib/ui/` and feature widgets
/// without Riverpod. With no scope (macOS, and most widget tests)
/// [maybeOf] is null.
class WindowFrameScope extends InheritedWidget {
  const WindowFrameScope({
    required this.frame,
    required super.child,
    super.key,
  });

  final WindowFrame frame;

  /// Registers no dependency: the scope is fixed for the app's lifetime.
  static WindowFrame? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WindowFrameScope>()?.frame;

  @override
  bool updateShouldNotify(WindowFrameScope oldWidget) =>
      frame != oldWidget.frame;
}
