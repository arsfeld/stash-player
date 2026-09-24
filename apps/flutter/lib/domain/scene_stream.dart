/// Which of Stash's stream routes an endpoint points at.
///
/// Classified from the URL's path extension rather than its label:
/// `GetSceneStreamPaths` builds every endpoint as the direct stream path
/// plus an extension, so the extension is structural, while the label is
/// user-facing English that upstream is free to reword.
enum StreamKind {
  direct,
  mkv,
  mp4,
  webm,
  hls,
  dash;

  /// Whether this stream can be seeked within, rather than having to be
  /// reopened at a new offset.
  ///
  /// True for the original file (served over range requests) and for the
  /// HLS and DASH manifests, which are emitted as VOD playlists that
  /// enumerate every segment of the whole file up front. Stash treats a
  /// jump of more than five segments as a seek and restarts its transcode
  /// at the requested one, so seeking a manifest is a supported operation
  /// rather than something that happens to work.
  ///
  /// False for the progressive `.mp4` and `.webm` transcodes, which are
  /// generated as they are sent: there is no timeline to move within, so
  /// moving means asking for a new stream that begins somewhere else.
  bool get hasRealTimeline => switch (this) {
    StreamKind.direct ||
    StreamKind.mkv ||
    StreamKind.hls ||
    StreamKind.dash => true,
    StreamKind.mp4 || StreamKind.webm => false,
  };

  /// Whether the engine's reported duration can be believed.
  ///
  /// Same split as [hasRealTimeline], and for the same reason: a stream
  /// produced as it is sent can only report how much of it has arrived,
  /// which climbs for the whole scene.
  bool get reportsTrueDuration => hasRealTimeline;

  /// What to call this stream when Stash sent no label. The schema makes
  /// `label` nullable, and these match the wording Stash uses when it
  /// does send one.
  String get defaultLabel => switch (this) {
    StreamKind.direct => 'Direct stream',
    StreamKind.mkv => 'MKV',
    StreamKind.mp4 => 'MP4',
    StreamKind.webm => 'WEBM',
    StreamKind.hls => 'HLS',
    StreamKind.dash => 'DASH',
  };

  static StreamKind fromUrl(Uri url) {
    final path = url.path;
    if (path.endsWith('.m3u8')) return StreamKind.hls;
    if (path.endsWith('.mpd')) return StreamKind.dash;
    if (path.endsWith('.mkv')) return StreamKind.mkv;
    if (path.endsWith('.webm')) return StreamKind.webm;
    if (path.endsWith('.mp4')) return StreamKind.mp4;
    return StreamKind.direct;
  }
}

/// One entry from Stash's `sceneStreams`: a way to play one scene.
///
/// [url] is stored exactly as Stash returned it, without an API key. The
/// key is applied at open time, because the same endpoint list outlives
/// any one connection resolve.
class SceneStream {
  const SceneStream({
    required this.url,
    required this.label,
    required this.kind,
  });

  factory SceneStream.fromEndpoint({required String url, String? label}) {
    final parsed = Uri.parse(url);
    final kind = StreamKind.fromUrl(parsed);
    return SceneStream(
      url: parsed,
      label: (label == null || label.isEmpty) ? kind.defaultLabel : label,
      kind: kind,
    );
  }

  final Uri url;

  /// Stash's own wording, shown verbatim in the quality menu. Carries the
  /// resolution ("HLS Full HD (1080p)"), which is why nothing here parses
  /// a resolution out of the URL separately.
  final String label;

  final StreamKind kind;

  /// Equality is on [url] alone: it is what actually identifies an
  /// endpoint, and it lets the menu mark the current entry without
  /// tracking object identity across a rebuilt selection.
  @override
  bool operator ==(Object other) => other is SceneStream && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'SceneStream($label, $url)';
}
