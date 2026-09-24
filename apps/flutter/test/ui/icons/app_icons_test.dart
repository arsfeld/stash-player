import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/platform_dialect.dart';
// Shown explicitly: the package's own barrel file also exports `Color` and
// `BlendMode` (its internal paint types, not dart:ui's), which collide with
// package:flutter/material.dart's when imported unprefixed. `encodeSvg` is
// all this test needs.
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart'
    show encodeSvg;

void main() {
  group('every icon has a drawable asset in both dialects', () {
    for (final dialect in PlatformDialect.values) {
      for (final icon in AppIcon.values) {
        test('${dialect.name} ${icon.name}', () {
          final file = File(icon.assetFor(dialect));
          expect(file.existsSync(), isTrue, reason: file.path);
          // Throws on anything flutter_svg can't render, which would
          // otherwise show up as a silently blank icon.
          encodeSvg(
            xml: file.readAsStringSync(),
            debugName: file.path,
            warningsAsErrors: true,
            enableClippingOptimizer: false,
            enableMaskingOptimizer: false,
            enableOverdrawOptimizer: false,
          );
        });
      }
    }
  });

  Future<SvgPicture> pumpIcon(
    WidgetTester tester,
    TargetPlatform platform, {
    Color? color,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, platform: platform),
        home: IconTheme(
          data: const IconThemeData(color: Color(0xFF123456), size: 20),
          child: AppIconView(AppIcon.play, color: color),
        ),
      ),
    );
    return tester.widget<SvgPicture>(find.byType(SvgPicture));
  }

  testWidgets('Adwaita draws the GNOME glyph', (tester) async {
    final svg = await pumpIcon(tester, TargetPlatform.linux);
    expect(
      (svg.bytesLoader as SvgAssetLoader).assetName,
      'assets/icons/gnome/media-playback-start.svg',
    );
  });

  testWidgets('macOS draws the Lucide glyph', (tester) async {
    final svg = await pumpIcon(tester, TargetPlatform.macOS);
    expect(
      (svg.bytesLoader as SvgAssetLoader).assetName,
      'assets/icons/lucide/play.svg',
    );
  });

  testWidgets('size and colour default to the ambient IconTheme', (
    tester,
  ) async {
    final svg = await pumpIcon(tester, TargetPlatform.linux);
    expect(svg.width, 20);
    expect(
      svg.colorFilter,
      const ColorFilter.mode(Color(0xFF123456), BlendMode.srcIn),
    );
  });

  testWidgets('an explicit colour wins', (tester) async {
    final svg = await pumpIcon(
      tester,
      TargetPlatform.linux,
      color: const Color(0xFFFF0000),
    );
    expect(
      svg.colorFilter,
      const ColorFilter.mode(Color(0xFFFF0000), BlendMode.srcIn),
    );
  });

  testWidgets('Lucide has no 10s seek glyph, so macOS badges one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, platform: TargetPlatform.macOS),
        home: const AppIconView(AppIcon.seekBack10, size: 24),
      ),
    );
    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('Adwaita has a real 10s glyph and no badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, platform: TargetPlatform.linux),
        home: const AppIconView(AppIcon.seekBack10, size: 24),
      ),
    );
    expect(find.text('10'), findsNothing);
  });
}
