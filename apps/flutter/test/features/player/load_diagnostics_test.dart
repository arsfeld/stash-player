import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/features/player/load_diagnostics.dart';

import '../../support/fake_clock.dart';

Scene _scene({List<SceneFile> files = const []}) => Scene(
  id: 's1',
  paths: const ScenePaths(stream: 'stream.mp4'),
  files: files,
);

void main() {
  group('LoadTimeline stage accounting', () {
    test('reports every stage that ran, in order, with its own duration', () {
      final clock = FakeClock();
      final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);

      timeline.enter(LoadStage.connecting);
      clock.advance(const Duration(milliseconds: 12));
      timeline.enter(LoadStage.opening);
      clock.advance(const Duration(milliseconds: 8340));
      timeline.enter(LoadStage.starting);
      clock.advance(const Duration(milliseconds: 40));

      expect(
        timeline.finish(),
        contains('connect 12ms, open 8340ms, play 40ms'),
      );
    });

    test('omits a stage that never ran rather than reporting it as zero', () {
      final clock = FakeClock();
      final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);

      timeline.enter(LoadStage.connecting);
      clock.advance(const Duration(milliseconds: 5));
      timeline.enter(LoadStage.opening);
      clock.advance(const Duration(milliseconds: 300));
      timeline.enter(LoadStage.starting);
      clock.advance(const Duration(milliseconds: 10));

      final report = timeline.finish();

      expect(report, contains('connect 5ms, open 300ms, play 10ms'));
      expect(report, isNot(contains('connect 5ms, open 300ms, connect')));
    });

    test('names the scene it is reporting on', () {
      final timeline = LoadTimeline(sceneId: 's42', clock: FakeClock().now);
      timeline.enter(LoadStage.connecting);

      expect(timeline.finish(), contains('scene s42'));
    });

    test('totals the stages it timed', () {
      final clock = FakeClock();
      final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);

      timeline.enter(LoadStage.connecting);
      clock.advance(const Duration(milliseconds: 100));
      timeline.enter(LoadStage.opening);
      clock.advance(const Duration(milliseconds: 250));

      expect(timeline.finish(), contains('350ms total'));
    });

    test('carries a media description when one is given', () {
      final timeline = LoadTimeline(
        sceneId: 's1',
        clock: FakeClock().now,
        media: 'h265/aac mkv 4.2 GB',
      );
      timeline.enter(LoadStage.connecting);

      expect(timeline.finish(), contains('h265/aac mkv 4.2 GB'));
    });
  });

  group('LoadTimeline milestones', () {
    test('reports how long until playback actually started, measured from '
        'the beginning of the load rather than from play()', () {
      final clock = FakeClock();
      final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
      timeline.enter(LoadStage.connecting);
      clock.advance(const Duration(milliseconds: 400));
      timeline.finish();

      clock.advance(const Duration(milliseconds: 10200));

      expect(timeline.markPlaying(), contains('10600ms'));
    });

    test('says plainly that the engine reporting itself unpaused is not the '
        'same event as video appearing', () {
      final clock = FakeClock();
      final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
      timeline.enter(LoadStage.connecting);
      clock.advance(const Duration(milliseconds: 83));

      // The wording is the point. An earlier version of this said
      // "playing after 83ms" for a scene that took 65 seconds to show a
      // frame, because mpv reports not-paused long before it has data.
      // A report that can be read as "this load was fast" when the load
      // was not fast is worse than no report.
      expect(timeline.markPlaying(), isNot(contains('playing after')));
      expect(timeline.markPlaying.call(), isNull);
    });

    test('a milestone is news only the first time it happens', () {
      final clock = FakeClock();
      final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
      timeline.enter(LoadStage.connecting);

      expect(timeline.markPlaying(), isNotNull);
      clock.advance(const Duration(seconds: 5));
      expect(timeline.markPlaying(), isNull);
    });
  });

  group(
    'LoadTimeline stalls: the number that matches what the viewer felt',
    () {
      test('times a stall from the moment it starts to the moment data '
          'actually arrives', () {
        final clock = FakeClock();
        final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
        timeline.enter(LoadStage.connecting);
        clock.advance(const Duration(milliseconds: 90));

        timeline.markStalled();
        clock.advance(const Duration(milliseconds: 64958));
        final report = timeline.markUnstalled(const Duration(seconds: 12));

        expect(report, contains('64958ms'));
        expect(report, contains('12s cached'));
      });

      test('reports the first stall against the whole load, since that total '
          'is the wait the viewer actually sat through', () {
        final clock = FakeClock();
        final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
        timeline.enter(LoadStage.connecting);
        clock.advance(const Duration(milliseconds: 90));
        timeline.markStalled();
        clock.advance(const Duration(milliseconds: 64958));

        expect(timeline.markUnstalled(Duration.zero), contains('65048ms'));
      });

      test(
        'a later stall is reported on its own, not folded into the load',
        () {
          final clock = FakeClock();
          final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
          timeline.enter(LoadStage.connecting);
          timeline.markStalled();
          timeline.markUnstalled(Duration.zero);

          clock.advance(const Duration(seconds: 300));
          timeline.markStalled();
          clock.advance(const Duration(milliseconds: 1500));
          final report = timeline.markUnstalled(const Duration(seconds: 3));

          expect(report, contains('1500ms'));
          expect(report, isNot(contains('since the load started')));
        },
      );

      test(
        'ignores an unstall that follows no stall, so an engine that reports '
        'not-buffering on a loop cannot invent recoveries',
        () {
          final timeline = LoadTimeline(sceneId: 's1', clock: FakeClock().now);
          timeline.enter(LoadStage.connecting);

          expect(timeline.markUnstalled(Duration.zero), isNull);
        },
      );

      test('a repeated stall signal does not restart the clock on the stall '
          'already being timed', () {
        final clock = FakeClock();
        final timeline = LoadTimeline(sceneId: 's1', clock: clock.now);
        timeline.enter(LoadStage.connecting);

        timeline.markStalled();
        clock.advance(const Duration(seconds: 5));
        timeline.markStalled();
        clock.advance(const Duration(seconds: 5));

        expect(timeline.markUnstalled(Duration.zero), contains('10000ms'));
      });
    },
  );

  group('describeMedia', () {
    test('names the codecs, container, size and bitrate', () {
      final description = describeMedia(
        _scene(
          files: const [
            SceneFile(
              videoCodec: 'h265',
              audioCodec: 'aac',
              format: 'mkv',
              size: 4509715660,
              bitRate: 12500000,
            ),
          ],
        ),
      );

      expect(description, 'h265/aac mkv 4.2 GB 12.5 Mbps');
    });

    test('degrades to whatever the server actually reported', () {
      final description = describeMedia(
        _scene(files: const [SceneFile(videoCodec: 'h264')]),
      );

      expect(description, 'h264');
    });

    test('says so plainly when there is no file at all', () {
      expect(describeMedia(_scene()), 'no file details');
    });
  });
}
