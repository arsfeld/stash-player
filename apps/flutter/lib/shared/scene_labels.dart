import '../domain/scene.dart';
import 'formatters.dart';

/// The one-line subtitle beneath a scene's title in the library: studio
/// and duration, matching what the released clients show.
///
/// Degrades to whichever half exists, and to an empty string when the
/// scene has neither. An empty subtitle shifts nothing, because the grid
/// fixes each tile's height rather than deriving it from content.
String sceneSubtitle(Scene scene) {
  final studio = scene.studio?.name;
  final duration = scene.files.isEmpty ? null : scene.files.first.duration;
  return [
    if (studio != null && studio.isNotEmpty) studio,
    if (duration != null) formatDuration(duration),
  ].join(' · ');
}
