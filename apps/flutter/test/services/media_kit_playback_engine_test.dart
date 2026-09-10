import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/media_kit_playback_engine.dart';

/// One command [FakeMediaKitPlayerPort] received, in call order. Kept
/// local to this test file — it exercises [MediaKitPlaybackEngine]'s
/// internal seam, not the application-level [PlaybackEngine] surface that
/// `FakePlaybackEngine` (`test/support/fake_playback_engine.dart`) fakes
/// for Tasks 9-11.
sealed class PortCommand {}

class OpenCommand implements PortCommand {
  OpenCommand(this.uri, {required this.play});
  final Uri uri;
  final bool play;
}

class PlayCommand implements PortCommand {}

class PauseCommand implements PortCommand {}

class SeekCommand implements PortCommand {
  SeekCommand(this.position);
  final Duration position;
}

class SetVolumeCommand implements PortCommand {
  SetVolumeCommand(this.volume);
  final double volume;
}

class DisposeCommand implements PortCommand {}

class OptionCommand implements PortCommand {
  OptionCommand(this.name, this.value);
  final String name;
  final String value;
}

/// A [MediaKitPlayerPort] that never touches `package:media_kit` — no
/// native player is ever constructed by this test file. Deliberately does
/// *not* close its own stream controllers in [dispose]: that lets tests
/// push events through [emitPlaying] etc. after [MediaKitPlaybackEngine]
/// has disposed, to prove the engine cancelled its subscriptions (rather
/// than merely proving this fake's own controllers were closed).
class FakeMediaKitPlayerPort implements MediaKitPlayerPort {
  final List<PortCommand> commands = [];
  int disposeCalls = 0;

  /// Every option set on this port, last value wins, so a test can ask
  /// what libmpv was actually configured with rather than replaying the
  /// call sequence.
  final Map<String, String> options = {};

  /// The names of options set before the first [open]. mpv reads some
  /// options (`start`, and everything about the stream layer) only when
  /// it opens a file, so for those the ordering is the behaviour.
  final Set<String> optionsSetBeforeOpen = {};
  bool _opened = false;

  /// [commands] without the option traffic, for the tests that care about
  /// the play/pause/seek sequence rather than how libmpv was configured.
  List<PortCommand> get controlCommands =>
      commands.where((command) => command is! OptionCommand).toList();

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  @override
  Stream<bool> get playing => _playingController.stream;

  @override
  Stream<bool> get buffering => _bufferingController.stream;

  @override
  Stream<Duration> get buffer => _bufferController.stream;

  @override
  Stream<Duration> get position => _positionController.stream;

  @override
  Stream<Duration> get duration => _durationController.stream;

  @override
  Stream<String> get error => _errorController.stream;

  @override
  Stream<String> get log => _logController.stream;

  void emitPlaying(bool value) => _playingController.add(value);
  void emitBuffering(bool value) => _bufferingController.add(value);
  void emitBuffer(Duration value) => _bufferController.add(value);
  void emitPosition(Duration value) => _positionController.add(value);
  void emitDuration(Duration value) => _durationController.add(value);
  void emitError(String message) => _errorController.add(message);
  void emitLog(String prefix, String level, String text) =>
      _logController.add('[$prefix/$level] $text');

  @override
  Future<void> setOption(String name, String value) async {
    if (!_opened) optionsSetBeforeOpen.add(name);
    options[name] = value;
    commands.add(OptionCommand(name, value));
  }

  @override
  Future<void> open(Uri uri, {required bool play}) async {
    _opened = true;
    commands.add(OpenCommand(uri, play: play));
  }

  @override
  Future<void> play() async => commands.add(PlayCommand());

  @override
  Future<void> pause() async => commands.add(PauseCommand());

  @override
  Future<void> seek(Duration position) async =>
      commands.add(SeekCommand(position));

  @override
  Future<void> setVolume(double volume) async =>
      commands.add(SetVolumeCommand(volume));

  @override
  Future<void> dispose() async {
    disposeCalls++;
    commands.add(DisposeCommand());
  }
}

