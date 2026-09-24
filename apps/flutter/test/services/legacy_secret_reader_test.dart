import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/legacy_secret_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(legacySecretChannel, null));

  test('returns the key the platform found', () async {
    messenger.setMockMethodCallHandler(legacySecretChannel, (call) async {
      expect(call.method, 'readApiKey');
      return 'legacy-key';
    });
    expect(
      await const MethodChannelLegacySecretReader().readApiKey(),
      'legacy-key',
    );
  });

  test('returns null when the platform has no legacy item', () async {
    messenger.setMockMethodCallHandler(
      legacySecretChannel,
      (call) async => null,
    );
    expect(await const MethodChannelLegacySecretReader().readApiKey(), isNull);
  });

  test('returns null on a platform without the handler', () async {
    // No mock handler registered → MissingPluginException.
    expect(await const MethodChannelLegacySecretReader().readApiKey(), isNull);
  });

  test('propagates a backend failure', () async {
    messenger.setMockMethodCallHandler(legacySecretChannel, (call) async {
      throw PlatformException(code: 'lookup-failed', message: 'locked');
    });
    expect(
      const MethodChannelLegacySecretReader().readApiKey(),
      throwsA(isA<PlatformException>()),
    );
  });
}
