import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/services/connection_store.dart';
import 'package:stash_player_flutter/services/stash_api.dart';

class FakeConnectionStore implements ConnectionStore {
  FakeConnectionStore({this.saved = const ConnectionConfig(), this.loadFuture});

  ConnectionConfig saved;

  /// When set, `load()` returns this instead of resolving `saved`
  /// immediately — lets tests hold a `load()` call pending (e.g. via a
  /// `Completer`) to exercise late-resolution behavior.
  final Future<ConnectionConfig>? loadFuture;

  final List<ConnectionConfig> saveCalls = <ConnectionConfig>[];

  @override
  Future<ConnectionConfig> load(Map<String, String> environment) =>
      loadFuture ?? Future.value(saved);

  @override
  Future<void> save(ConnectionConfig config) async {
    saveCalls.add(config);
    saved = config;
  }
}

class FakeStashApi implements StashApi {
  FakeStashApi({this.versionValue, this.versionFailure, this.versionFuture});

  final String? versionValue;
  final Failure? versionFailure;
  final Future<String>? versionFuture;

  @override
  Future<String> version() async {
    if (versionFailure case final Failure failure) throw failure;
    if (versionFuture case final Future<String> future) return future;
    return versionValue!;
  }

  @override
  Future<Scene?> findScene(String id) => throw UnimplementedError();

  @override
  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  }) => throw UnimplementedError();

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) => throw UnimplementedError();
}
