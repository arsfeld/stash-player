import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/connection.dart';
import '../shared/diagnostics.dart';
import 'connection_store.dart';
import 'legacy_config.dart';
import 'legacy_connection_importer.dart';
import 'legacy_secret_reader.dart';

const serverUrlPreferenceKey = 'dev.arsfeld.stashplayer.flutter.server_url';
const apiKeySecureStorageKey = 'dev.arsfeld.stashplayer.flutter.api_key';

/// Plain preferences rather than secure storage: a proxy address is a
/// routing detail, not a credential.
const socksProxyPreferenceKey = 'dev.arsfeld.stashplayer.flutter.socks_proxy';

/// Set once the one-time import from the legacy GTK / SwiftUI client has
/// been attempted, whatever its outcome, so a user who later clears their
/// connection doesn't get the legacy one back.
const legacyImportAttemptedPreferenceKey =
    'dev.arsfeld.stashplayer.flutter.legacy_import_attempted';

class PlatformConnectionStore implements ConnectionStore {
  PlatformConnectionStore({
    required SharedPreferencesAsync preferences,
    required FlutterSecureStorage secureStorage,
    LegacyConnectionImporter? legacyImporter,
  }) : _preferences = preferences,
       _secureStorage = secureStorage,
       _legacyImporter = legacyImporter;

  final SharedPreferencesAsync _preferences;
  final FlutterSecureStorage _secureStorage;
  final LegacyConnectionImporter? _legacyImporter;

  /// Set for the duration of one [_importLegacy] run, so
  /// `AppController.bootstrap()` and `ConnectionController.load()` calling
  /// `load()` concurrently on first launch share it rather than both
  /// reading [legacyImportAttemptedPreferenceKey] as unset and running the
  /// import twice. Cleared once that run settles, whether it resolves or
  /// throws — [legacyImportAttemptedPreferenceKey] stays the source of
  /// truth for "already attempted" across separate calls; this only closes
  /// the race within one, and must not turn a transient failure into a
  /// permanently cached one.
  Future<ConnectionConfig?>? _legacyImport;

  static Future<PlatformConnectionStore> create() async =>
      PlatformConnectionStore(
        preferences: SharedPreferencesAsync(),
        // The file-based login keychain rather than the data-protection
        // one (the plugin's default): the latter needs a
        // keychain-access-groups entitlement tied to a provisioning
        // profile, which a Developer ID build doesn't have.
        secureStorage: const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        ),
        // The legacy clients only ever shipped on Linux and macOS.
        legacyImporter: Platform.isLinux || Platform.isMacOS
            ? LegacyConnectionImporter(
                configPaths: legacyConfigCandidates(
                  isMacOS: Platform.isMacOS,
                  environment: Platform.environment,
                ),
                secrets: const MethodChannelLegacySecretReader(),
              )
            : null,
      );

  @override
  Future<ConnectionConfig> load(Map<String, String> environment) =>
      loadEffective(environment);

  Future<ConnectionConfig> loadStored() async {
    final stored = await _readStored();
    if (stored.serverUrl.isNotEmpty) return stored;
    try {
      final imported = await (_legacyImport ??= _importLegacy());
      return imported ?? stored;
    } finally {
      // `finally` rather than after the await: `_importLegacy`'s own
      // preference reads/writes aren't wrapped in its try/catch (only the
      // actual import is), so a rejected future must still be cleared —
      // otherwise every later load() on this store would replay the same
      // failure forever instead of retrying.
      _legacyImport = null;
    }
  }

  Future<ConnectionConfig> _readStored() async {
    final values = await Future.wait<Object?>([
      _preferences.getString(serverUrlPreferenceKey),
      _secureStorage.read(key: apiKeySecureStorageKey),
      _preferences.getString(socksProxyPreferenceKey),
    ]);
    return ConnectionConfig(
      serverUrl: values[0] as String? ?? '',
      apiKey: values[1] as String? ?? '',
      socksProxy: values[2] as String? ?? '',
    );
  }

  /// The one-time import described at [legacyImportAttemptedPreferenceKey].
  /// Never throws: any failure leaves the user on the connection screen,
  /// exactly as if there had been nothing to import.
  Future<ConnectionConfig?> _importLegacy() async {
    final importer = _legacyImporter;
    if (importer == null) return null;
    if (await _preferences.getBool(legacyImportAttemptedPreferenceKey) ??
        false) {
      return null;
    }
    await _preferences.setBool(legacyImportAttemptedPreferenceKey, true);
    try {
      final imported = await importer.importConnection();
      if (imported != null) {
        await save(imported);
        logDiagnostic('connection', 'Imported the legacy client connection');
      }
      return imported;
    } on Object catch (error) {
      logDiagnostic('connection', 'Legacy connection import failed: $error');
      return null;
    }
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
    _preferences.setString(socksProxyPreferenceKey, config.socksProxy),
  ]);
}
