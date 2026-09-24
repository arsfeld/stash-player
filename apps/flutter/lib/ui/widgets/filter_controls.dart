import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../menu/app_menu.dart';
import '../menu/native_menus.dart';
import '../theme/app_tokens.dart';

/// One entry in an [AppMenuButton]'s value list.
@immutable
class AppMenuItem<T> {
  const AppMenuItem({required this.value, required this.label});

  final T value;
  final String label;
}

/// A compact strip control showing the current selection and a caret,
/// opening its value list as a modal menu route.
///
/// [T] is deliberately non-nullable. Both `PopupMenuButton` and [showMenu]
/// report a `null` selection as a dismissal rather than a choice, so a
/// nullable "none" entry could never be picked. Callers that model "none"
/// as `null` (minimum rating) pass a sentinel value and map it back at the
/// callback boundary.
///
/// Built on [InkWell] rather than `PopupMenuButton` so the caller can
/// supply its own [FocusNode]: the library toolbar pins an explicit Tab
/// order across controls that move between rows, which needs a node per
/// control. The menu itself opens through [NativeMenusScope] (a native
/// `NSMenu`/`GtkMenu` in the app, a drawn one in tests). A native popup
/// menu takes keyboard focus itself while open, so the strip's Tab order
/// is unaffected.
class AppMenuButton<T extends Object> extends StatefulWidget {
  const AppMenuButton({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.tooltip,
    this.focusNode,
    super.key,
  });

  final T value;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onChanged;
  final String tooltip;
  final FocusNode? focusNode;

  @override
  State<AppMenuButton<T>> createState() => _AppMenuButtonState<T>();
}

