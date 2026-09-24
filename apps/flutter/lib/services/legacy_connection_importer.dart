import 'dart:io';

import '../domain/connection.dart';
import 'legacy_config.dart';
import 'legacy_secret_reader.dart';

/// Rebuilds the connection a legacy (GTK / SwiftUI) Stash Player saved, so
/// a user upgraded into this client lands in their library rather than on
/// an empty connection screen. Only reads; the legacy data is left in
/// place so rolling back still works.
class LegacyConnectionImporter {
  LegacyConnectionImporter({
    required List<String> configPaths,
    required LegacySecretReader secrets,
  }) : _configPaths = configPaths,
       _secrets = secrets;

  final List<String> _configPaths;
  final LegacySecretReader _secrets;

  /// The first usable legacy connection, or null when there is none.
  /// Errors from the keyring propagate; the caller decides what a failed
  /// import means.
  Future<ConnectionConfig?> importConnection() async {
    for (final path in _configPaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final legacy = parseLegacyConfig(await file.readAsString());
      if (legacy == null) continue;
      return ConnectionConfig(
        serverUrl: legacy.serverUrl,
        apiKey: await _secrets.readApiKey() ?? '',
        socksProxy: legacy.socksProxy,
      );
    }
    return null;
  }
}
