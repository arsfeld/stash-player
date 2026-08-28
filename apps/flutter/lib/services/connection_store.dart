import '../domain/connection.dart';

abstract interface class ConnectionStore {
  Future<ConnectionConfig> load(Map<String, String> environment);

  Future<void> save(ConnectionConfig config);
}
