import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Private layout widget shared by AppEmptyView and AppErrorView.
class _StatusColumn extends StatelessWidget {
  const _StatusColumn({
    required this.icon,
    required this.message,
    required this.messageStyle,
    required this.actionWidget,
  });

  final Widget icon;
  final String message;
  final TextStyle? messageStyle;
  final Widget actionWidget;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(height: AppTokens.space3),
        Text(message, textAlign: TextAlign.center, style: messageStyle),
        const SizedBox(height: AppTokens.space4),
        actionWidget,
      ],
    ),
  );
}

/// A centred spinner with a semantics label, for a screen with nothing to
/// show yet.
class AppLoadingView extends StatelessWidget {
  const AppLoadingView({this.semanticLabel = 'Loading', super.key});

  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: semanticLabel,
      child: const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// A centred "nothing here" state with one way out.
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTokens.of(context);
    return _StatusColumn(
      icon: Icon(
        Icons.movie_filter_outlined,
        size: 32,
        color: tokens.textFaint,
      ),
      message: message,
      messageStyle: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      actionWidget: OutlinedButton(
        onPressed: onAction,
        child: Text(actionLabel),
      ),
    );
  }
}

/// A centred failure state. Callers pass `Failure.userMessage`; the raw
/// `Failure.message` can carry server text and must never reach here.
class AppErrorView extends StatelessWidget {
  const AppErrorView({required this.message, required this.onRetry, super.key});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatusColumn(
      icon: Icon(Icons.error_outline, size: 32, color: theme.colorScheme.error),
      message: message,
      messageStyle: theme.textTheme.bodyMedium,
      actionWidget: FilledButton(
        onPressed: onRetry,
        child: const Text('Retry'),
      ),
    );
  }
}

/// A non-blocking failure strip shown above content that did load, in
/// place of Material's `MaterialBanner`. Callers pass `Failure.userMessage`;
/// the raw `Failure.message` can carry server text and must never reach here.
class AppInlineBanner extends StatelessWidget {
  const AppInlineBanner({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppTokens.space3),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space3,
        vertical: AppTokens.space2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTokens.radiusPanel),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: AppTokens.space2),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}
