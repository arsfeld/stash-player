import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/connection.dart';
import '../../shared/diagnostics.dart';
import 'connection_controller.dart';
import 'connection_sheet_presenter.dart';

/// Shows the native connection sheet over [child] while [open] is true,
/// when the app has one (macOS). With no sheet it just shows [child],
/// and the caller draws its own form.
///
/// If the sheet fails to open, it disables [connectionSheetProvider] for
/// the rest of the session, which brings every drawn fallback back (the
/// router's settings dialog, the first-launch form).
class ConnectionSheetHost extends ConsumerStatefulWidget {
  const ConnectionSheetHost({
    required this.open,
    required this.title,
    required this.confirmLabel,
    required this.cancellable,
    required this.onConnected,
    required this.child,
    this.onCancelled,
    super.key,
  });

  final bool open;
  final String title;
  final String confirmLabel;
  final bool cancellable;
  final void Function(ConnectionConfig config) onConnected;
  final VoidCallback? onCancelled;
  final Widget child;

  @override
  ConsumerState<ConnectionSheetHost> createState() =>
      _ConnectionSheetHostState();
}

class _ConnectionSheetHostState extends ConsumerState<ConnectionSheetHost> {
  ConnectionSheetPresenter? _presenter;

  /// Bumped on every open and close, so an open still loading when the
  /// host closes can tell it has been superseded.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.open) _scheduleOpen();
  }

  @override
  void didUpdateWidget(ConnectionSheetHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) _scheduleOpen();
    if (!widget.open && oldWidget.open) _close();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  // After the frame: opening loads through the connection controller,
  // and Riverpod forbids changing provider state mid-build.
  void _scheduleOpen() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());

  Future<void> _open() async {
    if (!mounted || !widget.open || _presenter != null) return;
    final sheet = ref.read(connectionSheetProvider);
    if (sheet == null) return;
    final generation = ++_generation;
    final presenter = ConnectionSheetPresenter(
      sheet: sheet,
      controller: ref.read(connectionControllerProvider),
      onConnected: (config) {
        _presenter = null;
        widget.onConnected(config);
      },
      onCancelled: () => widget.onCancelled?.call(),
    );
    _presenter = presenter;
    try {
      await presenter.open(
        title: widget.title,
        confirmLabel: widget.confirmLabel,
        cancellable: widget.cancellable,
      );
    } on Object catch (error) {
      if (error is! MissingPluginException && error is! PlatformException) {
        rethrow;
      }
      _presenter = null;
      logDiagnostic('connection', 'native sheet unavailable, drawing: $error');
      if (mounted) ref.read(connectionSheetProvider.notifier).disable();
      return;
    }
    // Closed while it was loading: take the fresh sheet straight down.
    if (generation != _generation || !mounted) unawaited(presenter.close());
  }

  void _close() {
    _generation++;
    final presenter = _presenter;
    _presenter = null;
    if (presenter != null) unawaited(presenter.close());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
