import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene_stream.dart';
import 'package:stash_player_flutter/features/player/player_top_bar.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';
import 'package:stash_player_flutter/ui/widgets/window_chrome.dart';

const _topBar = PlayerTopBar(
  title: 'Scene 42',
  metadataOpen: false,
  onBack: _noop,
  onToggleMetadata: _noop,
  streamOptions: [],
  currentStream: null,
  onSelectStream: _noopSelectStream,
  onMenuOpenChanged: _noopMenuOpenChanged,
);

void _noop() {}
void _noopSelectStream(SceneStream stream) {}
void _noopMenuOpenChanged(bool open) {}

Future<void> _pump(WidgetTester tester, TargetPlatform platform, Widget body) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark).copyWith(platform: platform),
        home: Scaffold(body: body),
      ),
    );

final _backButton = find.byTooltip('Back to library');

SceneStream _endpoint(String url, String label) =>
    SceneStream.fromEndpoint(url: url, label: label);

final _direct = _endpoint('https://s.example/scene/1/stream', 'Direct stream');
final _hls = _endpoint('https://s.example/scene/1/stream.m3u8', 'HLS');

Future<void> _pumpQualityMenu(
  WidgetTester tester, {
  required List<SceneStream> options,
  SceneStream? current,
  ValueChanged<SceneStream>? onSelect,
  ValueChanged<bool>? onMenuOpenChanged,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: PlayerTopBar(
        title: 'A scene',
        metadataOpen: false,
        onBack: () {},
        onToggleMetadata: () {},
        streamOptions: options,
        currentStream: current,
        onSelectStream: onSelect ?? (_) {},
        onMenuOpenChanged: onMenuOpenChanged ?? (_) {},
      ),
    ),
  ),
);

void main() {
  // The macOS titlebar is transparent and full-size-content, which is a
  // *window*-level setting: the Flutter view extends under the system
  // traffic lights on every screen, not only the ones that use
  // `AppWindowChrome`. This bar is the scene screen's own top strip, so
  // it has to reserve the same inset. It did not, and the back button
  // rendered underneath the lights, which draw above the Flutter layer.
  testWidgets('on macOS the back button clears the traffic lights', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.macOS, _topBar);

    expect(tester.getTopLeft(_backButton).dx, AppTokens.trafficLightInset);
  });

  testWidgets('elsewhere it uses the ordinary strip inset', (tester) async {
    await _pump(tester, TargetPlatform.linux, _topBar);

    expect(tester.getTopLeft(_backButton).dx, AppTokens.stripInset);
  });

  // Clearing the lights horizontally is only half of it: the bar also has
  // to put its controls on the lights' centre line, or the back button
  // reads as floating above them.
  testWidgets('on macOS the back button sits on the lights centre line', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.macOS, _topBar);

    expect(tester.getCenter(_backButton).dy, closeTo(25.5, 1));
  });

  testWidgets('the back button responds to the pointer', (tester) async {
    // Player chrome is always dark, so its hovered state is a wash of the
    // glyph colour rather than the theme's control tokens. Before the
    // fix this button had no `Material` of its own, so its ink went to
    // the scene screen's `Scaffold`, behind the video. Asserting that
    // *an* ink rounded-rect appears, rather than its exact colour: the
    // highlight repacks its alpha through `withAlpha`, so the painted
    // value is a rounding step away from the declared one.
    await _pump(tester, TargetPlatform.linux, _topBar);

    final host = find.descendant(
      of: _backButton,
      matching: find.byType(Material),
    );
    expect(host, isNot(paints..rrect()));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(_backButton));
    await tester.pumpAndSettle();

    expect(host, paints..rrect());
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets('agrees with AppWindowChrome on $platform', (tester) async {
      // The point of the fix is not the number, it is that there is only
      // one source for it. Rendering both bars together is what would
      // fail if either grew its own constant again.
      await _pump(
        tester,
        platform,
        const Column(
          children: [
            AppWindowChrome(
              children: [
                SizedBox(
                  key: Key('probe'),
                  width: 40,
                  height: AppTokens.controlBandHeight,
                ),
              ],
            ),
            _topBar,
          ],
        ),
      );

      expect(
        tester.getTopLeft(_backButton).dx,
        tester.getTopLeft(find.byKey(const Key('probe'))).dx,
      );
    });
  }

  testWidgets('offers no menu when there is only one way to play the scene', (
    tester,
  ) async {
    await _pumpQualityMenu(tester, options: [_direct], current: _direct);

    expect(find.byTooltip('Video quality'), findsNothing);
  });

  testWidgets('lists every stream Stash offered, by its own label', (
    tester,
  ) async {
    await _pumpQualityMenu(tester, options: [_direct, _hls], current: _direct);

    await tester.tap(find.byTooltip('Video quality'));
    await tester.pumpAndSettle();

    expect(find.text('Direct stream'), findsOneWidget);
    expect(find.text('HLS'), findsOneWidget);
  });

  testWidgets('reports the chosen stream', (tester) async {
    SceneStream? chosen;
    await _pumpQualityMenu(
      tester,
      options: [_direct, _hls],
      current: _direct,
      onSelect: (stream) => chosen = stream,
    );

    await tester.tap(find.byTooltip('Video quality'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HLS'));
    await tester.pumpAndSettle();

    expect(chosen, _hls);
  });

  testWidgets('holds the controls open while the menu is, so the bar does '
      'not fade out from under it', (tester) async {
    final opens = <bool>[];
    await _pumpQualityMenu(
      tester,
      options: [_direct, _hls],
      current: _direct,
      onMenuOpenChanged: opens.add,
    );

    await tester.tap(find.byTooltip('Video quality'));
    await tester.pumpAndSettle();
    expect(opens, [true]);

    await tester.tap(find.text('HLS'));
    await tester.pumpAndSettle();
    expect(opens, [true, false]);
  });
}
