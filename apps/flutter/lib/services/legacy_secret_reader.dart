import 'package:flutter/services.dart';

/// Reads the API key the legacy GTK / SwiftUI clients stored, which lives
/// outside flutter_secure_storage's namespace: a Secret Service item with
/// attributes `application=stash-player`, `key=stash-api-key` on Linux, a
/// Keychain generic password (service `stash-player`, account
/// `stash-api-key`) on macOS.
abstract interface class LegacySecretReader {
  /// The stored key, or null when there is none.
  Future<String?> readApiKey();
}

/// Implemented natively in `linux/runner/my_application.cc` and
/// `macos/Runner/MainFlutterWindow.swift`.
const legacySecretChannel = MethodChannel('stash_player/legacy_secret');

class MethodChannelLegacySecretReader implements LegacySecretReader {
  const MethodChannelLegacySecretReader([this._channel = legacySecretChannel]);

  final MethodChannel _channel;

  @override
  Future<String?> readApiKey() async {
    try {
      return await _channel.invokeMethod<String>('readApiKey');
    } on MissingPluginException {
      // Windows, or a test host: there was never a legacy client there.
      return null;
    }
  }
}
