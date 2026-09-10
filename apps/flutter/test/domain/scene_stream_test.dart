import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene_stream.dart';

void main() {
  group('StreamKind.fromUrl', () {
    // Classified from the path extension rather than the label, because
    // Stash builds every endpoint as the direct stream path plus an
    // extension. Labels are user-facing English that upstream can reword.
    test('the extensionless direct route is the original file', () {
      expect(
        StreamKind.fromUrl(Uri.parse('https://s.example/scene/1/stream')),
        StreamKind.direct,
      );
    });

    test('classifies each transcode container by extension', () {
      const cases = {
        'stream.mp4': StreamKind.mp4,
        'stream.webm': StreamKind.webm,
        'stream.mkv': StreamKind.mkv,
        'stream.m3u8': StreamKind.hls,
        'stream.mpd': StreamKind.dash,
      };
      for (final entry in cases.entries) {
        expect(
          StreamKind.fromUrl(
            Uri.parse('https://s.example/scene/1/${entry.key}'),
          ),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('a resolution query does not disturb classification', () {
      expect(
        StreamKind.fromUrl(
          Uri.parse('https://s.example/scene/1/stream.m3u8?resolution=FULL_HD'),
        ),
        StreamKind.hls,
      );
    });
  });

  group('capabilities', () {
    // The split that matters: the original file over range requests, and
    // a VOD manifest that enumerates every segment up front, both have a
    // timeline to seek within. A live transcode produced as it is sent
    // does not.
    test('originals and manifests have a real timeline', () {
      for (final kind in [
        StreamKind.direct,
        StreamKind.mkv,
        StreamKind.hls,
        StreamKind.dash,
      ]) {
        expect(kind.hasRealTimeline, isTrue, reason: kind.name);
        expect(kind.reportsTrueDuration, isTrue, reason: kind.name);
      }
    });

    test('progressive transcodes have neither', () {
      for (final kind in [StreamKind.mp4, StreamKind.webm]) {
        expect(kind.hasRealTimeline, isFalse, reason: kind.name);
        expect(kind.reportsTrueDuration, isFalse, reason: kind.name);
      }
    });
  });

  group('SceneStream.fromEndpoint', () {
    test('keeps the label Stash sent, verbatim', () {
      final stream = SceneStream.fromEndpoint(
        url: 'https://s.example/scene/1/stream.m3u8?resolution=FULL_HD',
        label: 'HLS Full HD (1080p)',
      );
      expect(stream.label, 'HLS Full HD (1080p)');
      expect(stream.kind, StreamKind.hls);
    });

    test('falls back to the kind name when Stash sent no label, since the '
        'schema makes it nullable', () {
      final stream = SceneStream.fromEndpoint(
        url: 'https://s.example/scene/1/stream',
      );
      expect(stream.label, 'Direct stream');
    });

    test('two endpoints with the same URL are equal, so the menu can mark '
        'the current one without identity tracking', () {
      final a = SceneStream.fromEndpoint(
        url: 'https://s.example/a',
        label: 'A',
      );
      final b = SceneStream.fromEndpoint(
        url: 'https://s.example/a',
        label: 'A',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
