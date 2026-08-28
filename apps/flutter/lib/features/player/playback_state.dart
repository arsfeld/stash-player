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
/// [volume]/[muted]/[fullscreen] preferences (which persist across scene
/// changes, unlike the engine-reported fields above), any [failure]
/// message, [generation], and any [controlFailure]/[controlFailureSequence].
///
/// Auto-hide visibility of the transport controls is *not* one of these
/// preferences, despite an earlier plan draft mandating a
/// `controlsVisible` field here: it is purely a widget-local UI concern
/// (`_SceneScreenState._controlsVisible` in `scene_screen.dart`, reset
/// per mount) with no reason to survive a scene change or be observable
/// outside the widget that owns the auto-hide timer — see that field's
/// own doc.
///
/// [generation] is bumped by every `PlaybackController.loadScene` call
/// and captured by every async operation it or a seek/volume/fullscreen
/// command starts; a result or stream event is only applied if its
/// captured generation still matches [generation] when it resolves —
/// see `PlaybackController`'s own class doc for why.
///
/// [failure] and [controlFailure] are deliberately two different fields,
/// not one. [failure] means "this scene could not be (or is no longer
/// being) loaded" — set only by `loadScene`'s own catch and by an
/// engine-reported stream error, both of which also drive [phase] to
/// [PlaybackPhase.failed]. [controlFailure] means "a control command
/// (play/pause/seek/volume/mute) failed" — set only by
/// `PlaybackController._runEngineCommand`, which deliberately does *not*
/// touch [phase] or [failure] at all (see that method's own doc for why
/// conflating the two was a real, reported defect: a merely-cosmetic
/// failed volume nudge used to permanently strand a scene in a terminal
/// `failed` phase it could never leave). [controlFailureSequence]
/// increments on every such command failure — a UI layer comparing it
/// against its own last-seen value (the same technique already used for
/// [phase]/`playing`/`buffering`, since a `ChangeNotifierProvider`-backed
/// controller's "previous" and "next" are the same mutable object and can
/// never be diffed by value) can detect *every* occurrence, including two
/// in a row with the identical message, which comparing [controlFailure]
/// by string value alone could not.
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
    this.failure,
    this.generation = 0,
    this.controlFailure,
    this.controlFailureSequence = 0,
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
  final String? failure;
  final int generation;

  /// Redacted message from the most recent failed control command
  /// (play/pause/seek/volume/mute) — see this class's own doc for why
  /// this is separate from [failure]. `null` until the first such
  /// failure for the current scene.
  final String? controlFailure;

  /// Bumped by every control-command failure, independent of [phase] and
  /// [failure] — see this class's own doc.
  final int controlFailureSequence;

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
    String? failure,
    int? generation,
    bool clearFailure = false,
    String? controlFailure,
    int? controlFailureSequence,
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
    failure: clearFailure ? null : (failure ?? this.failure),
    generation: generation ?? this.generation,
    controlFailure: controlFailure ?? this.controlFailure,
    controlFailureSequence:
        controlFailureSequence ?? this.controlFailureSequence,
  );
}
