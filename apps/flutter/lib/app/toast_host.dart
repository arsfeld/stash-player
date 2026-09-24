import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/widgets/app_toast.dart';
import 'notices.dart';

/// Shows each [globalNoticeProvider] notice as an [AppToast] over [child]
/// for [duration], replacing whatever toast is already up.
///
/// Mounted from `MaterialApp.builder`, so its context sits under the
/// app's Theme and a toast resolves the app's colours rather than
/// Flutter's fallback ones.
class ToastHost extends ConsumerStatefulWidget {
  const ToastHost({required this.child, super.key});

  static const Duration duration = Duration(seconds: 4);

  final Widget child;

  @override
  ConsumerState<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends ConsumerState<ToastHost> {
  AppNotice? _notice;
  Timer? _dismiss;

  @override
  void dispose() {
    _dismiss?.cancel();
    super.dispose();
  }

  void _show(AppNotice notice) {
    _dismiss?.cancel();
    setState(() => _notice = notice);
    _dismiss = Timer(ToastHost.duration, () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppNotice?>(globalNoticeProvider, (previous, next) {
      if (next == null || next.id == previous?.id) return;
      _show(next);
    });
    final theme = Theme.of(context);
    final notice = _notice;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: AppToast.alignmentFor(theme.platform),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: notice == null
                      ? const SizedBox.shrink()
                      : AppToast(
                          key: ValueKey(notice.id),
                          message: notice.message,
                          background: _colorFor(notice.severity, theme),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Color? _colorFor(AppNoticeSeverity severity, ThemeData theme) =>
      switch (severity) {
        AppNoticeSeverity.error => theme.colorScheme.error,
        AppNoticeSeverity.success => theme.colorScheme.primary,
        AppNoticeSeverity.warning || AppNoticeSeverity.info => null,
      };
}
