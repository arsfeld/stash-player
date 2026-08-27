import '../../domain/scene.dart';

/// Where a [PlaybackState] sits in its load lifecycle.
///
/// `disposed` is a terminal phase set by `PlaybackController.dispose` —
/// unlike `LibraryState`, which never outlives its controller in a way
/// that matters, a stray reference to a disposed [PlaybackState] (e.g.
/// held by a widget mid-teardown) should be able to tell it's looking at
/// a dead controller's last snapshot.
enum PlaybackPhase { initial, loading, ready, failed, disposed }

/// Immutable snapshot of the playback controller: which [scene] is
/// loaded (if any), where it stands in [phase], the engine-reported
/// [playing]/[buffering]/[duration]/[position], the user-level
/// [volume]/[muted]/[fullscreen]/[controlsVisible] preferences (which
/// persist across scene changes, unlike the engine-reported fields
/// above), any [failure] message, and [generation].
///
/// [generation] is bumped by every `PlaybackController.loadScene` call
/// and captured by every async operation it or a seek/volume/fullscreen
/// command starts; a result or stream event is only applied if its
/// captured generation still matches [generation] when it resolves —
/// see `PlaybackController`'s own class doc for why.
class PlaybackState {
  const PlaybackState({
    this.scene,
    this.phase = PlaybackPhase.initial,
    this.playing = false,
    this.buffering = false,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.volume = 1.0,
    this.muted = false,
    this.fullscreen = false,
    this.controlsVisible = true,
    this.failure,
    this.generation = 0,
  });

  final Scene? scene;
  final PlaybackPhase phase;
  final bool playing;
  final bool buffering;

  /// `Duration.zero` doubles as "unknown" — no real media has a zero
  /// duration, and the engine hasn't reported one yet until its
  /// `duration` stream emits at least once for the current scene.
  final Duration duration;
  final Duration position;

  /// `0.0`-`1.0`, matching `PlaybackEngine.setVolume`'s scale.
  final double volume;
  final bool muted;
  final bool fullscreen;
  final bool controlsVisible;
  final String? failure;
  final int generation;

  PlaybackState copyWith({
    Scene? scene,
    PlaybackPhase? phase,
    bool? playing,
    bool? buffering,
    Duration? duration,
    Duration? position,
    double? volume,
    bool? muted,
    bool? fullscreen,
    bool? controlsVisible,
    String? failure,
    int? generation,
    bool clearFailure = false,
  }) => PlaybackState(
    scene: scene ?? this.scene,
    phase: phase ?? this.phase,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    duration: duration ?? this.duration,
    position: position ?? this.position,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    fullscreen: fullscreen ?? this.fullscreen,
    controlsVisible: controlsVisible ?? this.controlsVisible,
    failure: clearFailure ? null : (failure ?? this.failure),
    generation: generation ?? this.generation,
  );
}
