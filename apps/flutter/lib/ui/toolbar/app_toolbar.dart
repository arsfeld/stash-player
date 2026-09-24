import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Rect;

import '../icons/app_icons.dart';

/// One item in an [AppToolbar]: what a window toolbar shows, described
/// once in Dart and built by the platform (an `NSToolbar` on macOS; see
/// `NativeToolbarChannel.swift`).
///
/// [id] must be stable across rebuilds. The native side reconciles by it,
/// so an item whose id and kind are unchanged is updated in place rather
/// than recreated. [label] names the item for accessibility and the
/// overflow menu; [tooltip] defaults to it.
@immutable
sealed class AppToolbarItem {
  const AppToolbarItem({required this.id, required this.label, this.tooltip});

  final String id;
  final String label;
  final String? tooltip;
}

/// A pop-up of [options], the one at [selected] checked and shown as the
/// item's title.
final class AppToolbarMenu extends AppToolbarItem {
  const AppToolbarMenu({
    required super.id,
    required super.label,
    required this.options,
    required this.selected,
    required this.onSelected,
    super.tooltip,
  });

  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelected;
}

/// An icon button that shows an on/off state.
final class AppToolbarToggle extends AppToolbarItem {
  const AppToolbarToggle({
    required super.id,
    required super.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    super.tooltip,
  });

  final AppIcon icon;
  final bool selected;
  final VoidCallback onPressed;
}

/// An icon button that performs an action. A null [onPressed] disables
/// it.
///
/// [onPressed] gets the item's frame in the Flutter view's logical
/// coordinates (top-left origin), for anchoring a drawn popover under
/// it, or null when the item was chosen some other way (from the
/// overflow menu, or with the keyboard). [badge] marks it as having
/// something waiting behind it.
final class AppToolbarAction extends AppToolbarItem {
  const AppToolbarAction({
    required super.id,
    required super.label,
    required this.icon,
    required this.onPressed,
    this.badge = false,
    super.tooltip,
  });

  final AppIcon icon;
  final void Function(Rect? anchor)? onPressed;
  final bool badge;
}

/// A search field. [text] is applied to the native field only while the
/// user isn't editing it, so a republish can't overwrite a newer
/// keystroke.
final class AppToolbarSearch extends AppToolbarItem {
  const AppToolbarSearch({
    required super.id,
    required super.label,
    required this.text,
    required this.onChanged,
    this.placeholder = '',
    super.tooltip,
  });

  final String text;
  final String placeholder;
  final ValueChanged<String> onChanged;
}

/// Menus, toggles and actions drawn as one control group (one capsule on
/// macOS 26 and later).
final class AppToolbarGroup extends AppToolbarItem {
  AppToolbarGroup({
    required super.id,
    required super.label,
    required this.children,
    super.tooltip,
  }) : assert(
         children.every(
           (child) =>
               child is AppToolbarMenu ||
               child is AppToolbarToggle ||
               child is AppToolbarAction,
         ),
         'a group holds only menus, toggles and actions',
       );

  final List<AppToolbarItem> children;
}

/// Space that grows to push the items after it to the trailing edge.
final class AppToolbarSpace extends AppToolbarItem {
  const AppToolbarSpace({super.id = 'flexible-space'}) : super(label: '');
}

/// A window toolbar's items, leading to trailing.
@immutable
class AppToolbar {
  const AppToolbar(this.items);

  /// No items: the titlebar alone.
  static const empty = AppToolbar([]);

  final List<AppToolbarItem> items;
}
