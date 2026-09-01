import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/features/player/scene_metadata_drawer.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

import '../../support/contrast.dart';

final _scene = Scene(
  id: 's1',
  paths: ScenePaths(stream: 'stream.mp4'),
  title: 'A Real Title',
  details: 'Some details.',
  date: '2024-01-02',
  studio: StudioRef(id: 'st1', name: 'Acme Studio'),
  performers: [PerformerRef(id: 'p1', name: 'Jane Doe')],
  files: [
    SceneFile(
      duration: 125,
      width: 1920,
      height: 1080,
      videoCodec: 'h264',
      frameRate: 30,
    ),
  ],
);

Future<void> _pumpDrawer(WidgetTester tester, Brightness brightness) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: Scaffold(
        body: SizedBox(
          width: SceneMetadataDrawer.maxWidth,
          height: 900,
          child: SceneMetadataDrawer(scene: _scene, onClose: () {}),
        ),
      ),
    ),
  );
  // Settle, not a single pump: `MaterialApp` interpolates its theme
  // through an `AnimatedTheme`, so re-pumping the same tree at the other
  // brightness reports colours still mid-lerp from the previous one.
  await tester.pumpAndSettle();
}

/// The colour a [Text] actually renders in, after its own style has been
/// merged with the ambient [DefaultTextStyle]. Reading `Text.style`
/// instead would report `null` for the description, which sets no style
/// of its own and is exactly the case that broke.
Color _textColor(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  return paragraph.text.style!.color!;
}

/// The colour an [Icon] renders its glyph in, which for an [IconButton]
/// comes from the button's own resolved foreground rather than from the
/// [Icon] widget's `color` field.
Color _iconColor(WidgetTester tester, IconData icon) {
  final richText = tester.widget<RichText>(
    find.descendant(of: find.byIcon(icon), matching: find.byType(RichText)),
  );
  return (richText.text as TextSpan).style!.color!;
}

void main() {
  // The drawer's panel is always dark because it slides over video, but
  // every colour inside it used to come from the app theme, which is
  // not. In light mode that put near-black text on a near-black panel.
  // These two groups are the regression guard the 383 tests that shipped
  // it did not have: they assert colours, in both brightnesses, which is
  // the only way this defect is visible from a test at all.
  for (final brightness in Brightness.values) {
    group('SceneMetadataDrawer in ${brightness.name} mode', () {
      testWidgets('every label is legible on the panel', (tester) async {
        await _pumpDrawer(tester, brightness);

        const samples = <String, String>{
          'A Real Title': 'the title',
          '2024-01-02': 'the date',
          'Acme Studio': 'the studio',
          'Some details.': 'the description',
          'PERFORMERS': 'a section label',
          'Jane Doe': 'a performer chip',
          'Duration': 'a file-table label',
          'h264': 'a file-table value',
        };

        for (final MapEntry(key: text, value: role) in samples.entries) {
          final colour = _textColor(tester, text);
          expect(
            contrastRatio(colour, SceneMetadataDrawer.panelColor),
            greaterThan(4.5),
            reason:
                '$role renders $colour on '
                '${SceneMetadataDrawer.panelColor}, which is not readable',
          );
        }

        expect(
          contrastRatio(
            _iconColor(tester, Icons.close),
            SceneMetadataDrawer.panelColor,
          ),
          greaterThan(4.5),
          reason: 'the close glyph is not readable on the panel',
        );
      });
    });
  }

  testWidgets('renders identically in both themes, because its panel does', (
    tester,
  ) async {
    // The sharper form of the same guard: the drawer is theme-independent
    // by construction, so any colour inside it that still varies with the
    // app's brightness is a colour that will be wrong in one of them.
    await _pumpDrawer(tester, Brightness.light);
    final light = [
      _textColor(tester, 'A Real Title'),
      _textColor(tester, 'Some details.'),
      _textColor(tester, 'PERFORMERS'),
      _textColor(tester, 'Duration'),
      _textColor(tester, 'Jane Doe'),
      _iconColor(tester, Icons.close),
    ];

    await _pumpDrawer(tester, Brightness.dark);
    final dark = [
      _textColor(tester, 'A Real Title'),
      _textColor(tester, 'Some details.'),
      _textColor(tester, 'PERFORMERS'),
      _textColor(tester, 'Duration'),
      _textColor(tester, 'Jane Doe'),
      _iconColor(tester, Icons.close),
    ];

    expect(light, dark);
  });

  testWidgets('the close button has a Material to put its ink on', (
    tester,
  ) async {
    // The drawer used to be wrapped in a `Material(elevation: 8)` of its
    // own. When it became a hand-painted panel that went away, and the
    // close button's ripple started going to the scene screen's
    // Scaffold, behind the video. `find.ancestor` is the check that it
    // has one again, without asserting on any particular pixel.
    await _pumpDrawer(tester, Brightness.dark);

    expect(
      find.ancestor(
        of: find.byType(IconButton),
        matching: find.descendant(
          of: find.byType(SceneMetadataDrawer),
          matching: find.byType(Material),
        ),
      ),
      findsWidgets,
    );
  });
}
