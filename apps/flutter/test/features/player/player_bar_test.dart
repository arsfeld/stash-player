import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/features/player/player_bar.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

Future<void> _pumpBar(
  WidgetTester tester, {
  required PlaybackState playback,
  ValueChanged<Duration>? onSeek,
  SceneActionState actions = const SceneActionState(),
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onSkipBackward,
  VoidCallback? onSkipForward,
  VoidCallback? onIncrementO,
  VoidCallback? onResetO,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: Scaffold(
      body: PlayerBar(
        playback: playback,
        actions: actions,
        onTogglePlayPause: () {},
        onSeek: onSeek ?? (_) {},
        onVolumeChanged: (_) {},
        onToggleMute: () {},
        onPrevious: onPrevious ?? () {},
        onNext: onNext ?? () {},
        onSkipBackward: onSkipBackward ?? () {},
        onSkipForward: onSkipForward ?? () {},
        onIncrementO: onIncrementO ?? () {},
        onResetO: onResetO ?? () {},
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

  testWidgets('the transport reads prev, back, play, forward, next', (
    tester,
  ) async {
    await _pumpBar(
      tester,
      playback: const PlaybackState(playing: true),
      actions: const SceneActionState(
        canGoPrevious: true,
        canGoNext: true,
        oCount: 3,
      ),
    );

    // Read off the rendered geometry rather than the widget list, so a
    // Row rebuilt in a different order fails here.
    double x(String tooltip) => tester.getCenter(find.byTooltip(tooltip)).dx;

    expect(x('Previous scene'), lessThan(x('Back 10 seconds')));
    expect(x('Back 10 seconds'), lessThan(x('Pause')));
    expect(x('Pause'), lessThan(x('Forward 10 seconds')));
    expect(x('Forward 10 seconds'), lessThan(x('Next scene')));
  });

  testWidgets('the O-counter sits at the trailing edge', (tester) async {
    await _pumpBar(
      tester,
      playback: const PlaybackState(playing: true),
      actions: const SceneActionState(oCount: 3),
    );

    expect(
      tester.getCenter(find.byTooltip('Bump O-counter')).dx,
      greaterThan(tester.getCenter(find.byTooltip('Pause')).dx),
    );
  });

  testWidgets('each control fires its own callback', (tester) async {
    final fired = <String>[];
    await _pumpBar(
      tester,
      playback: const PlaybackState(playing: true),
      actions: const SceneActionState(
        canGoPrevious: true,
        canGoNext: true,
        oCount: 3,
      ),
      onPrevious: () => fired.add('previous'),
      onNext: () => fired.add('next'),
      onSkipBackward: () => fired.add('back'),
      onSkipForward: () => fired.add('forward'),
      onIncrementO: () => fired.add('bump'),
      onResetO: () => fired.add('reset'),
    );

    for (final tooltip in [
      'Previous scene',
      'Back 10 seconds',
      'Forward 10 seconds',
      'Next scene',
      'Bump O-counter',
      'Reset O-counter to 0',
    ]) {
      await tester.tap(find.byTooltip(tooltip));
    }
    await tester.pump();

    expect(fired, ['previous', 'back', 'forward', 'next', 'bump', 'reset']);
  });

  testWidgets('prev and next go dead at the ends of the ordering', (
    tester,
  ) async {
    final fired = <String>[];
    await _pumpBar(
      tester,
      playback: const PlaybackState(playing: true),
      actions: const SceneActionState(oCount: 0),
      onPrevious: () => fired.add('previous'),
      onNext: () => fired.add('next'),
    );

    await tester.tap(find.byTooltip('Previous scene'));
    await tester.tap(find.byTooltip('Next scene'));
    await tester.pump();

    expect(fired, isEmpty);
  });

  testWidgets('the reset button is absent at zero', (tester) async {
    // Nothing to reset, and a control that does nothing is worse than no
    // control.
    await _pumpBar(
      tester,
      playback: const PlaybackState(playing: true),
      actions: const SceneActionState(oCount: 0),
    );

    expect(find.byTooltip('Bump O-counter'), findsOneWidget);
    expect(find.byTooltip('Reset O-counter to 0'), findsNothing);
  });

  testWidgets('a null count makes the O-counter dead but still present', (
    tester,
  ) async {
    // Dead rather than hidden: the bar must not reflow every time a
    // prev/next fetch is in flight.
    final fired = <String>[];
    await _pumpBar(
      tester,
      playback: const PlaybackState(playing: true),
      actions: const SceneActionState(),
      onIncrementO: () => fired.add('bump'),
    );

    expect(find.byTooltip('Bump O-counter'), findsOneWidget);

    await tester.tap(find.byTooltip('Bump O-counter'));
    await tester.pump();

    expect(fired, isEmpty);
  });
}
