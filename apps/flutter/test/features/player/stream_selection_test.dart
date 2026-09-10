import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_stream.dart';
import 'package:stash_player_flutter/features/player/stream_selection.dart';

final _direct = Uri.parse('https://s.example/scene/1/stream');

SceneStream _endpoint(String url, String label) =>
    SceneStream.fromEndpoint(url: url, label: label);

Scene _scene(List<SceneStream> streams) => Scene(
  id: '1',
  paths: const ScenePaths(stream: 'scene/1/stream'),
  streams: streams,
);

/// What a well-configured Stash returns for a scene it can transcode: the
/// original, then MP4 and HLS at each resolution it will serve.
List<SceneStream> _fullListing() => [
  _endpoint('https://s.example/scene/1/stream', 'Direct stream'),
  _endpoint('https://s.example/scene/1/stream.mp4?resolution=ORIGINAL', 'MP4'),
  _endpoint(
    'https://s.example/scene/1/stream.mp4?resolution=STANDARD',
    'MP4 Standard (480p)',
  ),
  _endpoint('https://s.example/scene/1/stream.m3u8?resolution=ORIGINAL', 'HLS'),
  _endpoint(
    'https://s.example/scene/1/stream.m3u8?resolution=STANDARD',
    'HLS Standard (480p)',
  ),
];

void main() {
  group('forScene', () {
    test('starts on the original and offers everything Stash listed', () {
      final selection = StreamSelection.forScene(
        _scene(_fullListing()),
        directFallback: _direct,
      );

      expect(selection.current.kind, StreamKind.direct);
      expect(selection.options, hasLength(5));
      expect(selection.isManual, isFalse);
      expect(selection.hasSwitched, isFalse);
    });

    test('synthesizes the original plus its MP4 transcode when Stash sent no '
        'endpoint list, so an older server still falls back', () {
      final selection = StreamSelection.forScene(
        _scene(const []),
        directFallback: _direct,
      );

      expect(selection.options, hasLength(2));
      expect(selection.current.kind, StreamKind.direct);
      expect(selection.options.last.kind, StreamKind.mp4);
      expect(selection.options.last.url.path, endsWith('/stream.mp4'));
    });
  });

  group('the ladder', () {
    test('prefers HLS over MP4, because a stall is a container problem and '
        'the picture should survive it', () {
      final selection = StreamSelection.forScene(
        _scene(_fullListing()),
        directFallback: _direct,
      );

      expect(selection.nextRung()!.kind, StreamKind.hls);
    });

    test('takes the first HLS entry, which is the original resolution', () {
      final selection = StreamSelection.forScene(
        _scene(_fullListing()),
        directFallback: _direct,
      );

      expect(selection.nextRung()!.label, 'HLS');
    });

    test('walks direct then HLS then MP4, each rung at most once, so a '
        'transcode that also stalls cannot restart the cycle', () {
      var selection = StreamSelection.forScene(
        _scene(_fullListing()),
        directFallback: _direct,
      );

      final hls = selection.nextRung()!;
      selection = selection.advance(hls);
      expect(selection.current.kind, StreamKind.hls);
      expect(selection.hasSwitched, isTrue);

      final mp4 = selection.nextRung()!;
      selection = selection.advance(mp4);
      expect(selection.current.kind, StreamKind.mp4);

      expect(selection.nextRung(), isNull);
    });

    test('falls straight to MP4 when the server offers no HLS', () {
      final selection = StreamSelection.forScene(
        _scene([
          _endpoint('https://s.example/scene/1/stream', 'Direct stream'),
          _endpoint(
            'https://s.example/scene/1/stream.mp4?resolution=ORIGINAL',
            'MP4',
          ),
        ]),
        directFallback: _direct,
      );

      expect(selection.nextRung()!.kind, StreamKind.mp4);
    });

    test('has nowhere to go when the original is all there is', () {
      final selection = StreamSelection.forScene(
        _scene([
          _endpoint('https://s.example/scene/1/stream', 'Direct stream'),
        ]),
        directFallback: _direct,
      );

      expect(selection.nextRung(), isNull);
    });

    test('starts on HLS when the file has no direct route at all, which is '
        'what Stash does for an audio codec its container cannot hold', () {
      final selection = StreamSelection.forScene(
        _scene([
          _endpoint(
            'https://s.example/scene/1/stream.m3u8?resolution=ORIGINAL',
            'HLS',
          ),
          _endpoint(
            'https://s.example/scene/1/stream.mp4?resolution=ORIGINAL',
            'MP4',
          ),
        ]),
        directFallback: _direct,
      );

      expect(selection.current.kind, StreamKind.hls);
      // Rung zero, so nothing has been switched away from yet.
      expect(selection.hasSwitched, isFalse);
      expect(selection.nextRung()!.kind, StreamKind.mp4);
    });
  });

  group('a manual pick', () {
    test('stops the ladder, because overriding a deliberate choice is the '
        'original complaint pointed the other way', () {
      final selection =
          StreamSelection.forScene(
            _scene(_fullListing()),
            directFallback: _direct,
          ).choose(
            _endpoint(
              'https://s.example/scene/1/stream.mp4?resolution=STANDARD',
              'MP4 Standard (480p)',
            ),
          );

      expect(selection.isManual, isTrue);
      expect(selection.current.label, 'MP4 Standard (480p)');
      expect(selection.hasSwitched, isTrue);
    });

    test('back to the original is a return, not a switch, so nothing '
        'announces one', () {
      final selection = StreamSelection.forScene(
        _scene(_fullListing()),
        directFallback: _direct,
      );
      final onHls = selection.advance(selection.nextRung()!);
      expect(onHls.hasSwitched, isTrue);

      final backToOriginal = onHls.choose(selection.current);

      expect(backToOriginal.hasSwitched, isFalse);
      expect(backToOriginal.isManual, isTrue);
    });
  });
}
