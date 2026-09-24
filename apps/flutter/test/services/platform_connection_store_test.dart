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
      'a keyring failure still imports the URL and proxy, with an empty key, '
      'once',
      () async {
        final failing = _StubSecrets.failing();
        final store = buildImportingStore(failing);
        const expected = ConnectionConfig(
          serverUrl: 'https://legacy.lan',
          socksProxy: '127.0.0.1:1055',
        );

        expect(await store.load(const {}), expected);
        expect(await store.load(const {}), expected);
        expect(failing.reads, 1);
      },
    );

    test(
      'a failure persisting the import falls through to an empty connection, '
      'once',
      () async {
        SharedPreferencesAsyncPlatform.instance = _FlakyPreferences(
          failingSetString: serverUrlPreferenceKey,
        );
        final secrets = _StubSecrets('legacy-key');
        final store = buildImportingStore(secrets);

        expect((await store.load(const {})).serverUrl, '');
        expect((await store.load(const {})).serverUrl, '');
        expect(secrets.reads, 1);
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

    test('a preferences failure during the import is retried on the next '
        'load(), not replayed forever', () async {
      SharedPreferencesAsyncPlatform.instance = _FlakyPreferences(
        failingGetBool: legacyImportAttemptedPreferenceKey,
      );
      final secrets = _StubSecrets('legacy-key');
      final store = buildImportingStore(secrets);

      await expectLater(store.load(const {}), throwsA(anything));

      expect(
        await store.load(const {}),
        const ConnectionConfig(
          serverUrl: 'https://legacy.lan',
          apiKey: 'legacy-key',
          socksProxy: '127.0.0.1:1055',
        ),
      );
      expect(secrets.reads, 1);
    });
  });
}

/// Throws once on the first `getBool` call for [_failingGetBool], or the
/// first `setString` call for [_failingSetString], then answers like a
/// normal in-memory store. The `getBool` case stands in for a preferences
/// backend that glitches on `_importLegacy`'s unguarded read of
/// [legacyImportAttemptedPreferenceKey] (the reads/writes around that flag
/// aren't inside its try/catch — only the actual import is), so a `load()`
/// call can be asserted to retry afterwards rather than replay the same
/// rejected import forever. The `setString` case fails persisting an
/// import, inside that try/catch.
base class _FlakyPreferences extends InMemorySharedPreferencesAsync {
  _FlakyPreferences({String? failingGetBool, String? failingSetString})
    : _failingGetBool = failingGetBool,
      _failingSetString = failingSetString,
      super.empty();

  final String? _failingGetBool;
  final String? _failingSetString;
  bool _getBoolThrown = false;
  bool _setStringThrown = false;

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) {
    if (key == _failingGetBool && !_getBoolThrown) {
      _getBoolThrown = true;
      return Future<bool?>.error(Exception('preferences unavailable'));
    }
    return super.getBool(key, options);
  }

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) {
    if (key == _failingSetString && !_setStringThrown) {
      _setStringThrown = true;
      return Future<bool>.error(Exception('preferences unavailable'));
    }
    return super.setString(key, value, options);
  }
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
