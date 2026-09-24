class ConnectionConfig {
  const ConnectionConfig({
    this.serverUrl = '',
    this.apiKey = '',
    this.socksProxy = '',
  });

  final String serverUrl;
  final String apiKey;

  /// `host` or `host:port` of a SOCKS5 proxy to reach the server through,
  /// or empty for a direct connection. Present because a Stash on a
  /// tailnet is reachable only through Tailscale's userspace SOCKS port
  /// when no interface exists to route to it.
  final String socksProxy;

  ConnectionConfig copyWith({
    String? serverUrl,
    String? apiKey,
    String? socksProxy,
  }) => ConnectionConfig(
    serverUrl: serverUrl ?? this.serverUrl,
    apiKey: apiKey ?? this.apiKey,
    socksProxy: socksProxy ?? this.socksProxy,
  );

  @override
  bool operator ==(Object other) =>
      other is ConnectionConfig &&
      other.serverUrl == serverUrl &&
      other.apiKey == apiKey &&
      other.socksProxy == socksProxy;

  @override
  int get hashCode => Object.hash(serverUrl, apiKey, socksProxy);
}

/// Overlays `STASH_URL` / `STASH_API_KEY` / `STASH_SOCKS_PROXY` process
/// environment values onto a stored [ConnectionConfig].
///
/// A field is overridden whenever its environment key is present at all —
/// including an explicitly empty value, which overrides a stored key for an
/// unauthenticated development server. An absent key leaves the stored
/// value untouched. This is the single source of truth for that precedence
/// rule; both the connection controller and the platform connection store
/// must route through it rather than reimplementing the `containsKey`
/// check.
ConnectionConfig overlayEnvironment(
  ConnectionConfig stored,
  Map<String, String> environment,
) => ConnectionConfig(
  serverUrl: environment.containsKey('STASH_URL')
      ? environment['STASH_URL']!
      : stored.serverUrl,
  apiKey: environment.containsKey('STASH_API_KEY')
      ? environment['STASH_API_KEY']!
      : stored.apiKey,
  socksProxy: environment.containsKey('STASH_SOCKS_PROXY')
      ? environment['STASH_SOCKS_PROXY']!
      : stored.socksProxy,
);
