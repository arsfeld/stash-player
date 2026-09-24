import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/legacy_config.dart';

void main() {
  group('legacyConfigCandidates', () {
    test('macOS reads the directories-crate ProjectDirs path', () {
      expect(
        legacyConfigCandidates(
          isMacOS: true,
          environment: const {'HOME': '/Users/me'},
        ),
        [
          '/Users/me/Library/Application Support/one.arsfeld.stash-player/config.toml',
        ],
      );
    });

    test('Linux tries XDG_CONFIG_HOME first, then the host ~/.config', () {
      expect(
        legacyConfigCandidates(
          isMacOS: false,
          environment: const {
            'HOME': '/home/me',
            'XDG_CONFIG_HOME':
                '/home/me/.var/app/dev.arsfeld.stash-player/config',
          },
        ),
        [
          '/home/me/.var/app/dev.arsfeld.stash-player/config/stash-player/config.toml',
          '/home/me/.config/stash-player/config.toml',
        ],
      );
    });

    test('Linux without XDG_CONFIG_HOME lists ~/.config once', () {
      expect(
        legacyConfigCandidates(
          isMacOS: false,
          environment: const {'HOME': '/home/me'},
        ),
        ['/home/me/.config/stash-player/config.toml'],
      );
    });

    test('no HOME means no candidates', () {
      expect(
        legacyConfigCandidates(isMacOS: false, environment: const {}),
        isEmpty,
      );
    });
  });

  group('parseLegacyConfig', () {
    test('reads the URL and a SOCKS proxy', () {
      final config = parseLegacyConfig('''
stash_url = "https://stash.example.ts.net"
autoplay = true
volume = 0.5
proxy_url = "socks5h://127.0.0.1:1055"
''');
      expect(config?.serverUrl, 'https://stash.example.ts.net');
      expect(config?.socksProxy, '127.0.0.1:1055');
    });

    test('a config without proxy_url has no proxy', () {
      final config = parseLegacyConfig('stash_url = "http://nas:9999"');
      expect(config?.serverUrl, 'http://nas:9999');
      expect(config?.socksProxy, '');
    });

    test('an empty URL means nothing to import', () {
      expect(parseLegacyConfig('stash_url = ""'), isNull);
    });

    test('the legacy default placeholder URL means nothing to import', () {
      // What `Config::default()` wrote for a user who never configured a
      // server; the Rust `has_custom_stash_url` treats it as unset too.
      expect(
        parseLegacyConfig('stash_url = "https://stash.example.com"'),
        isNull,
      );
    });

    test('malformed TOML means nothing to import', () {
      expect(parseLegacyConfig('stash_url = "unterminated'), isNull);
    });

    test('a non-string URL means nothing to import', () {
      expect(parseLegacyConfig('stash_url = 42'), isNull);
    });
  });

  group('socksAddressFromProxyUrl', () {
    test('strips socks5 and socks5h schemes and a trailing slash', () {
      expect(
        socksAddressFromProxyUrl('socks5h://127.0.0.1:1055'),
        '127.0.0.1:1055',
      );
      expect(
        socksAddressFromProxyUrl('SOCKS5://proxy.lan:1080/'),
        'proxy.lan:1080',
      );
    });

    test('drops HTTP proxies, which the Flutter client cannot use', () {
      expect(socksAddressFromProxyUrl('http://proxy.lan:3128'), '');
    });

    test(
      'drops proxies with credentials, which the SOCKS setting cannot hold',
      () {
        expect(
          socksAddressFromProxyUrl('socks5h://user:pw@127.0.0.1:1055'),
          '',
        );
      },
    );

    test('drops an empty or schemeless value', () {
      expect(socksAddressFromProxyUrl(''), '');
      expect(socksAddressFromProxyUrl('127.0.0.1:1055'), '');
    });
  });
}
