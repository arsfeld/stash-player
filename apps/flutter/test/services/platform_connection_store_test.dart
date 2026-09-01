import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:stash_player_flutter/domain/connection.dart';
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
}
