import 'package:flutter/foundation.dart';

import '../../domain/connection.dart';

/// What a [ConnectionSheet] opens with.
@immutable
class ConnectionSheetRequest {
  const ConnectionSheetRequest({
    required this.title,
    required this.confirmLabel,
    required this.cancellable,
    required this.values,
    required this.proxyHint,
  });

  final String title;
  final String confirmLabel;

  /// Whether the sheet has a Cancel button (and Esc). False on first
  /// launch, when there is nothing to go back to.
  final bool cancellable;

  /// The fields' initial text.
  final ConnectionConfig values;
  final String proxyHint;
}

/// Everything about an open sheet that Dart decides: whether it can
/// submit, whether a test is running, and the errors to show.
@immutable
class ConnectionSheetState {
  const ConnectionSheetState({
    required this.canSubmit,
    required this.busy,
    this.urlError,
    this.proxyError,
    this.failure,
  });

  final bool canSubmit;
  final bool busy;
  final String? urlError;
  final String? proxyError;
  final String? failure;

  @override
  bool operator ==(Object other) =>
      other is ConnectionSheetState &&
      other.canSubmit == canSubmit &&
      other.busy == busy &&
      other.urlError == urlError &&
      other.proxyError == proxyError &&
      other.failure == failure;

  @override
  int get hashCode =>
      Object.hash(canSubmit, busy, urlError, proxyError, failure);
}

/// What the user did in the sheet.
sealed class ConnectionSheetEvent {
  const ConnectionSheetEvent();
}

/// A field changed. [values] holds all three fields' current text.
final class ConnectionSheetChanged extends ConnectionSheetEvent {
  const ConnectionSheetChanged(this.values);
  final ConnectionConfig values;
}

/// The confirm button (or Return).
final class ConnectionSheetSubmitted extends ConnectionSheetEvent {
  const ConnectionSheetSubmitted(this.values);
  final ConnectionConfig values;
}

/// Cancel (or Esc).
final class ConnectionSheetCancelled extends ConnectionSheetEvent {
  const ConnectionSheetCancelled();
}

/// The connection form as a platform sheet: an AppKit sheet on macOS
/// (`ConnectionSheetChannel.swift`). It holds no rules of its own;
/// `ConnectionSheetPresenter` decides everything and pushes it through
/// [update].
abstract interface class ConnectionSheet {
  /// Shows the sheet. [onEvent] receives edits, submit and cancel until
  /// [dismiss]. Throws `MissingPluginException` or `PlatformException`
  /// when the native side is unavailable.
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  );

  Future<void> update(ConnectionSheetState state);

  /// Closes the sheet. A no-op when none is open.
  Future<void> dismiss();
}
