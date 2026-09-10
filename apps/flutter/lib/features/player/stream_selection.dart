import '../../domain/scene.dart';
import '../../domain/scene_stream.dart';
import '../../services/authenticated_url.dart';

/// Which of a scene's streams is playing, what else it could be playing,
/// and where to go next when the current one will not start.
///
/// Pure and immutable: no engine, no async, no connection. Every
/// transition returns a new selection, the way [PlaybackState] does, so
/// the ladder's rules are testable without driving a player.
///
/// The ladder is deliberately shorter than [options]. The menu lists
/// everything Stash offered, but the automatic path only ever tries
/// `direct -> HLS -> MP4`: DASH covers the same ground as HLS, and a
/// longer ladder only means a longer worst case before the viewer gets a
/// picture.
class StreamSelection {
  const StreamSelection._({
    required this.options,
    required this.current,
    required this.isManual,
    required List<SceneStream> ladder,
    required SceneStream initial,
    required int rung,
  }) : _ladder = ladder,
       _initial = initial,
       _rung = rung;

  /// Builds the selection for [scene].
  ///
  /// [directFallback] is the scene's own `paths.stream`, resolved against
  /// the server but *not* authenticated. It is only used when Stash sent
  /// no endpoint list: an older server, or a scene with no primary file.
  /// In that case this reproduces exactly the two-entry world the player
  /// had before it could ask, so nothing regresses.
  factory StreamSelection.forScene(Scene scene, {required Uri directFallback}) {
    final options = scene.streams.isNotEmpty
        ? List<SceneStream>.unmodifiable(scene.streams)
        : List<SceneStream>.unmodifiable([
            SceneStream(
              url: directFallback,
              label: StreamKind.direct.defaultLabel,
              kind: StreamKind.direct,
            ),
            SceneStream(
              url: transcodedStreamUrl(directFallback),
              label: StreamKind.mp4.defaultLabel,
              kind: StreamKind.mp4,
            ),
          ]);

    final ladder = _buildLadder(options);
    return StreamSelection._(
      options: options,
      current: ladder.first,
      isManual: false,
      ladder: ladder,
      initial: ladder.first,
      rung: 0,
    );
  }

  /// The rungs the automatic path will try, in order, each at most once.
  ///
  /// Rung zero is whatever Stash listed first, which is the original file
  /// whenever there is one. A scene whose audio codec is invalid for its
  /// container gets no direct route at all, and then rung zero is a
  /// transcode: that is a first choice, not a fallback, which is why
  /// [hasSwitched] compares against it rather than against a kind.
  static List<SceneStream> _buildLadder(List<SceneStream> options) {
    SceneStream? firstOf(StreamKind kind) {
      for (final option in options) {
        if (option.kind == kind) return option;
      }
      return null;
    }

    final rungs = <SceneStream>[
      options.first,
      ?firstOf(StreamKind.hls),
      ?firstOf(StreamKind.mp4),
    ];

    // The first entry can itself be the HLS or MP4 one, and a scene can
    // legitimately offer only a single endpoint.
    final seen = <SceneStream>{};
    return List<SceneStream>.unmodifiable(rungs.where(seen.add));
  }

  /// Everything Stash offered, in the order it listed them. This is what
  /// the quality menu shows.
  final List<SceneStream> options;

  final SceneStream current;

  /// Whether the viewer chose [current] themselves. A manual pick stops
  /// the ladder: a stream someone deliberately selected must not be
  /// silently swapped out from under them.
  final bool isManual;

  final List<SceneStream> _ladder;
  final SceneStream _initial;
  final int _rung;

  /// Whether [current] is something other than what this scene started
  /// on. Compared against the initial stream rather than against
  /// `kind != direct`, for the no-direct-route reason on [_buildLadder],
  /// and so that manually returning to the original reads as a return
  /// rather than as another switch.
  bool get hasSwitched => current != _initial;

  /// The next rung to try, or `null` once the ladder is spent.
  SceneStream? nextRung() =>
      _rung + 1 < _ladder.length ? _ladder[_rung + 1] : null;

  /// Moves automatically onto [stream], which must be the value
  /// [nextRung] just returned.
  StreamSelection advance(SceneStream stream) => StreamSelection._(
    options: options,
    current: stream,
    isManual: isManual,
    ladder: _ladder,
    initial: _initial,
    rung: _rung + 1,
  );

  /// Moves onto [stream] because the viewer asked for it.
  StreamSelection choose(SceneStream stream) => StreamSelection._(
    options: options,
    current: stream,
    isManual: true,
    ladder: _ladder,
    initial: _initial,
    rung: _rung,
  );
}
