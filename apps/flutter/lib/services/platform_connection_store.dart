import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/connection.dart';
import 'connection_store.dart';

const serverUrlPreferenceKey = 'dev.arsfeld.stashplayer.flutter.server_url';
const apiKeySecureStorageKey = 'dev.arsfeld.stashplayer.flutter.api_key';

class PlatformConnectionStore implements ConnectionStore {
  PlatformConnectionStore({
    required SharedPreferencesAsync preferences,
    required FlutterSecureStorage secureStorage,
  }) : _preferences = preferences,
       _secureStorage = secureStorage;

  final SharedPreferencesAsync _preferences;
  final FlutterSecureStorage _secureStorage;

  static Future<PlatformConnectionStore> create() async =>
      PlatformConnectionStore(
        preferences: SharedPreferencesAsync(),
        secureStorage: const FlutterSecureStorage(),
      );

  @override
  Future<ConnectionConfig> load(Map<String, String> environment) =>
      loadEffective(environment);

  Future<ConnectionConfig> loadStored() async {
    final values = await Future.wait<Object?>([
      _preferences.getString(serverUrlPreferenceKey),
      _secureStorage.read(key: apiKeySecureStorageKey),
    ]);
    return ConnectionConfig(
      serverUrl: values[0] as String? ?? '',
      apiKey: values[1] as String? ?? '',
    );
  }

  Future<ConnectionConfig> loadEffective(
    Map<String, String> environment,
  ) async {
    final stored = await loadStored();
    return overlayEnvironment(stored, environment);
  }

  @override
  Future<void> save(ConnectionConfig config) => Future.wait<void>([
    _preferences.setString(serverUrlPreferenceKey, config.serverUrl),
    _secureStorage.write(key: apiKeySecureStorageKey, value: config.apiKey),
  ]);
}