class _AppMenuButtonState<T extends Object> extends State<AppMenuButton<T>> {
  Future<void> _open() => NativeMenusScope.of(context).show(
    context,
    AppMenu([
      for (final item in widget.items)
        AppMenuAction(
          label: item.label,
          checked: item.value == widget.value,
          onSelected: () => widget.onChanged(item.value),
        ),
    ]),
    globalRectOf(context),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTokens.of(context);
    final label = widget.items
        .firstWhere(
          (item) => item.value == widget.value,
          orElse: () => widget.items.first,
        )
        .label;

    return Tooltip(
      message: widget.tooltip,
      child: Container(
        height: AppTokens.controlBandHeight,
        decoration: BoxDecoration(
          color: tokens.controlSurface,
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
        // A Material of its own, *between* the fill and the InkWell. An
        // ink feature paints immediately above the Material hosting it
        // and beneath the rest of that Material's subtree, so a control
        // whose opaque background sits under its InkWell buries every
        // splash and highlight it produces. The nearest Material here
        // used to be the Scaffold's, two layers down, which left the
        // whole strip inert under the pointer.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            focusNode: widget.focusNode,
            onTap: _open,
            hoverColor: tokens.controlHover,
            highlightColor: tokens.controlActive,
            splashColor: tokens.controlActive,
            borderRadius: BorderRadius.circular(tokens.radiusControl),
            // Padding inside the InkWell, not on the fill above it, so
            // hover and press cover the control's whole box.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTokens.space3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: theme.textTheme.labelMedium),
                  const SizedBox(width: AppTokens.space1),
                  AppIconView(
                    AppIcon.dropdown,
                    size: 12,
                    color: tokens.textFaint,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A square icon control with an on and an off state, filled with the
/// accent when on.
///
/// [tooltip] and [semanticLabel] are both required and both asserted
/// non-empty. An icon with no label is only an acceptable control if it
/// always carries those two, so this is enforced at the constructor rather
/// than left to review.
class AppIconToggle extends StatelessWidget {
  const AppIconToggle({
    required this.icon,
    required this.tooltip,
    required this.semanticLabel,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    super.key,
  }) : assert(tooltip != '', 'an icon-only control needs a tooltip'),
       assert(
         semanticLabel != '',
         'an icon-only control needs a semantics label',
       );

  final AppIcon icon;
  final String tooltip;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AppTokens.of(context);

    // Semantics wraps Tooltip, not the other way around: Tooltip builds its
    // own semantics boundary (an OverlayPortal ancestor carrying just the
    // tooltip message), and a boundary above our node is one `find.byType`
    // plus `getSemantics` can never see, since that lookup only climbs
    // toward the root. Semantics on the outside keeps everything, this
    // node's label and toggled state plus Tooltip's own message, merged
    // into the one node a caller resolves by widget type.
    return Semantics(
      button: true,
      toggled: selected,
      label: semanticLabel,
      child: Tooltip(
        message: tooltip,
        child: AnimatedContainer(
          duration: AppTokens.hoverDuration,
          width: AppTokens.controlBandHeight + 2,
          height: AppTokens.controlBandHeight,
          decoration: BoxDecoration(
            color: selected ? scheme.primary : tokens.controlSurface,
            borderRadius: BorderRadius.circular(tokens.radiusControl),
          ),
          // See the matching note in AppMenuButton.build: this Material
          // has to sit between the fill and the InkWell for ink to be
          // visible at all.
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              focusNode: focusNode,
              onTap: onPressed,
              // The palette names a hovered and a pressed value for the
              // control surface but none for the accent, so a selected
              // control gets what Material gives any filled button
              // instead: a wash of its own foreground colour. Both
              // composite over the fill above, which is why the
              // unselected pair can be the opaque tokens verbatim.
              hoverColor: selected
                  ? scheme.onPrimary.withValues(alpha: 0.12)
                  : tokens.controlHover,
              highlightColor: selected
                  ? scheme.onPrimary.withValues(alpha: 0.2)
                  : tokens.controlActive,
              splashColor: selected
                  ? scheme.onPrimary.withValues(alpha: 0.2)
                  : tokens.controlActive,
              borderRadius: BorderRadius.circular(tokens.radiusControl),
              child: Center(
                child: AppIconView(
                  icon,
                  size: 16,
                  color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A square icon control that performs an action rather than holding a
/// state. Same geometry and same labelling rules as [AppIconToggle].
///
/// A null [onPressed] disables it: the icon dims, the ink goes, and it
/// drops out of focus traversal, so Tab skips it. The tooltip still shows
/// on hover, which is where a disabled control can say why.
///
/// [badge] draws a small accent dot in the top-right corner, for a control
/// with something waiting behind it.
class AppIconAction extends StatelessWidget {
  const AppIconAction({
    required this.icon,
    required this.tooltip,
    required this.semanticLabel,
    required this.onPressed,
    this.badge = false,
    this.focusNode,
    super.key,
  }) : assert(tooltip != '', 'an icon-only control needs a tooltip'),
       assert(
         semanticLabel != '',
         'an icon-only control needs a semantics label',
       );

  /// On the badge dot, so a test can find it.
  static const Key badgeKey = Key('app-icon-action-badge');

  final AppIcon icon;
  final String tooltip;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool badge;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AppTokens.of(context);
    final enabled = onPressed != null;

    // See the matching note in AppIconToggle.build: Semantics has to be the
    // outer widget so this node stays reachable by widget type.
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: AppTokens.controlBandHeight + 2,
          height: AppTokens.controlBandHeight,
          decoration: BoxDecoration(
            color: tokens.controlSurface,
            borderRadius: BorderRadius.circular(tokens.radiusControl),
          ),
          child: Stack(
            children: [
              // See the matching note in AppMenuButton.build: this Material
              // has to sit between the fill and the InkWell for ink to be
              // visible at all.
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    focusNode: focusNode,
                    onTap: onPressed,
                    hoverColor: tokens.controlHover,
                    highlightColor: tokens.controlActive,
                    splashColor: tokens.controlActive,
                    borderRadius: BorderRadius.circular(tokens.radiusControl),
                    child: Center(
                      child: AppIconView(
                        icon,
                        size: 16,
                        color: enabled
                            ? scheme.onSurfaceVariant
                            : scheme.onSurfaceVariant.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
                ),
              ),
              if (badge)
                Positioned(
                  top: 3,
                  right: 4,
                  child: IgnorePointer(
                    child: Container(
                      key: badgeKey,
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        // A ring in the control's own fill keeps the dot
                        // legible where it overlaps the icon, in both
                        // themes.
                        border: Border.all(color: tokens.controlSurface),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip's search field.
///
/// [fieldKey] lands on the inner [TextField] rather than on this wrapper:
/// `tester.enterText` resolves its finder to an `EditableText`, so a key on
/// the wrapper would make the field untypable from a test.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    required this.controller,
    required this.onChanged,
    this.fieldKey,
    this.focusNode,
    this.hintText = 'Search scenes',
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final Key? fieldKey;
  final FocusNode? focusNode;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return SizedBox(
      height: AppTokens.controlBandHeight,
      child: TextField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        style: Theme.of(context).textTheme.labelMedium,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: Center(
            widthFactor: 1,
            child: AppIconView(
              AppIcon.search,
              size: 16,
              color: tokens.textFaint,
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: AppTokens.controlBandHeight,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space2,
          ),
        ),
      ),
    );
  }
}
