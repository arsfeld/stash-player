import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';

void main() {
  group('overlayEnvironment — STASH_API_KEY', () {
    test('an absent key leaves the stored value intact', () {
      final result = overlayEnvironment(
        const ConnectionConfig(apiKey: 'stored-key'),
        const {},
      );

      expect(result.apiKey, 'stored-key');
    });

    test('an explicitly empty key overrides the stored value to empty', () {
      final result = overlayEnvironment(
        const ConnectionConfig(apiKey: 'stored-key'),
        const {'STASH_API_KEY': ''},
      );

      expect(result.apiKey, isEmpty);
    });

    test('a present non-empty key overrides the stored value', () {
      final result = overlayEnvironment(
        const ConnectionConfig(apiKey: 'stored-key'),
        const {'STASH_API_KEY': 'env-key'},
      );

      expect(result.apiKey, 'env-key');
    });
  });

  group('overlayEnvironment — STASH_URL', () {
    test('an absent key leaves the stored value intact', () {
      final result = overlayEnvironment(
        const ConnectionConfig(serverUrl: 'https://stored.test'),
        const {},
      );

      expect(result.serverUrl, 'https://stored.test');
    });

    test('an explicitly empty key overrides the stored value to empty', () {
      final result = overlayEnvironment(
        const ConnectionConfig(serverUrl: 'https://stored.test'),
        const {'STASH_URL': ''},
      );

      expect(result.serverUrl, isEmpty);
    });

    test('a present non-empty key overrides the stored value', () {
      final result = overlayEnvironment(
        const ConnectionConfig(serverUrl: 'https://stored.test'),
        const {'STASH_URL': 'https://env.test'},
      );

      expect(result.serverUrl, 'https://env.test');
    });
  });
}
