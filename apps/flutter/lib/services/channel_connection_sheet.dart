import 'package:flutter/services.dart';

import '../domain/connection.dart';
import '../features/connection/connection_sheet.dart';

/// The connection sheet over `stash_player/connection_sheet`, drawn by
/// `ConnectionSheetChannel.swift` as a real AppKit sheet.
///
/// Events arrive as method calls from the runner and go to the `onEvent`
/// of the sheet that is currently open. Once it is dismissed they are
/// dropped, so a late click can't reach a closed sheet's owner.
class ChannelConnectionSheet implements ConnectionSheet {
  ChannelConnectionSheet({
    MethodChannel channel = const MethodChannel(
      'stash_player/connection_sheet',
    ),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  void Function(ConnectionSheetEvent event)? _onEvent;

  /// Asks the runner to close any sheet a previous isolate left open (a
  /// hot restart). Failures are ignored; [present] reports them.
  Future<void> reset() async {
    try {
      await _channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // No runner support: nothing to reset.
    } on PlatformException {
      // Same.
    }
  }

  @override
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  ) async {
    _onEvent = onEvent;
    try {
      await _channel.invokeMethod<void>('present', {
        'title': request.title,
        'confirmLabel': request.confirmLabel,
        'cancellable': request.cancellable,
        'serverUrl': request.values.serverUrl,
        'apiKey': request.values.apiKey,
        'socksProxy': request.values.socksProxy,
        'proxyHint': request.proxyHint,
      });
    } on Object {
      _onEvent = null;
      rethrow;
    }
  }

  @override
  Future<void> update(ConnectionSheetState state) =>
      _channel.invokeMethod<void>('update', {
        'canSubmit': state.canSubmit,
        'busy': state.busy,
        'urlError': state.urlError,
        'proxyError': state.proxyError,
        'failure': state.failure,
      });

  @override
  Future<void> dismiss() async {
    _onEvent = null;
    try {
      await _channel.invokeMethod<void>('dismiss');
    } on MissingPluginException {
      // Nothing was ever shown.
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final onEvent = _onEvent;
    if (onEvent == null) return null;
    ConnectionConfig values() {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      return ConnectionConfig(
        serverUrl: args['serverUrl'] as String? ?? '',
        apiKey: args['apiKey'] as String? ?? '',
        socksProxy: args['socksProxy'] as String? ?? '',
      );
    }

    switch (call.method) {
      case 'changed':
        onEvent(ConnectionSheetChanged(values()));
      case 'submitted':
        onEvent(ConnectionSheetSubmitted(values()));
      case 'cancelled':
        onEvent(const ConnectionSheetCancelled());
    }
    return null;
  }
}
