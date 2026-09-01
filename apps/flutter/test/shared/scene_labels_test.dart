import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/shared/scene_labels.dart';

Scene _scene({StudioRef? studio, double? duration}) => Scene(
  id: '1',
  paths: const ScenePaths(),
  studio: studio,
  files: duration == null ? const [] : [SceneFile(duration: duration)],
);

void main() {
  test('joins studio and duration', () {
    expect(
      sceneSubtitle(
        _scene(
          studio: const StudioRef(id: 's', name: 'Field Notes Films'),
          duration: 1620,
        ),
      ),
      'Field Notes Films · 27:00',
    );
  });

  test('falls back to whichever half exists', () {
    expect(
      sceneSubtitle(
        _scene(
          studio: const StudioRef(id: 's', name: 'Wild Lens'),
        ),
      ),
      'Wild Lens',
    );
    expect(sceneSubtitle(_scene(duration: 1620)), '27:00');
  });

  test('is empty when the scene has neither', () {
    expect(sceneSubtitle(_scene()), '');
  });
}
