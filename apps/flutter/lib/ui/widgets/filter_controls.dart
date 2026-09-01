import 'package:flutter/material.dart';

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
/// Built on [InkWell] plus [showMenu] rather than `PopupMenuButton` so the
/// caller can supply its own [FocusNode]: the library toolbar pins an
/// explicit Tab order across controls that move between rows, which needs
/// a node per control. `MenuAnchor` is not an option here: its overlay is
/// not part of the surrounding traversal chain, so nothing inside it is
/// reachable by sequential Tab.
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
  Future<void> _open() async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          button.size.bottomLeft(Offset.zero),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<T>(
      context: context,
      position: position,
      initialValue: widget.value,
      items: [
        for (final item in widget.items)
          PopupMenuItem<T>(
            value: item.value,
            height: 36,
            child: Text(item.label),
          ),
      ],
    );

    if (selected != null) widget.onChanged(selected);
  }

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
      child: InkWell(
        focusNode: widget.focusNode,
        onTap: _open,
        borderRadius: BorderRadius.circular(AppTokens.radiusControl),
        child: Container(
          height: AppTokens.controlBandHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.space3),
          decoration: BoxDecoration(
            color: tokens.controlSurface,
            borderRadius: BorderRadius.circular(AppTokens.radiusControl),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: theme.textTheme.labelMedium),
              const SizedBox(width: AppTokens.space1),
              Icon(Icons.arrow_drop_down, size: 16, color: tokens.textFaint),
            ],
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

  final IconData icon;
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
        child: InkWell(
          focusNode: focusNode,
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTokens.radiusControl),
          child: AnimatedContainer(
            duration: AppTokens.hoverDuration,
            width: AppTokens.controlBandHeight + 2,
            height: AppTokens.controlBandHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? scheme.primary : tokens.controlSurface,
              borderRadius: BorderRadius.circular(AppTokens.radiusControl),
            ),
            child: Icon(
              icon,
              size: 16,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// A square icon control that performs an action rather than holding a
/// state. Same geometry and same labelling rules as [AppIconToggle].
class AppIconAction extends StatelessWidget {
  const AppIconAction({
    required this.icon,
    required this.tooltip,
    required this.semanticLabel,
    required this.onPressed,
    this.focusNode,
    super.key,
  }) : assert(tooltip != '', 'an icon-only control needs a tooltip'),
       assert(
         semanticLabel != '',
         'an icon-only control needs a semantics label',
       );

  final IconData icon;
  final String tooltip;
  final String semanticLabel;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AppTokens.of(context);

    // See the matching note in AppIconToggle.build: Semantics has to be the
    // outer widget so this node stays reachable by widget type.
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          focusNode: focusNode,
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTokens.radiusControl),
          child: Container(
            width: AppTokens.controlBandHeight + 2,
            height: AppTokens.controlBandHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.controlSurface,
              borderRadius: BorderRadius.circular(AppTokens.radiusControl),
            ),
            child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
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
          prefixIcon: Icon(Icons.search, size: 16, color: tokens.textFaint),
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
