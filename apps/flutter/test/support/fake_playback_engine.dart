import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:stash_player_flutter/features/player/playback_engine.dart';

/// One command [FakePlaybackEngine] received, in call order. Tests assert
/// against [FakePlaybackEngine.commands] to verify what a consumer (the
/// playback controller and scene screen built in Tasks 9-11) asked the
/// engine to do, without coupling assertions to a specific mocking
/// library.
sealed class PlaybackCommand {}

class OpenCommand implements PlaybackCommand {
  OpenCommand(this.uri, {required this.play});

  final Uri uri;
  final bool play;
}

class PlayCommand implements PlaybackCommand {}

class PauseCommand implements PlaybackCommand {}

class SeekCommand implements PlaybackCommand {
  SeekCommand(this.position);

  final Duration position;
}

class SetVolumeCommand implements PlaybackCommand {
  SetVolumeCommand(this.zeroToOne);

  final double zeroToOne;
}

class SetMutedCommand implements PlaybackCommand {
  SetMutedCommand(this.muted);

  final bool muted;
}

class DisposeCommand implements PlaybackCommand {}

/// Deterministic [PlaybackEngine] test double for every test above the
/// `media_kit` boundary (Tasks 9-11: the playback controller, activity
/// sync, and scene screen). Every stream is a broadcast [StreamController]
/// the test drives directly via the `emit*` methods; every command call is
/// recorded in [commands] rather than acted on.
///
/// [dispose] is idempotent — a second call is a safe no-op, matching
/// [PlaybackEngine.dispose]'s contract. Every other command throws a
/// [StateError] once this engine has been disposed, so a consumer that
/// leaks an engine (keeps driving it past its own teardown) fails the
/// test that exercises it instead of silently no-op'ing.
class FakePlaybackEngine implements PlaybackEngine {
  final List<PlaybackCommand> commands = [];

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _errorsController =
      StreamController<String>.broadcast();

  bool _disposed = false;

  /// Whether [dispose] has been called. Exposed so a test can assert a
  /// consumer tore this engine down without inspecting [commands].
  bool get isDisposed => _disposed;

  @override
  Stream<bool> get playing => _playingController.stream;

  @override
  Stream<bool> get buffering => _bufferingController.stream;

  @override
  Stream<Duration> get position => _positionController.stream;

  @override
  Stream<Duration> get duration => _durationController.stream;

  @override
  Stream<String> get errors => _errorsController.stream;

  void emitPlaying(bool value) => _playingController.add(value);

  void emitBuffering(bool value) => _bufferingController.add(value);

  void emitPosition(Duration value) => _positionController.add(value);

  void emitDuration(Duration value) => _durationController.add(value);

  void emitError(String message) => _errorsController.add(message);

  @override
  Widget buildVideoSurface({Key? key}) => SizedBox.shrink(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false}) async {
    _checkNotDisposed();
    commands.add(OpenCommand(uri, play: play));
  }

  @override
  Future<void> play() async {
    _checkNotDisposed();
    commands.add(PlayCommand());
  }

  @override
  Future<void> pause() async {
    _checkNotDisposed();
    commands.add(PauseCommand());
  }

  @override
  Future<void> seek(Duration position) async {
    _checkNotDisposed();
    commands.add(SeekCommand(position));
  }

  @override
  Future<void> setVolume(double zeroToOne) async {
    _checkNotDisposed();
    commands.add(SetVolumeCommand(zeroToOne));
  }

  @override
  Future<void> setMuted(bool muted) async {
    _checkNotDisposed();
    commands.add(SetMutedCommand(muted));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    commands.add(DisposeCommand());
    await _playingController.close();
    await _bufferingController.close();
    await _positionController.close();
    await _durationController.close();
    await _errorsController.close();
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError(
        'FakePlaybackEngine: command issued after dispose() — the engine '
        "leaked past its consumer's teardown.",
      );
    }
  }
}