void main() {
  group('MediaKitPlaybackEngine', () {
    late FakeMediaKitPlayerPort port;
    late MediaKitPlaybackEngine engine;

    setUp(() {
      port = FakeMediaKitPlayerPort();
      engine = MediaKitPlaybackEngine.testable(port: port);
    });

    test('forwards open with the play flag', () async {
      final uri = Uri.parse('https://stash.example/scene/1.m3u8');
      await engine.open(uri, play: true);

      expect(port.controlCommands, hasLength(1));
      final command = port.controlCommands.single as OpenCommand;
      expect(command.uri, uri);
      expect(command.play, isTrue);
    });

    test('open defaults play to false', () async {
      final uri = Uri.parse('https://stash.example/scene/1.mp4');
      await engine.open(uri);

      final command = port.controlCommands.single as OpenCommand;
      expect(command.play, isFalse);
    });

    test('forwards play, pause, and seek', () async {
      await engine.play();
      await engine.pause();
      await engine.seek(const Duration(seconds: 42));

      expect(port.controlCommands, hasLength(3));
      expect(port.controlCommands[0], isA<PlayCommand>());
      expect(port.controlCommands[1], isA<PauseCommand>());
      expect(
        (port.controlCommands[2] as SeekCommand).position,
        const Duration(seconds: 42),
      );
    });

    group('setVolume', () {
      test('maps interface 0-1 to package 0-100 at the midpoint', () async {
        await engine.setVolume(0.5);

        final command = port.controlCommands.single as SetVolumeCommand;
        expect(command.volume, 50.0);
      });

      test('clamps above 1.0 to 100 rather than overshooting', () async {
        await engine.setVolume(1.5);

        final command = port.controlCommands.single as SetVolumeCommand;
        expect(command.volume, 100.0);
      });

      test('clamps below 0.0 to 0 rather than undershooting', () async {
        await engine.setVolume(-0.2);

        final command = port.controlCommands.single as SetVolumeCommand;
        expect(command.volume, 0.0);
      });
    });

    group('setMuted', () {
      test('mutes to zero and restores the prior volume on unmute', () async {
        await engine.setVolume(0.6);
        await engine.setMuted(true);
        await engine.setMuted(false);

        expect(port.controlCommands, hasLength(3));
        expect((port.controlCommands[0] as SetVolumeCommand).volume, 60.0);
        expect((port.controlCommands[1] as SetVolumeCommand).volume, 0.0);
        expect((port.controlCommands[2] as SetVolumeCommand).volume, 60.0);
      });

      test('does not forward a redundant mute/unmute call', () async {
        await engine.setMuted(false);

        expect(port.controlCommands, isEmpty);
      });

      test('remembers a volume change made while muted for unmute', () async {
        await engine.setVolume(0.6);
        await engine.setMuted(true);
        // Changing the target volume while muted must not itself forward
        // to the port — doing so would audibly un-mute the output.
        await engine.setVolume(0.2);
        await engine.setMuted(false);

        expect(port.controlCommands, hasLength(3));
        expect((port.controlCommands[0] as SetVolumeCommand).volume, 60.0);
        expect((port.controlCommands[1] as SetVolumeCommand).volume, 0.0);
        expect((port.controlCommands[2] as SetVolumeCommand).volume, 20.0);
      });
    });

    group('stream mapping', () {
      test('forwards playing, buffering, position, and duration', () async {
        final playingValues = <bool>[];
        final bufferingValues = <bool>[];
        final positionValues = <Duration>[];
        final durationValues = <Duration>[];

        engine.playing.listen(playingValues.add);
        engine.buffering.listen(bufferingValues.add);
        engine.position.listen(positionValues.add);
        engine.duration.listen(durationValues.add);

        port.emitPlaying(true);
        port.emitBuffering(true);
        port.emitPosition(const Duration(seconds: 3));
        port.emitDuration(const Duration(minutes: 2));
        await Future<void>.delayed(Duration.zero);

        expect(playingValues, [true]);
        expect(bufferingValues, [true]);
        expect(positionValues, [const Duration(seconds: 3)]);
        expect(durationValues, [const Duration(minutes: 2)]);
      });
    });

    group('errors', () {
      test('redacts an apikey query value from package error text', () async {
        final errors = <String>[];
        engine.errors.listen(errors.add);

        port.emitError(
          'Failed to open '
          'https://stash.example/scene/1.m3u8?apikey=super-secret-key: '
          'connection refused',
        );
        await Future<void>.delayed(Duration.zero);

        expect(errors, hasLength(1));
        expect(errors.single, isNot(contains('super-secret-key')));
        expect(errors.single, contains('apikey=***'));
      });

      test('redacts an ApiKey header value from package error text', () async {
        final errors = <String>[];
        engine.errors.listen(errors.add);

        port.emitError('request failed, ApiKey: super-secret-key rejected');
        await Future<void>.delayed(Duration.zero);

        expect(errors.single, isNot(contains('super-secret-key')));
        expect(errors.single, contains('ApiKey: ***'));
      });
    });

    group('proxy configuration', () {
      test('routes through the proxy when one is configured', () async {
        final tuned = MediaKitPlaybackEngine.testable(
          port: port,
          httpProxyUrl: 'http://127.0.0.1:5000',
        );
        addTearDown(tuned.dispose);
        await pumpEventQueue();

        expect(port.options['http-proxy'], 'http://127.0.0.1:5000');
      });

      test('sets no proxy at all when none is configured, rather than an '
          'empty one libmpv would try to use', () async {
        final tuned = MediaKitPlaybackEngine.testable(port: port);
        addTearDown(tuned.dispose);
        await pumpEventQueue();

        expect(port.options, isNot(contains('http-proxy')));
      });

      test('sets no throughput tuning, every candidate for which measured '
          'neutral or worse against the real server', () async {
        final tuned = MediaKitPlaybackEngine.testable(port: port);
        addTearDown(tuned.dispose);
        await pumpEventQueue();

        // `multiple_requests=1` took a 53-second load past 240 seconds and
        // an 8 MiB stream buffer read 255 MB instead of 70 MB. This test
        // is the tripwire: adding one back without a measurement fails
        // here first.
        expect(port.options.keys, isNot(contains('stream-lavf-o')));
        expect(port.options.keys, isNot(contains('stream-buffer-size')));
        expect(port.options.keys, isNot(contains('demuxer-readahead-secs')));
        expect(port.options.keys, isNot(contains('cache')));
      });
    });

    group('opening at a resume position', () {
      test('opens directly at the resume position instead of seeking after '
          'the file is already open', () async {
        await engine.open(
          Uri.parse('https://stash.example/scene/1.mp4'),
          startAt: const Duration(seconds: 31, milliseconds: 120),
        );

        // Ordering is the point: mpv reads `start` when it opens the
        // file. A seek issued after `open` returns arrives before the
        // demuxer has the file at all, which is why the real one failed
        // with `error running command _command(seek, 31.1200, absolute)`
        // and left the scene playing from zero.
        expect(port.options['start'], '31.12');
        expect(port.optionsSetBeforeOpen, contains('start'));
      });

      test('clears a previous scene\'s resume position, so a scene with no '
          'resume does not inherit one', () async {
        await engine.open(
          Uri.parse('https://stash.example/a.mp4'),
          startAt: const Duration(seconds: 31),
        );
        await engine.open(Uri.parse('https://stash.example/b.mp4'));

        expect(port.options['start'], '0');
      });
    });

    group('mpv log forwarding', () {
      test('forwards what the media backend says it is doing to the console, '
          'which is where a slow open is actually explained', () async {
        final lines = <String>[];
        final logged = MediaKitPlaybackEngine.testable(
          port: port,
          log: lines.add,
        );
        addTearDown(logged.dispose);

        port.emitLog('cache', 'info', 'Cache is not responding, waiting...');
        await Future<void>.delayed(Duration.zero);

        expect(
          lines,
          contains(
            allOf(contains('cache'), contains('Cache is not responding')),
          ),
        );
      });

      test('redacts the API key mpv prints when it opens the stream URL, '
          'which it does on every single load', () async {
        final lines = <String>[];
        final logged = MediaKitPlaybackEngine.testable(
          port: port,
          log: lines.add,
        );
        addTearDown(logged.dispose);

        port.emitLog(
          'ffmpeg',
          'info',
          'Opening https://stash.example/scene/1/stream?apikey=super-secret-key',
        );
        await Future<void>.delayed(Duration.zero);

        expect(lines.single, isNot(contains('super-secret-key')));
        expect(lines.single, contains('apikey=***'));
      });
    });

    group('dispose', () {
      test('disposes the underlying port exactly once', () async {
        await engine.dispose();
        await engine.dispose();

        expect(port.disposeCalls, 1);
      });

      test('closes the streams it exposes', () async {
        final done = Completer<void>();
        engine.playing.listen((_) {}, onDone: done.complete);

        await engine.dispose();

        await done.future.timeout(const Duration(seconds: 1));
      });

      test('cancels its subscriptions to the port on dispose', () async {
        await engine.dispose();

        // If the engine failed to cancel its subscription before closing
        // its own (now-closed) controller, this would try to add an event
        // to a closed StreamController and surface as an uncaught error
        // in this test's zone.
        port.emitPlaying(true);
        await Future<void>.delayed(Duration.zero);
      });
    });
  });
}
