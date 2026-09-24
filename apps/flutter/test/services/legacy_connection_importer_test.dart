import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/services/legacy_connection_importer.dart';
import 'package:stash_player_flutter/services/legacy_secret_reader.dart';

class FakeLegacySecretReader implements LegacySecretReader {
  FakeLegacySecretReader([this.key]);

  final String? key;
  int reads = 0;

  @override
  Future<String?> readApiKey() async {
    reads++;
    return key;
  }
}

class _ThrowingLegacySecretReader implements LegacySecretReader {
  @override
  Future<String?> readApiKey() async =>
      throw PlatformException(code: 'lookup-failed');
}

void main() {
  late Directory dir;

  setUp(
    () async => dir = await Directory.systemTemp.createTemp('legacy-import'),
  );
  tearDown(() => dir.delete(recursive: true));

  String writeConfig(String name, String contents) {
    final file = File(p.join(dir.path, name))..writeAsStringSync(contents);
    return file.path;
  }

  test('imports URL, key, and SOCKS proxy', () async {
    final path = writeConfig(
      'config.toml',
      'stash_url = "https://stash.lan"\nproxy_url = "socks5h://127.0.0.1:1055"\n',
    );
    final importer = LegacyConnectionImporter(
      configPaths: [path],
      secrets: FakeLegacySecretReader('legacy-key'),
    );

    expect(
      await importer.importConnection(),
      const ConnectionConfig(
        serverUrl: 'https://stash.lan',
        apiKey: 'legacy-key',
        socksProxy: '127.0.0.1:1055',
      ),
    );
  });

  test('a missing key imports as empty (auth-less servers)', () async {
    final path = writeConfig('config.toml', 'stash_url = "http://nas:9999"');
    final importer = LegacyConnectionImporter(
      configPaths: [path],
      secrets: FakeLegacySecretReader(),
    );

    expect(
      await importer.importConnection(),
      const ConnectionConfig(serverUrl: 'http://nas:9999'),
    );
  });

  test(
    'a keyring failure still imports the URL and proxy, with an empty key',
    () async {
      final path = writeConfig(
        'config.toml',
        'stash_url = "https://stash.lan"\nproxy_url = "socks5h://127.0.0.1:1055"\n',
      );
      final importer = LegacyConnectionImporter(
        configPaths: [path],
        secrets: _ThrowingLegacySecretReader(),
      );

      expect(
        await importer.importConnection(),
        const ConnectionConfig(
          serverUrl: 'https://stash.lan',
          socksProxy: '127.0.0.1:1055',
        ),
      );
    },
  );

  test('skips missing and unusable candidates in order', () async {
    final unusable = writeConfig('bad.toml', 'stash_url = ""');
    final good = writeConfig('good.toml', 'stash_url = "http://second"');
    final importer = LegacyConnectionImporter(
      configPaths: [p.join(dir.path, 'absent.toml'), unusable, good],
      secrets: FakeLegacySecretReader(),
    );

    expect((await importer.importConnection())?.serverUrl, 'http://second');
  });

  test('no config means no import, and the keyring is never touched', () async {
    final secrets = FakeLegacySecretReader('legacy-key');
    final importer = LegacyConnectionImporter(
      configPaths: [p.join(dir.path, 'absent.toml')],
      secrets: secrets,
    );

    expect(await importer.importConnection(), isNull);
    expect(secrets.reads, 0);
  });
}
