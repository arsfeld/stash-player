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
// all this test needs, plus `parseWithoutOptimizers` for the "does this
// glyph actually paint anything" check below.
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart'
    show encodeSvg, parseWithoutOptimizers;

// A `fill`/`stroke` of the form `url(#id)`, with or without a trailing
// fallback colour (`url(#id) rgb(0,0,0)`) — GNOME's GPA source SVGs paint
// this way, referencing a paint server GTK's own editor supplies at
// runtime. `tool/fetch_icons.py`'s `flatten_gpa` step rewrites every one
// of these to its fallback colour, since vector_graphics_compiler 1.3.0
// (flutter_svg's backend) drops the whole paint silently, rather than
// falling back to the trailing colour the way CSS would, when `#id`
// doesn't resolve — the icon renders with no fill and no stroke at all.
// A leftover reference here means an icon that will render blank.
// Captures whatever sits between `url(` and its closing `)` verbatim,
// quoting included: ElementTree (`tool/fetch_icons.py`'s serializer) can
// round-trip a literal `"` inside a double-quoted attribute as the
// entity `&quot;`, not the character itself, so a quote-character class
// like `["']?` would silently miss it. `_paintUrlRefId` below strips
// whichever wrapper (if any) actually shows up.
final _paintUrlPattern = RegExp(r'''(?:fill|stroke)=["']url\(([^)]*)\)''');
final _idPattern = RegExp(r'''\bid=["']([^"']+)["']''');
const _quoteWrappers = ['&quot;', '&apos;', '"', "'"];

/// The `#id` a `url(...)` fill/stroke's raw inner text refers to, or
/// `null` if it isn't a `#`-fragment reference at all.
String? _paintUrlRefId(String rawInner) {
  var inner = rawInner.trim();
  for (final wrapper in _quoteWrappers) {
    if (inner.startsWith(wrapper)) inner = inner.substring(wrapper.length);
  }
  for (final wrapper in _quoteWrappers) {
    if (inner.endsWith(wrapper)) {
      inner = inner.substring(0, inner.length - wrapper.length);
    }
  }
  inner = inner.trim();
  return inner.startsWith('#') ? inner.substring(1) : null;
}

/// The `url(#id)` fill/stroke references in [xml] whose `#id` is not
/// defined anywhere in the same file (so can never resolve).
Iterable<String> _danglingPaintReferences(String xml) {
  final definedIds = _idPattern
      .allMatches(xml)
      .map((match) => match.group(1))
      .toSet();
  return _paintUrlPattern
      .allMatches(xml)
      .map((match) => _paintUrlRefId(match.group(1)!))
      .whereType<String>()
      .where((ref) => !definedIds.contains(ref));
}

/// Every `.svg` file directly under [dir], for a check that covers the
/// whole bundled set rather than only the files [AppIcon] currently
/// references.
Iterable<File> _svgFiles(String dir) => Directory(
  dir,
).listSync().whereType<File>().where((file) => file.path.endsWith('.svg'));

void main() {
  group('no bundled SVG references an undefined paint id', () {
    for (final dir in ['assets/icons/gnome', 'assets/icons/lucide']) {
      for (final file in _svgFiles(dir)) {
        test(file.path, () {
          expect(
            _danglingPaintReferences(file.readAsStringSync()),
            isEmpty,
            reason:
                '${file.path} has a fill/stroke url(#id) whose id is not '
                'defined in the file; vector_graphics_compiler drops such '
                'a paint instead of falling back, so the glyph renders '
                'blank',
          );
        });
      }
    }
  });

  group('every icon has a drawable asset in both dialects', () {
    for (final dialect in PlatformDialect.values) {
      for (final icon in AppIcon.values) {
        test('${dialect.name} ${icon.name}', () {
          final file = File(icon.assetFor(dialect));
          expect(file.existsSync(), isTrue, reason: file.path);
          final xml = file.readAsStringSync();
          // Throws on anything flutter_svg can't render, which would
          // otherwise show up as a silently blank icon.
          encodeSvg(
            xml: xml,
            debugName: file.path,
            warningsAsErrors: true,
            enableClippingOptimizer: false,
            enableMaskingOptimizer: false,
            enableOverdrawOptimizer: false,
          );
          // `encodeSvg` passing above is not itself evidence the glyph
          // draws anything: an unresolvable `url()` paint (see
          // `_paintUrlPattern`'s doc) parses without warning or error,
          // it is just silently dropped, leaving every path with no
          // fill and no stroke. Parse again and check some paint
          // actually made it through.
          final instructions = parseWithoutOptimizers(
            xml,
            key: file.path,
            warningsAsErrors: true,
          );
          expect(
            instructions.paints.any(
              (paint) => paint.fill != null || paint.stroke != null,
            ),
            isTrue,
            reason:
                '${file.path} parsed with zero fill/stroke paints - '
                'every path in it would render blank',
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

  test('every icon names an SF Symbol for native macOS surfaces', () {
    final symbolName = RegExp(r'^[a-z0-9]+(\.[a-z0-9]+)*$');
    for (final icon in AppIcon.values) {
      expect(icon.sfSymbol, matches(symbolName), reason: icon.name);
    }
  });
}
