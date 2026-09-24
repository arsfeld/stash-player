import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../theme/platform_dialect.dart';

/// A titled group of form rows: libadwaita's `AdwPreferencesGroup` (rows
/// in one rounded boxed list, separated by hairlines) or an AppKit form
/// section (plain rows under a bold label).
class AppPreferencesGroup extends StatelessWidget {
  const AppPreferencesGroup({
    required this.title,
    required this.children,
    this.description,
    super.key,
  });

  final String title;
  final List<Widget> children;

  /// Dimmed text under the rows, for guidance that applies to the group.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTokens.of(context);
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;

    final Widget rows = adwaita
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.controlSurface,
              borderRadius: BorderRadius.circular(tokens.radiusPanel),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, row) in children.indexed) ...[
                  if (index > 0) const Divider(),
                  row,
                ],
              ],
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, row) in children.indexed) ...[
                if (index > 0) const SizedBox(height: AppTokens.space2),
                row,
              ],
            ],
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppTokens.space2),
        rows,
        if (description case final String text) ...[
          const SizedBox(height: AppTokens.space2),
          Padding(
            // On macOS the description lines up with the fields, not the
            // labels, as AppKit forms do.
            padding: EdgeInsetsDirectional.only(
              start: adwaita ? 0 : AppEntryRow.macLabelWidth + AppTokens.space2,
            ),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One labelled text field in an [AppPreferencesGroup].
///
/// On Adwaita it follows `AdwEntryRow`: a borderless field filling the
/// row, with the label inside it that moves up to a caption once the row
/// has focus or text, which is exactly a floating label. On macOS it is
/// an AppKit form row: a right-aligned "Label:" column beside a bordered
/// field, with the label and field merged into one semantics node so a
/// screen reader names the field. [errorText] is the field's own, so it
/// renders directly under the field on both.
class AppEntryRow extends StatelessWidget {
  const AppEntryRow({
    required this.label,
    required this.controller,
    this.fieldKey,
    this.focusNode,
    this.hint,
    this.errorText,
    this.enabled = true,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.trailing,
    super.key,
  });

  /// Width of the macOS label column: room for "SOCKS5 proxy:" at the
  /// default text size.
  static const double macLabelWidth = 120;

  final String label;
  final TextEditingController controller;

  /// Put on the [TextField] itself, so tests can reach it.
  final Key? fieldKey;
  final FocusNode? focusNode;
  final String? hint;
  final String? errorText;
  final bool enabled;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  /// A control after the field, such as a show/hide toggle. Kept out of
  /// the macOS merged semantics node so it stays its own button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) =>
      PlatformDialect.of(context) == PlatformDialect.adwaita
      ? _adwaita()
      : _macos();

  TextField _field(InputDecoration decoration) => TextField(
    key: fieldKey,
    controller: controller,
    focusNode: focusNode,
    enabled: enabled,
    obscureText: obscureText,
    keyboardType: keyboardType,
    textInputAction: textInputAction,
    onSubmitted: onSubmitted,
    decoration: decoration,
  );

  Widget _adwaita() => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppTokens.space3,
      vertical: AppTokens.space1,
    ),
    child: Row(
      children: [
        Expanded(
          child: _field(
            InputDecoration(
              labelText: label,
              hintText: hint,
              errorText: errorText,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _macos() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: macLabelWidth,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppTokens.space2),
                  child: Text('$label:', textAlign: TextAlign.end),
                ),
              ),
              const SizedBox(width: AppTokens.space2),
              Expanded(
                child: _field(
                  InputDecoration(hintText: hint, errorText: errorText),
                ),
              ),
            ],
          ),
        ),
      ),
      ?trailing,
    ],
  );
}
