import '../../domain/scene.dart';

/// One stage of `PlaybackController.loadScene`, in the order they run.
///
/// These are the awaits that chain before a scene can play, split
/// out so both halves of "why is this slow" can name the same thing: the
/// overlay tells the viewer which one is taking the time, and
/// [LoadTimeline] tells the console how long each one took.
enum LoadStage {
  /// Resolving the server URL and API key.
  connecting,

  /// `PlaybackEngine.open` on the authenticated stream URL: the demuxer
  /// reading enough of the container to know what it is holding.
  opening,

  /// `PlaybackEngine.play` returning. Note that this is not the same
  /// moment as video appearing, which is why [LoadTimeline] tracks two
  /// further milestones after every stage has closed.
  starting,
}

/// How each stage reads in a log line.
String _stageLabel(LoadStage stage) => switch (stage) {
  LoadStage.connecting => 'connect',
  LoadStage.opening => 'open',
  LoadStage.starting => 'play',
};

/// Times one `loadScene` call, stage by stage, and formats what it
/// measured as console-ready lines.
///
/// Deliberately pure and clock-injected: everything this records is
/// derived from the [clock] passed at construction, so its formatting
/// (the part that is easy to get subtly wrong, and the part anyone
/// reading a slow-load report actually relies on) is testable without
/// real time passing.
///
/// A stage is only reported if it actually ran, rather than being
/// claimed at zero milliseconds.
///
/// The milestones are tracked separately from the stages, and measured
/// from the same start, because none of the stages measure the wait that
/// matters. Every one of them can close in under a tenth of a second on
/// a scene that takes over a minute to show a frame: `open` returns once
/// the demuxer accepts the URL, `play` returns once mpv accepts the
/// command, and mpv then reports itself unpaused while it has no data at
/// all. The whole real wait lands afterwards, in a buffering stall, which
/// is what [markStalled]/[markUnstalled] exist to time.
class LoadTimeline {
  LoadTimeline({
    required this.sceneId,
    required DateTime Function() clock,
    this.media,
  }) : _clock = clock;

  final String sceneId;
  final DateTime Function() _clock;

  /// A short description of what is being loaded (codecs, container,
  /// size), carried into the report so a slow load can be read against
  /// the file that caused it. See [describeMedia].
  final String? media;

  final List<(LoadStage, Duration)> _closed = [];
  DateTime? _startedAt;
  DateTime? _stageStartedAt;
  LoadStage? _current;
  bool _playingMarked = false;
  bool _finished = false;
  DateTime? _stalledAt;
  bool _stallReported = false;

  /// Whether [finish] has already run. A load can reach its end down
  /// either the success or the failure path, and both report; this keeps
  /// one that passes through both from reporting twice.
  bool get isFinished => _finished;

  /// Closes whichever stage was open and opens [stage].
  void enter(LoadStage stage) {
    final now = _clock();
    _startedAt ??= now;
    _closeCurrent(now);
    _current = stage;
    _stageStartedAt = now;
  }

  /// Closes the open stage and returns the stage report, ready to log.
  String finish() {
    _closeCurrent(_clock());
    _finished = true;
    return _stageReport();
  }

  /// Records the engine reporting itself unpaused for the first time.
  ///
  /// Deliberately *not* worded as "playing". mpv reports not-paused as
  /// soon as it accepts the play command, which on a slow link can be a
  /// full minute before a single frame is decoded. An earlier version of
  /// this line read "playing after 83ms" for a scene that took 65
  /// seconds to appear, which is worse than saying nothing: it invited
  /// exactly the wrong conclusion about where the time went. The number
  /// that answers that is [markUnstalled]'s.
  String? markPlaying() {
    if (_playingMarked) return null;
    _playingMarked = true;
    return 'scene $sceneId: engine unpaused after ${_sinceStart()} '
        '(not yet showing video)';
  }

  /// Records the engine going into a buffering stall. Idempotent while a
  /// stall is already being timed, so an engine that re-asserts the flag
  /// cannot restart the clock on the wait already in progress.
  void markStalled() {
    _stalledAt ??= _clock();
  }

  /// Closes the stall opened by [markStalled] and reports how long it
  /// lasted, with [buffered] as the cache it finally came back with.
  /// Returns `null` when no stall was open.
  ///
  /// The first stall of a load is reported against the whole load as
  /// well as against itself: for a scene that opens instantly and then
  /// sits buffering, that total is the only number in this class that
  /// matches the wait the viewer actually sat through.
  String? markUnstalled(Duration buffered) {
    final stalledAt = _stalledAt;
    if (stalledAt == null) return null;
    _stalledAt = null;

    final stall = _clock().difference(stalledAt).inMilliseconds;
    final cache = buffered > Duration.zero
        ? '${buffered.inSeconds}s cached'
        : 'nothing cached';
    if (_stallReported) {
      return 'scene $sceneId: stalled ${stall}ms, recovered with $cache';
    }
    _stallReported = true;
    return 'scene $sceneId: first stall lasted ${stall}ms, recovered with '
        '$cache; ${_sinceStart()} since the load started';
  }

  void _closeCurrent(DateTime now) {
    final stage = _current;
    final startedAt = _stageStartedAt;
    if (stage == null || startedAt == null) return;
    _closed.add((stage, now.difference(startedAt)));
    _current = null;
    _stageStartedAt = null;
  }

  String _stageReport() {
    final subject = media == null
        ? 'scene $sceneId'
        : 'scene $sceneId ($media)';
    if (_closed.isEmpty) return '$subject: nothing timed';

    final stages = _closed
        .map((entry) => '${_stageLabel(entry.$1)} ${entry.$2.inMilliseconds}ms')
        .join(', ');
    final total = _closed.fold(Duration.zero, (sum, entry) => sum + entry.$2);
    return '$subject: $stages; ${total.inMilliseconds}ms total';
  }

  String _sinceStart() {
    final startedAt = _startedAt;
    if (startedAt == null) return 'an unknown time';
    return '${_clock().difference(startedAt).inMilliseconds}ms';
  }
}

/// Describes [scene]'s first file the way a slow-load report needs it:
/// codecs, container, size, bitrate, in that order, skipping whatever
/// the server did not report rather than padding with placeholders.
///
/// Reports only the first file. A Stash scene can have several, but the
/// one being streamed is the one this describes, and `paths.stream`
/// resolves to that same first file.
String describeMedia(Scene scene) {
  if (scene.files.isEmpty) return 'no file details';
  final file = scene.files.first;

  final parts = <String>[
    if (_codecs(file) case final String codecs) codecs,
    if (file.format case final String format when format.isNotEmpty) format,
    if (file.size case final int size when size > 0) _formatBytes(size),
    if (file.bitRate case final int rate when rate > 0) _formatBitrate(rate),
  ];
  return parts.isEmpty ? 'no file details' : parts.join(' ');
}

String? _codecs(SceneFile file) {
  final video = file.videoCodec;
  final audio = file.audioCodec;
  final hasVideo = video != null && video.isNotEmpty;
  final hasAudio = audio != null && audio.isNotEmpty;
  if (hasVideo && hasAudio) return '$video/$audio';
  if (hasVideo) return video;
  if (hasAudio) return audio;
  return null;
}

String _formatBytes(int bytes) {
  const kib = 1024;
  const mib = kib * 1024;
  const gib = mib * 1024;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
  return '${(bytes / kib).toStringAsFixed(1)} KB';
}

String _formatBitrate(int bitsPerSecond) {
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).toStringAsFixed(0)} kbps';
}
