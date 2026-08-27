import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import '../../domain/failure.dart';
import '../../services/connection_store.dart';
import '../../services/stash_api.dart';

enum ConnectionPhase { initial, loading, ready, failed }

class ConnectionState {
  const ConnectionState({
    this.config = const ConnectionConfig(),
    this.phase = ConnectionPhase.initial,
    this.serverVersion,
    this.fieldError,
    this.failure,
  });

  final ConnectionConfig config;
  final ConnectionPhase phase;
  final String? serverVersion;
  final String? fieldError;
  final String? failure;

  ConnectionState copyWith({
    ConnectionConfig? config,
    ConnectionPhase? phase,
    String? serverVersion,
    String? fieldError,
    String? failure,
    bool clearServerVersion = false,
    bool clearFieldError = false,
    bool clearFailure = false,
  }) => ConnectionState(
    config: config ?? this.config,
    phase: phase ?? this.phase,
    serverVersion: clearServerVersion
        ? null
        : serverVersion ?? this.serverVersion,
    fieldError: clearFieldError ? null : fieldError ?? this.fieldError,
    failure: clearFailure ? null : failure ?? this.failure,
  );
}

typedef StashApiFactory = StashApi Function(ConnectionConfig config);

final connectionControllerProvider =
    ChangeNotifierProvider<ConnectionController>((ref) {
      throw UnsupportedError(
        'ConnectionController must be provided by app bootstrap.',
      );
    });

class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required ConnectionStore store,
    required Map<String, String> environment,
    required StashApiFactory apiFactory,
  }) : _store = store,
       _environment = environment,
       _apiFactory = apiFactory;

  final ConnectionStore _store;
  final Map<String, String> _environment;
  final StashApiFactory _apiFactory;

  ConnectionState _state = const ConnectionState();
  ConnectionState get state => _state;

  /// Fetches the effective (environment-overlaid) stored config in the
  /// background and applies it once resolved.
  ///
  /// Deliberately does not transition through [ConnectionPhase.loading] —
  /// that phase disables the form fields, and this fetch must not block the
  /// user from typing while it's in flight (they may be filling in the form
  /// before the stored/environment values are even read).
  Future<void> load() async {
    try {
      final stored = await _store.load(_environment);
      _setState(
        ConnectionState(
          config: overlayEnvironment(stored, _environment),
          phase: ConnectionPhase.initial,
        ),
      );
    } catch (_) {
      _setState(
        _state.copyWith(
          phase: ConnectionPhase.failed,
          failure: 'Could not load saved connection settings.',
        ),
      );
    }
  }

  Future<void> testAndSave(ConnectionConfig entered) async {
    final config = entered.copyWith(serverUrl: entered.serverUrl.trim());
    if (!_validServerUrl(config.serverUrl)) {
      _setState(
        ConnectionState(
          config: config,
          phase: ConnectionPhase.failed,
          fieldError: 'Enter a valid http or https server URL.',
        ),
      );
      return;
    }

    _setState(ConnectionState(config: config, phase: ConnectionPhase.loading));
    try {
      final version = await _apiFactory(config).version();
      await _store.save(config);
      _setState(
        ConnectionState(
          config: config,
          phase: ConnectionPhase.ready,
          serverVersion: version,
        ),
      );
    } on Failure catch (failure) {
      _setState(
        ConnectionState(
          config: config,
          phase: ConnectionPhase.failed,
          failure: _copyFor(failure),
        ),
      );
    } catch (_) {
      _setState(
        ConnectionState(
          config: config,
          phase: ConnectionPhase.failed,
          failure: 'Could not save the connection settings.',
        ),
      );
    }
  }

  bool _validServerUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  String _copyFor(Failure failure) => switch (failure) {
    HttpFailure(:final statusCode) when statusCode == 401 =>
      'Stash rejected the API key. Check it and try again.',
    TransportFailure() =>
      'Could not reach Stash. Check the server URL and network connection.',
    _ => failure.userMessage,
  };

  void _setState(ConnectionState value) {
    _state = value;
    notifyListeners();
  }
}
