import 'dart:async';

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

  test('load() clears a previous attempt\'s field errors and does not carry '
      'its unsaved config forward when the store itself throws (final '
      'review §1: reopening the dialog after a failed Save, then Cancel, '
      're-runs load() on the same shared controller; if that load() itself '
      'fails, it used to keep the old fieldError/proxyFieldError and the '
      'old failed config, so a reopened form would seed itself from an '
      'unsaved, invalid entry)', () async {
    // `..ignore()`: this future is deliberately not awaited until after
    // the testAndSave below, so without it Dart's zone would report an
    // unhandled-error failure the moment the microtask queue drains,
    // well before `load()` ever gets to it.
    final loadFuture = Future<ConnectionConfig>.error(
      Exception('disk unreadable'),
    )..ignore();
    final controller = ConnectionController(
      store: FakeConnectionStore(loadFuture: loadFuture),
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    // A previous failed Save in this same session, standing in for the
    // state a reopened dialog's shared controller would still be
    // carrying.
    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'not a url'),
    );
    expect(controller.state.fieldError, isNotNull);
    expect(controller.state.config.serverUrl, 'not a url');

    await controller.load();

    expect(controller.state.phase, ConnectionPhase.failed);
    expect(
      controller.state.failure,
      'Could not load saved connection settings.',
    );
    expect(controller.state.fieldError, isNull);
    expect(controller.state.proxyFieldError, isNull);
    expect(controller.state.config, const ConnectionConfig());
  });

  test(
    'load() falls back to a generic failure message when the store throws '
    'a bare (non-Failure) error (final review §3b: previously untested)',
    () async {
      final controller = ConnectionController(
        store: FakeConnectionStore(
          loadFuture: Future<ConnectionConfig>.error(
            Exception('disk unreadable'),
          ),
        ),
        environment: const {},
        apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
      );

      await controller.load();

      expect(controller.state.phase, ConnectionPhase.failed);
      expect(
        controller.state.failure,
        'Could not load saved connection settings.',
      );
    },
  );

  test('testAndSave falls back to a generic failure message when the API '
      'factory throws a bare (non-Failure) error (final review §3b: '
      'previously untested)', () async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) =>
          FakeStashApi(versionFuture: Future<String>.error(Exception('boom'))),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'key'),
    );

    expect(controller.state.phase, ConnectionPhase.failed);
    expect(controller.state.failure, 'Could not save the connection settings.');
    expect(store.saveCalls, isEmpty);
  });

  test('rejects an unparseable SOCKS proxy before contacting Stash', () async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await controller.testAndSave(
      const ConnectionConfig(
        serverUrl: 'https://stash.test',
        socksProxy: 'not a proxy',
      ),
    );

    expect(controller.state.phase, ConnectionPhase.failed);
    expect(controller.state.proxyFieldError, isNotNull);
    expect(store.saveCalls, isEmpty);
  });

  test('load() does not clobber an in-flight testAndSave (final review §2: '
      'a load() that resolves while a test is still running used to reset '
      'phase back to initial with the stored config, which would silently '
      're-enable Cancel/Esc mid-test)', () async {
    final store = FakeConnectionStore(
      saved: const ConnectionConfig(serverUrl: 'https://stored.test'),
    );
    final versionCompleter = Completer<String>();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionFuture: versionCompleter.future),
    );

    // testAndSave sets phase to loading synchronously, before its first
    // await, so this is already true the moment the call returns.
    final testAndSaveFuture = controller.testAndSave(
      const ConnectionConfig(serverUrl: 'https://entered.test'),
    );
    expect(controller.state.phase, ConnectionPhase.loading);

    // A concurrent load() — e.g. the form's own mount-time fetch —
    // resolves while the test above is still in flight. It must leave
    // the loading state alone.
    await controller.load();

    expect(controller.state.phase, ConnectionPhase.loading);
    expect(controller.state.config.serverUrl, 'https://entered.test');

    versionCompleter.complete('v0.31.0');
    await testAndSaveFuture;

    expect(controller.state.phase, ConnectionPhase.ready);
    expect(store.saveCalls, hasLength(1));
    expect(store.saveCalls.single.serverUrl, 'https://entered.test');
  });

  test('accepts a blank SOCKS proxy as meaning no proxy', () async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await controller.testAndSave(
      const ConnectionConfig(serverUrl: 'https://stash.test'),
    );

    expect(controller.state.phase, ConnectionPhase.ready);
    expect(controller.state.proxyFieldError, isNull);
  });
}
