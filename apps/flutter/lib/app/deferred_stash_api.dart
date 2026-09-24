import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/job.dart';
import '../domain/scan_options.dart';
import '../domain/scene.dart';
import '../domain/scene_filter.dart';
import '../services/stash_api.dart';
import 'providers.dart';

/// Forwards every [StashApi] call to whatever [stashApiProvider] resolves
/// to, resolving it lazily on each call rather than requiring one
/// synchronously at construction time.
///
/// [stashApiProvider] is a `FutureProvider`, but the library and tasks
/// providers share this adapter and their `ChangeNotifierProvider`s must
/// be handed back synchronously. Each is constructed with a [StashApi] it
/// can call immediately, and this adapter is what makes that true even
/// before the real one has resolved.
///
/// Resolving can throw a bare platform exception (secure storage or
/// keyring access denied, say) that is not a `Failure`, because it fails
/// before `HttpStashApi` ever runs. Callers have to be ready for that.
class DeferredStashApi implements StashApi {
  DeferredStashApi(this._ref);

  final Ref _ref;

  Future<StashApi> get _resolved => _ref.read(stashApiProvider.future);

  @override
  Future<String> version() async => (await _resolved).version();

  @override
  Future<Scene?> findScene(String id) async => (await _resolved).findScene(id);

  @override
  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  }) async =>
      (await _resolved).findScenes(filter, page: page, perPage: perPage);

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) async => (await _resolved).saveSceneActivity(
    id: id,
    resumeTime: resumeTime,
    playDuration: playDuration,
  );

  @override
  Future<int> incrementO(String id) async => (await _resolved).incrementO(id);

  @override
  Future<int> resetO(String id) async => (await _resolved).resetO(id);

  @override
  Future<ScanOptions> scanDefaults() async => (await _resolved).scanDefaults();

  @override
  Future<String> metadataScan(ScanOptions options) async =>
      (await _resolved).metadataScan(options);

  @override
  Future<List<Job>> jobQueue() async => (await _resolved).jobQueue();

  @override
  Future<Job?> findJob(String id) async => (await _resolved).findJob(id);
}
