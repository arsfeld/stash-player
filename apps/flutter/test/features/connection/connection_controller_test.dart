import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';

import '../../support/fakes.dart';

void main() {
  test('environment values override storage but are not persisted', () async {
    final store = FakeConnectionStore(
      saved: const ConnectionConfig(
        serverUrl: 'https://saved',
        apiKey: 'saved',
      ),
    );
    final controller = ConnectionController(
      store: store,
      environment: const {
        'STASH_URL': 'https://env',
        'STASH_API_KEY': 'env-key',
      },
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await controller.load();

    expect(controller.state.config.serverUrl, 'https://env');
    expect(controller.state.config.apiKey, 'env-key');
    expect(store.saveCalls, isEmpty);
  });

  test('an explicitly empty environment key overrides a stored key', () async {
    final controller = ConnectionController(
      store: FakeConnectionStore(
        saved: const ConnectionConfig(
          serverUrl: 'https://saved',
          apiKey: 'saved',
        ),
      ),
      environment: const {'STASH_API_KEY': ''},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await controller.load();

    expect(controller.state.config.apiKey, isEmpty);
  });

  test('rejects malformed and non-http server URLs', () async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'stash.local', apiKey: 'key'),
    );
    expect(
      controller.state.fieldError,
      'Enter a valid http or https server URL.',
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'ftp://stash.local', apiKey: 'key'),
    );
    expect(
      controller.state.fieldError,
      'Enter a valid http or https server URL.',
    );
    expect(store.saveCalls, isEmpty);
  });

  test('allows an empty API key and displays the server version', () async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: ' https://stash.test ', apiKey: ''),
    );

    expect(controller.state.phase, ConnectionPhase.ready);
    expect(controller.state.serverVersion, 'v0.31.0');
    expect(store.saveCalls, const [
      ConnectionConfig(serverUrl: 'https://stash.test', apiKey: ''),
    ]);
  });

  test('uses authentication guidance for a 401 failure', () async {
    final controller = ConnectionController(
      store: FakeConnectionStore(),
      environment: const {},
      apiFactory: (_) => FakeStashApi(
        versionFailure: const HttpFailure(401, 'secret api key'),
      ),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'secret'),
    );

    expect(
      controller.state.failure,
      'Stash rejected the API key. Check it and try again.',
    );
    expect(controller.state.failure, isNot(contains('secret')));
  });

  test('uses reachability guidance for a transport failure', () async {
    final controller = ConnectionController(
      store: FakeConnectionStore(),
      environment: const {},
      apiFactory: (_) => FakeStashApi(
        versionFailure: const TransportFailure(
          'https://private.example/secret',
        ),
      ),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'secret'),
    );

    expect(
      controller.state.failure,
      'Could not reach Stash. Check the server URL and network connection.',
    );
    expect(controller.state.failure, isNot(contains('private.example')));
  });

  test(
    'saves only the entered form values after successful validation',
    () async {
      final store = FakeConnectionStore(
        saved: const ConnectionConfig(
          serverUrl: 'https://saved',
          apiKey: 'saved',
        ),
      );
      final controller = ConnectionController(
        store: store,
        environment: const {
          'STASH_URL': 'https://environment',
          'STASH_API_KEY': 'environment-key',
        },
        apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
      );
      await controller.load();

      await controller.testAndSave(
        const ConnectionConfig(
          serverUrl: 'https://entered',
          apiKey: 'entered-key',
        ),
      );

      expect(store.saveCalls, const [
        ConnectionConfig(serverUrl: 'https://entered', apiKey: 'entered-key'),
      ]);
    },
  );

  test('does not save after failed validation', () async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) =>
          FakeStashApi(versionFailure: const HttpFailure(500, 'server failed')),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'key'),
    );

    expect(controller.state.phase, ConnectionPhase.failed);
    expect(store.saveCalls, isEmpty);
  });
}
