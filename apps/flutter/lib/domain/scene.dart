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
    List<SceneFile> files = const [],
    this.studio,
    List<PerformerRef> performers = const [],
  }) : files = List.unmodifiable(files),
       performers = List.unmodifiable(performers);

  final String id;
  final ScenePaths paths;
  final String? title;
  final String? details;
  final String? date;
  final int? rating100;
  final double? resumeTime;
  final int? playCount;
  final double? playDuration;
  final List<SceneFile> files;
  final StudioRef? studio;
  final List<PerformerRef> performers;

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
    this.frameRate,
  });

  final String? path;
  final double? duration;
  final int? width;
  final int? height;
  final String? videoCodec;
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
