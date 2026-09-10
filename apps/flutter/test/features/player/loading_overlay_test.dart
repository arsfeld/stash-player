import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_stream.dart';
import 'package:stash_player_flutter/features/player/load_diagnostics.dart';
import 'package:stash_player_flutter/features/player/loading_overlay.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/features/player/stream_selection.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

Scene _scene({double? resumeTime}) => Scene(
  id: 's1',
  paths: const ScenePaths(stream: 'stream.mp4'),
  resumeTime: resumeTime,
  files: const [SceneFile(duration: 3600)],
);

PlaybackState _loading({
  LoadStage? stage = LoadStage.opening,
  Scene? scene,
  Duration buffered = Duration.zero,
}) => PlaybackState(
  scene: scene ?? _scene(),
  phase: PlaybackPhase.loading,
  loadStage: stage,
  buffered: buffered,
);

PlaybackState _stalled({Duration buffered = Duration.zero}) => PlaybackState(
  scene: _scene(),
  phase: PlaybackPhase.ready,
  playing: true,
  buffering: true,
  buffered: buffered,
);

/// A selection the automatic ladder has already stepped off its first
/// stream, which is the state the switching wording is about. The scene
/// carries no endpoint list, so this is the synthesized direct/MP4 pair,
/// built against Stash's real extensionless direct route so that the two
/// entries are genuinely different URLs.
StreamSelection _switched() {
  final selection = StreamSelection.forScene(
    _scene(),
    directFallback: Uri.parse('https://stash.test/scene/s1/stream'),
  );
  return selection.advance(selection.nextRung()!);
}

/// A scene with a real endpoint list, for the manual-pick case: choosing a
/// stream only means something when there is more than the synthesized
/// direct/MP4 pair to choose between.
Scene _streamedScene() => Scene(
  id: 's1',
  paths: const ScenePaths(stream: 'scene/s1/stream'),
  files: const [SceneFile(duration: 3600)],
  streams: [
    SceneStream.fromEndpoint(
      url: 'https://stash.test/scene/s1/stream',
      label: 'Direct stream',
    ),
    SceneStream.fromEndpoint(
      url: 'https://stash.test/scene/s1/stream.m3u8?resolution=ORIGINAL',
      label: 'HLS',
    ),
  ],
);

StreamSelection _selection() => StreamSelection.forScene(
  _streamedScene(),
  directFallback: Uri.parse('https://stash.test/scene/s1/stream'),
);

Future<void> _mount(WidgetTester tester, PlaybackState state) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: PlaybackLoadingOverlay(state: state),
        ),
      ),
    );

/// Mounts the overlay and waits out the grace period, which is the state
/// every test below except the grace test itself is about.
Future<void> _pump(WidgetTester tester, PlaybackState state) async {
  await _mount(tester, state);
  await tester.pump(loadingOverlayGrace + const Duration(milliseconds: 1));
}

