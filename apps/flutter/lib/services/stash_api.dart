import '../domain/job.dart';
import '../domain/scan_options.dart';
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

  /// Bumps the scene's O counter by one and returns the server's new
  /// count. The count is server-owned, so callers display what comes
  /// back rather than incrementing a local copy.
  Future<int> incrementO(String id);

  /// Sets the scene's O counter back to zero and returns the new count,
  /// which Stash reports rather than the caller assuming it.
  Future<int> resetO(String id);

  /// The options a scan from the Stash web UI's Tasks page would use — what
  /// it last saved, else the server's defaults, else covers only. See
  /// `resolveScanOptions`.
  Future<ScanOptions> scanDefaults();

  /// Queues a metadata scan of every library path with [options] and
  /// returns the id of the job Stash queued it under. The job is already in
  /// [jobQueue] by the time this returns.
  Future<String> metadataScan(ScanOptions options);

  /// Stash's queued and running jobs. Empty when the server reports none.
  /// A job leaves the queue once it ends.
  Future<List<Job>> jobQueue();

  /// The job with [id], whether it is still queued or among the few Stash
  /// keeps after they end (it forgets all but its ten most recent). Null
  /// when Stash no longer knows it. A job's final status is only visible
  /// here: it leaves [jobQueue] the moment it ends.
  Future<Job?> findJob(String id);
}
