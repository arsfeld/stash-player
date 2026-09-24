import 'package:flutter/services.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';

/// A [ConnectionSheet] that records what it is told and lets a test act
/// as the user through [send].
class FakeConnectionSheet implements ConnectionSheet {
  FakeConnectionSheet({this.failPresent = false});

  bool failPresent;
  ConnectionSheetRequest? presented;
  final List<ConnectionSheetState> updates = [];
  bool dismissed = false;
  void Function(ConnectionSheetEvent event)? _onEvent;

  bool get isOpen => _onEvent != null;

  void send(ConnectionSheetEvent event) => _onEvent?.call(event);

  @override
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  ) async {
    if (failPresent) throw MissingPluginException('no sheet');
    presented = request;
    dismissed = false;
    _onEvent = onEvent;
  }

  @override
  Future<void> update(ConnectionSheetState state) async => updates.add(state);

  @override
  Future<void> dismiss() async {
    dismissed = true;
    _onEvent = null;
  }
}

/// Overrides [connectionSheetProvider] with [sheet].
class FakeConnectionSheetNotifier extends ConnectionSheetNotifier {
  FakeConnectionSheetNotifier(this.sheet);
  final ConnectionSheet? sheet;

  @override
  ConnectionSheet? build() => sheet;
}
