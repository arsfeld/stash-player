import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/scene_tile.dart';

void main() {
  group('SceneGridGeometry', () {
    test('fills the width with tiles no wider than the target', () {
      final geometry = SceneGridGeometry.resolve(
        availableWidth: 1000,
        textScaler: TextScaler.noScaling,
      );

      expect(geometry.columnCount, 4);
      expect(geometry.tileWidth, closeTo(238, 0.01));
      expect(
        geometry.tileWidth,
        lessThanOrEqualTo(SceneGridGeometry.maxTileWidth),
      );
    });

    test('never drops below one column', () {
      final geometry = SceneGridGeometry.resolve(
        availableWidth: 0,
        textScaler: TextScaler.noScaling,
      );

      expect(geometry.columnCount, 1);
      expect(geometry.tileHeight, greaterThan(0));
    });

    test('grows the tile with the text scale instead of shrinking type', () {
      final plain = SceneGridGeometry.resolve(
        availableWidth: 1000,
        textScaler: TextScaler.noScaling,
      );
      final scaled = SceneGridGeometry.resolve(
        availableWidth: 1000,
        textScaler: const TextScaler.linear(2),
      );

      expect(scaled.columnCount, plain.columnCount);
      expect(scaled.tileWidth, plain.tileWidth);
      expect(scaled.tileHeight, greaterThan(plain.tileHeight));
    });
  });

  group('SceneTile', () {
    testWidgets('renders one title size regardless of title length', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 200,
              child: SceneTile(
                scene: Scene(
                  id: '1',
                  paths: const ScenePaths(),
                  title:
                      'An extremely long scene title that would previously '
                      'have been shrunk to fit by the FittedBox',
                  files: const [],
                ),
                thumbnailRepository: null,
                onOpen: () {},
              ),
            ),
          ),
        ),
      );

      final title = tester.widget<Text>(
        find.textContaining('An extremely long'),
      );
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      // The tile shows a placeholder rather than failing when it has no
      // repository, which is the same path a failed fetch takes.
      expect(find.bySemanticsLabel('Thumbnail unavailable'), findsOneWidget);
    });

    testWidgets('opens on tap', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 200,
              child: SceneTile(
                scene: Scene(
                  id: '1',
                  paths: const ScenePaths(),
                  title: 'Kyoto Cherry Blossoms',
                  files: const [],
                ),
                thumbnailRepository: null,
                onOpen: () => opened++,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Kyoto Cherry Blossoms'));
      await tester.pump();

      expect(opened, 1);
    });
  });
}
