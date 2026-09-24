import 'package:flutter/widgets.dart';

/// One row of an [AppMenu].
sealed class AppMenuEntry {
  const AppMenuEntry();
}

/// A command. [checked] null means "not a check item"; true/false shows or
/// hides the platform's check mark.
///
/// [shortcut] is shown and registered only by the macOS menu bar
/// (`platform_menu_adapter.dart`); popup menus ignore it, since nothing
/// the app shows as a popup has a shortcut.
final class AppMenuAction extends AppMenuEntry {
  const AppMenuAction({
    required this.label,
    required this.onSelected,
    this.enabled = true,
    this.checked,
    this.shortcut,
  });

  final String label;
  final VoidCallback onSelected;
  final bool enabled;
  final bool? checked;
  final SingleActivator? shortcut;
}

final class AppMenuSeparator extends AppMenuEntry {
  const AppMenuSeparator();
}

/// A menu described once, in Dart, and drawn by whichever [NativeMenus]
/// renderer is in scope: a real `NSMenu` or `GtkMenu`, or a Material menu
/// in tests.
@immutable
class AppMenu {
  const AppMenu(this.entries);

  final List<AppMenuEntry> entries;
}
