import 'scene_stream.dart';

class ScenePage {
  ScenePage({required this.total, required List<Scene> scenes})
    : scenes = List.unmodifiable(scenes);

  final int total;
  final List<Scene> scenes;
}

class Scene {
  Scene({
    required this.id,
    required this.paths,
    this.title,
    this.details,
    this.date,
    this.rating100,
    this.resumeTime,
    this.playCount,
    this.playDuration,
    this.oCounter,
    List<SceneFile> files = const [],
    this.studio,
    List<PerformerRef> performers = const [],
    List<SceneStream> streams = const [],
  }) : files = List.unmodifiable(files),
       performers = List.unmodifiable(performers),
       streams = List.unmodifiable(streams);

  final String id;
  final ScenePaths paths;
  final String? title;
  final String? details;
  final String? date;
  final int? rating100;
  final double? resumeTime;
  final int? playCount;
  final double? playDuration;

  /// Stash's per-scene "O counter". `null` means the server reported no
  /// count at all, which is a different state from a real `0`: the first
  /// is an absence, the second is a scene nobody has counted yet. The
  /// player's O-counter controls key their sensitivity off that
  /// distinction.
  final int? oCounter;
  final List<SceneFile> files;
  final StudioRef? studio;
  final List<PerformerRef> performers;

  /// Every way Stash says this scene can be played, in the order it
  /// listed them: the original file first when its audio codec is valid
  /// for its container, then the MP4, WEBM, HLS and DASH transcodes at
  /// each resolution the server will serve.
  ///
  /// Empty on an older Stash, or for a scene with no primary file. A
  /// listing is not a promise: the endpoint list is filtered only on the
  /// server's maximum transcode size and the file's own resolution, so a
  /// server with no cache dir advertises HLS here and then refuses to
  /// serve it.
  final List<SceneStream> streams;

  String get displayTitle {
    if (title case final String value when value.isNotEmpty) return value;
    for (final file in files) {
      if (file.path case final String path) {
        final name = _filenameStem(path);
        if (name != null) return name;
      }
    }
    return 'Scene $id';
  }

  /// The duration Stash scanned from the file itself, or `null` when it
  /// reported none.
  ///
  /// Authoritative in a way the playback engine's own reported duration
  /// is not. A transcoded stream is produced as it is sent, so the engine
  /// can only ever report how much of it has arrived, and that number
  /// climbs for the whole scene. This one is measured from the original
  /// file and is correct from the moment the metadata loads, before a
  /// single byte of video has been fetched.
  Duration? get knownDuration {
    final seconds = files.isEmpty ? null : files.first.duration;
    if (seconds == null || seconds <= 0) return null;
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  double? get effectiveResume {
    final resume = resumeTime;
    if (resume == null || resume <= 0) return null;
    final duration = files.isEmpty ? null : files.first.duration;
    if (duration != null &&
        duration > 0 &&
        (resume >= duration - 10 || resume / duration >= .97)) {
      return null;
    }
    return resume;
  }
}

String? _filenameStem(String path) {
  final basename = path.split(RegExp(r'[/\\]')).last;
  if (basename.isEmpty) return null;
  final dot = basename.lastIndexOf('.');
  return dot > 0 ? basename.substring(0, dot) : basename;
}

class ScenePaths {
  const ScenePaths({this.screenshot, this.stream});

  final String? screenshot;
  final String? stream;
}

class SceneFile {
  const SceneFile({
    this.path,
    this.duration,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
    this.format,
    this.size,
    this.bitRate,
    this.frameRate,
  });

  final String? path;
  final double? duration;
  final int? width;
  final int? height;
  final String? videoCodec;

  /// The three fields below exist to answer "why did this take so long to
  /// start" rather than to be displayed. A codec pair plus a container
  /// plus a size is most of the question already: whether Stash is
  /// handing back the original file or transcoding it, and how much has
  /// to cross the wire before the first frame can be decoded.
  final String? audioCodec;

  /// Container, as Stash reports it (`mkv`, `mp4`, ...).
  final String? format;

  /// File size in bytes.
  final int? size;

  /// Overall bitrate in bits per second.
  final int? bitRate;
  final double? frameRate;
}

class StudioRef {
  const StudioRef({required this.id, required this.name});

  final String id;
  final String name;
}

class PerformerRef {
  const PerformerRef({required this.id, required this.name});

  final String id;
  final String name;
}