void main() {
  group('staying out of the way of a fast load', () {
    testWidgets('shows nothing at all for a load that resolves quickly, '
        'rather than flashing a spinner', (tester) async {
      await _mount(tester, _loading());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('appears once the load has gone on longer than a blink', (
      tester,
    ) async {
      await _mount(tester, _loading());
      await tester.pump(loadingOverlayGrace + const Duration(milliseconds: 1));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('what it says it is waiting on', () {
    testWidgets('names the connection while the connection is resolving', (
      tester,
    ) async {
      await _pump(tester, _loading(stage: LoadStage.connecting));

      expect(find.textContaining('Connecting'), findsOneWidget);
    });

    testWidgets('names opening the video while the demuxer is reading it', (
      tester,
    ) async {
      await _pump(tester, _loading(stage: LoadStage.opening));

      expect(find.textContaining('Opening'), findsOneWidget);
    });

    testWidgets('names the position it is opening at, since opening an hour '
        'in is a slower thing than opening at the start', (tester) async {
      await _pump(
        tester,
        _loading(stage: LoadStage.opening, scene: _scene(resumeTime: 754)),
      );

      expect(find.textContaining('12:34'), findsOneWidget);
    });

    testWidgets('calls a mid-playback stall buffering rather than loading, '
        'because the two are not the same wait', (tester) async {
      await _pump(tester, _stalled());

      expect(find.textContaining('Buffering'), findsOneWidget);
      expect(find.textContaining('Opening'), findsNothing);
    });

    testWidgets('is announced to assistive technology', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _loading(stage: LoadStage.opening));

      expect(find.bySemanticsLabel(RegExp('Opening')), findsAtLeastNWidgets(1));
      handle.dispose();
    });
  });

  group('how long the wait has gone on', () {
    testWidgets('says nothing about elapsed time for a wait short enough not '
        'to need explaining', (tester) async {
      await _pump(tester, _loading());
      await tester.pump(const Duration(seconds: 1));

      // Exactly one line on screen: the headline, with no detail line
      // under it. Lowering either threshold puts a second `Text` here.
      expect(find.textContaining('Opening'), findsOneWidget);
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('starts reporting elapsed seconds once the wait drags on', (
      tester,
    ) async {
      await _pump(tester, _loading());
      await tester.pump(loadingElapsedThreshold + const Duration(seconds: 1));

      expect(find.textContaining('4s'), findsOneWidget);
    });

    testWidgets('reports how much has been cached once the wait is long, so '
        'a stall that is winning is distinguishable from a stuck one', (
      tester,
    ) async {
      await _pump(tester, _loading(buffered: const Duration(seconds: 8)));
      await tester.pump(loadingDetailThreshold + const Duration(seconds: 2));

      expect(find.textContaining('8s cached'), findsOneWidget);
    });

    testWidgets('says plainly when a long wait has cached nothing at all', (
      tester,
    ) async {
      await _pump(tester, _loading());
      await tester.pump(loadingDetailThreshold + const Duration(seconds: 2));

      expect(find.textContaining('nothing cached yet'), findsOneWidget);
    });
  });

  group('how much of the video it covers', () {
    testWidgets('scrims the surface during the initial load, when there is '
        'nothing behind it worth seeing', (tester) async {
      await _pump(tester, _loading());

      expect(
        tester.widget<ColoredBox>(find.byKey(loadingScrimKey)).color.a,
        greaterThan(0.0),
      );
    });

    testWidgets('leaves the picture alone during a mid-playback stall', (
      tester,
    ) async {
      await _pump(tester, _stalled());

      expect(find.byKey(loadingScrimKey), findsNothing);
    });
  });

  group('falling back to the transcode', () {
    testWidgets('says it is switching streams, rather than looking like an '
        'ordinary reload', (tester) async {
      await _pump(
        tester,
        PlaybackState(
          scene: _scene(),
          phase: PlaybackPhase.loading,
          loadStage: LoadStage.opening,
          streams: _switched(),
        ),
      );

      expect(find.textContaining('faster stream'), findsOneWidget);
      expect(find.textContaining('Opening video'), findsNothing);
    });

    testWidgets('goes back to plain wording once the switch has happened, so '
        'a later stall is not mislabelled as another switch', (tester) async {
      await _pump(
        tester,
        PlaybackState(
          scene: _scene(),
          phase: PlaybackPhase.ready,
          playing: true,
          buffering: true,
          streams: _switched(),
        ),
      );

      expect(find.textContaining('Buffering'), findsOneWidget);
      expect(find.textContaining('faster stream'), findsNothing);
    });

    testWidgets('names the stream when the viewer chose it, since they know '
        'what they asked for', (tester) async {
      final base = _selection();
      final chosen = base.choose(base.options.last);

      await _pump(
        tester,
        PlaybackState(
          scene: _streamedScene(),
          phase: PlaybackPhase.loading,
          loadStage: LoadStage.opening,
          streams: chosen,
        ),
      );

      expect(find.textContaining('Switching to HLS'), findsOneWidget);
      expect(find.textContaining('faster stream'), findsNothing);
    });

    testWidgets('stays generic when the player switched on its own, since '
        'naming a stream nobody chose only raises a question', (tester) async {
      final base = _selection();

      await _pump(
        tester,
        PlaybackState(
          scene: _streamedScene(),
          phase: PlaybackPhase.loading,
          loadStage: LoadStage.opening,
          streams: base.advance(base.nextRung()!),
        ),
      );

      expect(find.textContaining('faster stream'), findsOneWidget);
    });
  });
}
