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
