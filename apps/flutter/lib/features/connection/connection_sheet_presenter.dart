import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/connection.dart';
import 'connection_controller.dart';
import 'connection_form.dart';
import 'connection_sheet.dart';

/// Runs a [ConnectionSheet] against the [ConnectionController]: every
/// rule stays here in Dart, and the sheet only shows what it's told.
///
/// - The stored connection is loaded before the sheet appears, so nothing
///   can be typed before the fields are seeded.
/// - Submit runs `testAndSave`. While it runs, the sheet is busy (fields
///   and both buttons disabled, since `testAndSave` saves the moment
///   Stash answers and a close mid-test would leave it saved but unused).
/// - Errors land under their fields. Success dismisses the sheet and
///   reports the config through [onConnected].
/// - Cancel is reported through [onCancelled]; the owner decides whether
///   that closes the sheet (via [close]).
class ConnectionSheetPresenter {
  ConnectionSheetPresenter({
    required this.sheet,
    required this.controller,
    required this.onConnected,
    required this.onCancelled,
  });

  final ConnectionSheet sheet;
  final ConnectionController controller;
  final void Function(ConnectionConfig config) onConnected;
  final VoidCallback onCancelled;

  ConnectionConfig _values = const ConnectionConfig();
  ConnectionSheetState? _lastSent;
  ConnectionPhase? _lastPhase;
  bool _open = false;

  /// Loads the stored connection, then shows the sheet seeded with it.
  /// Rethrows the sheet's own failure to open.
  Future<void> open({
    required String title,
    required String confirmLabel,
    required bool cancellable,
  }) async {
    await controller.load();
    _values = controller.state.config;
    _lastPhase = controller.state.phase;
    await sheet.present(
      ConnectionSheetRequest(
        title: title,
        confirmLabel: confirmLabel,
        cancellable: cancellable,
        values: _values,
        proxyHint: connectionProxyHint,
      ),
      _onEvent,
    );
    _open = true;
    controller.addListener(_onController);
    _push();
  }

  /// Closes the sheet. Safe to call when it isn't open.
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    controller.removeListener(_onController);
    await sheet.dismiss();
  }

  void _onEvent(ConnectionSheetEvent event) {
    switch (event) {
      case ConnectionSheetChanged(:final values):
        _values = values;
        _push();
      case ConnectionSheetSubmitted(:final values):
        _values = values;
        unawaited(controller.testAndSave(values));
      case ConnectionSheetCancelled():
        onCancelled();
    }
  }

  void _onController() {
    final state = controller.state;
    final previous = _lastPhase;
    _lastPhase = state.phase;
    if (previous != ConnectionPhase.ready &&
        state.phase == ConnectionPhase.ready) {
      unawaited(close());
      onConnected(state.config);
      return;
    }
    _push();
  }

  void _push() {
    final state = controller.state;
    final next = ConnectionSheetState(
      // Same rule as ConnectionFields.canSubmit.
      canSubmit: _values.serverUrl.trim().isNotEmpty,
      busy: state.phase == ConnectionPhase.loading,
      urlError: state.fieldError,
      proxyError: state.proxyFieldError,
      failure: state.failure,
    );
    if (next == _lastSent) return;
    _lastSent = next;
    unawaited(sheet.update(next));
  }
}
