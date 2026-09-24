import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/services/legacy_connection_importer.dart';
import 'package:stash_player_flutter/services/legacy_secret_reader.dart';
import 'package:stash_player_flutter/services/platform_connection_store.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    FlutterSecureStorage.setMockInitialValues({});
  });

  PlatformConnectionStore buildStore() => PlatformConnectionStore(
    preferences: SharedPreferencesAsync(),
    secureStorage: const FlutterSecureStorage(),
  );

  test(
    'round-trips the SOCKS proxy alongside the rest of the connection',
    () async {
      final store = buildStore();

      await store.save(
        const ConnectionConfig(
          serverUrl: 'https://stash.example.ts.net',
          apiKey: 'secret',
          socksProxy: '127.0.0.1:1055',
        ),
      );

      expect(
        await store.load(const {}),
        const ConnectionConfig(
          serverUrl: 'https://stash.example.ts.net',
          apiKey: 'secret',
          socksProxy: '127.0.0.1:1055',
        ),
      );
    },
  );

  test('lets the environment override the stored SOCKS proxy', () async {
    final store = buildStore();
    await store.save(const ConnectionConfig(socksProxy: '127.0.0.1:1055'));

    final loaded = await store.load(const {
      'STASH_SOCKS_PROXY': '10.0.0.1:1080',
    });

    expect(loaded.socksProxy, '10.0.0.1:1080');
  });

  group('legacy import', () {
    late Directory dir;
    late String legacyConfigPath;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('legacy-store');
      legacyConfigPath = p.join(dir.path, 'config.toml');
      File(legacyConfigPath).writeAsStringSync(
        'stash_url = "https://legacy.lan"\nproxy_url = "socks5h://127.0.0.1:1055"\n',
      );
    });
    tearDown(() => dir.delete(recursive: true));

    PlatformConnectionStore buildImportingStore(LegacySecretReader secrets) =>
        PlatformConnectionStore(
          preferences: SharedPreferencesAsync(),
          secureStorage: const FlutterSecureStorage(),
          legacyImporter: LegacyConnectionImporter(
            configPaths: [legacyConfigPath],
            secrets: secrets,
          ),
        );

    test(
      'imports and persists the legacy connection when none is stored',
      () async {
        final store = buildImportingStore(_StubSecrets('legacy-key'));
        const expected = ConnectionConfig(
          serverUrl: 'https://legacy.lan',
          apiKey: 'legacy-key',
          socksProxy: '127.0.0.1:1055',
        );

        expect(await store.load(const {}), expected);
        // Persisted: a store without an importer now sees it too.
        expect(await buildStore().load(const {}), expected);
      },
    );

    test('never imports over an existing connection', () async {
      await buildStore().save(
        const ConnectionConfig(serverUrl: 'https://mine'),
      );

      final loaded = await buildImportingStore(
        _StubSecrets('legacy-key'),
      ).load(const {});

      expect(loaded.serverUrl, 'https://mine');
    });

    test(
      'runs at most once, even when the user later clears the URL',
      () async {
        final store = buildImportingStore(_StubSecrets('legacy-key'));
        await store.load(const {});
        await store.save(const ConnectionConfig());

        expect((await store.load(const {})).serverUrl, '');
      },
    );

    test(
      'a failed import falls through to an empty connection, once',
      () async {
        final failing = _StubSecrets.failing();
        final store = buildImportingStore(failing);

        expect((await store.load(const {})).serverUrl, '');
        expect((await store.load(const {})).serverUrl, '');
        expect(failing.reads, 1);
      },
    );

    test(
      'environment overrides still win over an imported connection',
      () async {
        final store = buildImportingStore(_StubSecrets('legacy-key'));

        final loaded = await store.load(const {'STASH_URL': 'http://env'});

        expect(loaded.serverUrl, 'http://env');
        expect(loaded.apiKey, 'legacy-key');
      },
    );

    test('concurrent loads share a single import', () async {
      final secrets = _StubSecrets('legacy-key');
      final store = buildImportingStore(secrets);
      const expected = ConnectionConfig(
        serverUrl: 'https://legacy.lan',
        apiKey: 'legacy-key',
        socksProxy: '127.0.0.1:1055',
      );

      final results = await Future.wait([
        store.load(const {}),
        store.load(const {}),
      ]);

      expect(results, [expected, expected]);
      expect(secrets.reads, 1);
    });
  });
}

class _StubSecrets implements LegacySecretReader {
  _StubSecrets(this._key) : _fail = false;
  _StubSecrets.failing() : _key = null, _fail = true;

  final String? _key;
  final bool _fail;
  int reads = 0;

  @override
  Future<String?> readApiKey() async {
    reads++;
    if (_fail) throw PlatformException(code: 'lookup-failed');
    return _key;
  }
}
