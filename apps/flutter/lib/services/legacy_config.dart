import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

/// The connection fields the legacy GTK and SwiftUI clients persisted in
/// their `config.toml` (written by the Rust `stash-player-core` crate).
class LegacyConfig {
  const LegacyConfig({required this.serverUrl, required this.socksProxy});

  final String serverUrl;

  /// `host:port`, or empty. See [socksAddressFromProxyUrl].
  final String socksProxy;
}

/// Where the legacy clients' `config.toml` may be, most likely first.
///
/// The Rust clients used the `directories` crate's
/// `ProjectDirs::from("one", "arsfeld", "stash-player")`. On Linux that
/// resolves through `XDG_CONFIG_HOME` — inside the Flatpak, the per-app
/// `~/.var/app/…/config` — with the host `~/.config` as the non-Flatpak
/// location (also exposed read-only to the Flatpak by its manifest).
List<String> legacyConfigCandidates({
  required bool isMacOS,
  required Map<String, String> environment,
}) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return const [];
  if (isMacOS) {
    return [
      p.join(
        home,
        'Library',
        'Application Support',
        'one.arsfeld.stash-player',
        'config.toml',
      ),
    ];
  }
  final xdg = environment['XDG_CONFIG_HOME'];
  final roots = <String>{
    if (xdg != null && xdg.isNotEmpty) xdg,
    p.join(home, '.config'),
  };
  return [
    for (final root in roots) p.join(root, 'stash-player', 'config.toml'),
  ];
}

/// Parses a legacy `config.toml`, or returns null when it holds no usable
/// server URL (including when it isn't valid TOML at all).
LegacyConfig? parseLegacyConfig(String source) {
  final Map<String, dynamic> values;
  try {
    values = TomlDocument.parse(source).toMap();
  } on Object {
    return null;
  }
  final url = values['stash_url'];
  if (url is! String || url.trim().isEmpty) return null;
  final proxy = values['proxy_url'];
  return LegacyConfig(
    serverUrl: url.trim(),
    socksProxy: proxy is String ? socksAddressFromProxyUrl(proxy) : '',
  );
}

final _socksUrl = RegExp(r'^socks5h?://([^/@]+)/?$', caseSensitive: false);

/// Converts the legacy clients' `proxy_url` (a `socks5h://host:port` or
/// `http://…` URL) to the Flutter client's SOCKS setting (`host:port`).
///
/// Anything the Flutter client can't honour — HTTP proxies, credentials —
/// maps to empty (a direct connection), so the user sees a connection
/// failure they can fix on the connection screen, not a silently wrong
/// route.
String socksAddressFromProxyUrl(String proxyUrl) =>
    _socksUrl.firstMatch(proxyUrl.trim())?.group(1) ?? '';
