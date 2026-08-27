import '../domain/scene.dart';
import '../domain/scene_filter.dart';

abstract interface class StashApi {
  Future<String> version();

  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  });

  Future<Scene?> findScene(String id);

  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  });
}
