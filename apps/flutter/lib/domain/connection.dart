class ConnectionConfig {
  const ConnectionConfig({this.serverUrl = '', this.apiKey = ''});

  final String serverUrl;
  final String apiKey;

  ConnectionConfig copyWith({String? serverUrl, String? apiKey}) =>
      ConnectionConfig(
        serverUrl: serverUrl ?? this.serverUrl,
        apiKey: apiKey ?? this.apiKey,
      );

  @override
  bool operator ==(Object other) =>
      other is ConnectionConfig &&
      other.serverUrl == serverUrl &&
      other.apiKey == apiKey;

  @override
  int get hashCode => Object.hash(serverUrl, apiKey);
}

/// Overlays `STASH_URL` / `STASH_API_KEY` process environment values onto a
/// stored [ConnectionConfig].
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
);
