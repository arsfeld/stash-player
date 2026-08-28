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

/// A [MediaKitPlayerPort] that never touches `package:media_kit` — no
/// native player is ever constructed by this test file. Deliberately does
/// *not* close its own stream controllers in [dispose]: that lets tests
/// push events through [emitPlaying] etc. after [MediaKitPlaybackEngine]
/// has disposed, to prove the engine cancelled its subscriptions (rather
/// than merely proving this fake's own controllers were closed).
class FakeMediaKitPlayerPort implements MediaKitPlayerPort {
  final List<PortCommand> commands = [];
  int disposeCalls = 0;

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  @override
  Stream<bool> get playing => _playingController.stream;

  @override
  Stream<bool> get buffering => _bufferingController.stream;

  @override
  Stream<Duration> get position => _positionController.stream;

  @override
  Stream<Duration> get duration => _durationController.stream;

  @override
  Stream<String> get error => _errorController.stream;

  void emitPlaying(bool value) => _playingController.add(value);
  void emitBuffering(bool value) => _bufferingController.add(value);
  void emitPosition(Duration value) => _positionController.add(value);
  void emitDuration(Duration value) => _durationController.add(value);
  void emitError(String message) => _errorController.add(message);

  @override
  Future<void> open(Uri uri, {required bool play}) async {
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

      expect(port.commands, hasLength(1));
      final command = port.commands.single as OpenCommand;
      expect(command.uri, uri);
      expect(command.play, isTrue);
    });

    test('open defaults play to false', () async {
      final uri = Uri.parse('https://stash.example/scene/1.mp4');
      await engine.open(uri);

      final command = port.commands.single as OpenCommand;
      expect(command.play, isFalse);
    });

    test('forwards play, pause, and seek', () async {
      await engine.play();
      await engine.pause();
      await engine.seek(const Duration(seconds: 42));

      expect(port.commands, hasLength(3));
      expect(port.commands[0], isA<PlayCommand>());
      expect(port.commands[1], isA<PauseCommand>());
      expect(
        (port.commands[2] as SeekCommand).position,
        const Duration(seconds: 42),
      );
    });

    group('setVolume', () {
      test('maps interface 0-1 to package 0-100 at the midpoint', () async {
        await engine.setVolume(0.5);

        final command = port.commands.single as SetVolumeCommand;
        expect(command.volume, 50.0);
      });

      test('clamps above 1.0 to 100 rather than overshooting', () async {
        await engine.setVolume(1.5);

        final command = port.commands.single as SetVolumeCommand;
        expect(command.volume, 100.0);
      });

      test('clamps below 0.0 to 0 rather than undershooting', () async {
        await engine.setVolume(-0.2);

        final command = port.commands.single as SetVolumeCommand;
        expect(command.volume, 0.0);
      });
    });

    group('setMuted', () {
      test('mutes to zero and restores the prior volume on unmute', () async {
        await engine.setVolume(0.6);
        await engine.setMuted(true);
        await engine.setMuted(false);

        expect(port.commands, hasLength(3));
        expect((port.commands[0] as SetVolumeCommand).volume, 60.0);
        expect((port.commands[1] as SetVolumeCommand).volume, 0.0);
        expect((port.commands[2] as SetVolumeCommand).volume, 60.0);
      });

      test('does not forward a redundant mute/unmute call', () async {
        await engine.setMuted(false);

        expect(port.commands, isEmpty);
      });

      test('remembers a volume change made while muted for unmute', () async {
        await engine.setVolume(0.6);
        await engine.setMuted(true);
        // Changing the target volume while muted must not itself forward
        // to the port — doing so would audibly un-mute the output.
        await engine.setVolume(0.2);
        await engine.setMuted(false);

        expect(port.commands, hasLength(3));
        expect((port.commands[0] as SetVolumeCommand).volume, 60.0);
        expect((port.commands[1] as SetVolumeCommand).volume, 0.0);
        expect((port.commands[2] as SetVolumeCommand).volume, 20.0);
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
