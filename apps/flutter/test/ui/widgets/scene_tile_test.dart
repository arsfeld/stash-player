import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/shared/scene_placeholder.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';
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

  group('SceneTile pointer feedback', () {
    // The tile lost its hover and press feedback when the redesign
    // dropped the `Card` it used to sit in: its `InkWell` had no
    // `Material` of its own left, so every splash painted under the
    // `Scaffold`'s. Ink is the wrong mechanism here anyway, because an
    // ink feature paints beneath the opaque thumbnail no matter which
    // Material hosts it, so the tile expresses both states as a wash
    // over the artwork instead. These assertions are what make that wash
    // more than decoration.
    Future<void> pumpTile(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 200,
              child: SceneTile(
                scene: Scene(
                  id: '1',
                  paths: const ScenePaths(),
                  title: 'A scene',
                  files: const [],
                ),
                thumbnailRepository: null,
                onOpen: () {},
              ),
            ),
          ),
        ),
      ),
    );

    // The target colour, read after settling so it is also the rendered
    // one.
    Color wash(WidgetTester tester) {
      final container = tester.widget<AnimatedContainer>(
        find.byKey(const Key('scene-tile-wash')),
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    testWidgets('is invisible at rest, washes on hover, deepens on press', (
      tester,
    ) async {
      await pumpTile(tester);
      expect(wash(tester).a, 0, reason: 'an idle tile must not be washed');

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(SceneTile)));
      await tester.pumpAndSettle();
      final hovered = wash(tester);
      expect(hovered.a, greaterThan(0), reason: 'hover produces no feedback');

      await gesture.down(tester.getCenter(find.byType(SceneTile)));
      await tester.pump(kPressTimeout + const Duration(milliseconds: 50));
      final pressed = wash(tester);
      expect(
        pressed.a,
        greaterThan(hovered.a),
        reason: 'a press must read as more than a hover',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(wash(tester), hovered);
    });

    testWidgets('the wash animates over the hover duration', (tester) async {
      // Otherwise the token has nothing to drive here and the state
      // change is a hard flip.
      await pumpTile(tester);

      expect(
        tester
            .widget<AnimatedContainer>(find.byKey(const Key('scene-tile-wash')))
            .duration,
        AppTokens.hoverDuration,
      );
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
      // repository, which is the same path a failed fetch takes. The
      // placeholder's label merges into the tile's single outer button
      // semantics node on purpose, matching the convention documented in
      // `library_screen_test.dart`'s "a missing/failed thumbnail falls
      // back to the shared placeholder" test, so the widget type rather
      // than a standalone semantics label is the right thing to assert
      // here.
      expect(find.byType(ScenePlaceholder), findsOneWidget);
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

  group('SceneTile height fits SceneGridGeometry', () {
    // Regression coverage for a real overflow: the two tests above give
    // the tile a generous `SizedBox(height: 200)`, so neither ever
    // compared the tile's actual rendered height against what
    // `SceneGridGeometry` predicts for it. `SceneGrid` gives every tile a
    // *tight* height instead, via `SliverGridDelegateWithFixedCrossAxisCount`'s
    // `mainAxisExtent: geometry.tileHeight`, and a mismatch there throws
    // a `RenderFlex overflowed` exception in the real grid, which is
    // exactly what shipped undetected until the library screen started
    // rendering real data.
    Scene longTitledScene() => Scene(
      id: '1',
      paths: const ScenePaths(),
      title: 'A reasonably long scene title for overflow testing',
      files: const [],
    );

    Future<Size> measureNaturalHeight(
      WidgetTester tester, {
      required double tileWidth,
      required TextScaler textScaler,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: tileWidth,
                    child: SceneTile(
                      scene: longTitledScene(),
                      thumbnailRepository: null,
                      onOpen: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(SceneTile));
    }

    Future<void> pumpAtGeometryTightHeight(
      WidgetTester tester, {
      required double tileWidth,
      required double tileHeight,
      required TextScaler textScaler,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: tileWidth,
                    height: tileHeight,
                    child: SceneTile(
                      scene: longTitledScene(),
                      thumbnailRepository: null,
                      onOpen: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets(
      'fits within the geometry-predicted height at the default text scale',
      (tester) async {
        const textScaler = TextScaler.noScaling;
        final geometry = SceneGridGeometry.resolve(
          availableWidth: 1000,
          textScaler: textScaler,
        );

        final natural = await measureNaturalHeight(
          tester,
          tileWidth: geometry.tileWidth,
          textScaler: textScaler,
        );
        expect(natural.height, lessThanOrEqualTo(geometry.tileHeight));

        // Exercise the exact tight-constraint path `SceneGrid` uses.
        await pumpAtGeometryTightHeight(
          tester,
          tileWidth: geometry.tileWidth,
          tileHeight: geometry.tileHeight,
          textScaler: textScaler,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'fits within the geometry-predicted height at a raised text scale',
      (tester) async {
        const textScaler = TextScaler.linear(1.3);
        final geometry = SceneGridGeometry.resolve(
          availableWidth: 1000,
          textScaler: textScaler,
        );

        final natural = await measureNaturalHeight(
          tester,
          tileWidth: geometry.tileWidth,
          textScaler: textScaler,
        );
        expect(natural.height, lessThanOrEqualTo(geometry.tileHeight));

        await pumpAtGeometryTightHeight(
          tester,
          tileWidth: geometry.tileWidth,
          tileHeight: geometry.tileHeight,
          textScaler: textScaler,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
