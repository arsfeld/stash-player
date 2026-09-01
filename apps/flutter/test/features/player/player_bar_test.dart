import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/features/player/player_bar.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

Future<void> _pumpBar(
  WidgetTester tester, {
  required PlaybackState playback,
  ValueChanged<Duration>? onSeek,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: Scaffold(
      body: PlayerBar(
        playback: playback,
        onTogglePlayPause: () {},
        onSeek: onSeek ?? (_) {},
        onVolumeChanged: (_) {},
        onToggleMute: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('emits exactly one seek per drag gesture', (tester) async {
    // Committing a seek on every onChanged sample turns one drag into
    // dozens of GraphQL writes; the bar tracks the thumb locally and
    // seeks only from onChangeEnd.
    final seeks = <Duration>[];
    await _pumpBar(
      tester,
      playback: const PlaybackState(
        duration: Duration(minutes: 10),
        position: Duration(minutes: 1),
      ),
      onSeek: seeks.add,
    );

    final slider = find.byKey(const Key('scene-seek-bar'));
    final centre = tester.getCenter(slider);
    final gesture = await tester.startGesture(centre);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();

    expect(seeks, isEmpty);

    await gesture.up();
    await tester.pump();

    expect(seeks, hasLength(1));
  });

  testWidgets('disables the scrubber until a duration is known', (
    tester,
  ) async {
    await _pumpBar(tester, playback: const PlaybackState());

    final slider = tester.widget<Slider>(
      find.byKey(const Key('scene-seek-bar')),
    );
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);
  });

  testWidgets('keeps the volume slider addressable by its key', (tester) async {
    await _pumpBar(tester, playback: const PlaybackState(volume: 0.5));

    expect(find.byKey(const Key('scene-volume-slider')), findsOneWidget);
  });
}
