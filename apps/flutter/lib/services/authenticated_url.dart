Uri authenticatedUrl(Uri baseUri, String source, String apiKey) {
  final uri = Uri.tryParse(source)?.hasScheme == true
      ? Uri.parse(source)
      : baseUri.resolve(source);
  final hasApiKey = uri.queryParameters.keys.any(
    (key) => key.toLowerCase() == 'apikey',
  );
  if (hasApiKey || apiKey.isEmpty) return uri;

  return uri.replace(
    queryParameters: {...uri.queryParameters, 'apikey': apiKey},
  );
}

/// Stash's transcode of whatever [direct] points at: the same scene's
/// `stream` route with `.mp4` appended, beginning at [startAt].
///
/// The player falls back to this when the direct stream stalls with
/// nothing arriving. Some mp4s in a library are written with one `mdat`
/// box per chunk (measured: one in twenty-four), and libmpv's demuxer
/// walks every top-level box before it will play, which on a remote
/// library means downloading tens of megabytes of headers it discards.
/// Stash's transcode has none of that structure, so it starts in
/// seconds. It costs real quality (measured at 656 kbps against a
/// 2.8 Mbps original) and server CPU, which is why nothing reaches for
/// it until the direct stream has actually failed to make progress.
///
/// [startAt] goes into the URL rather than being seeked to afterwards,
/// because the transcode is generated as it is sent: it has no timeline
/// to seek within, and asking the engine to seek inside one fails. The
/// consequence is that the returned stream's own clock starts at zero,
/// so whoever opens it has to add [startAt] back to every position the
/// engine reports.
///
/// Idempotent in both respects: appending cannot happen twice, and a new
/// [startAt] replaces any previous one rather than stacking.
Uri transcodedStreamUrl(Uri direct, {Duration? startAt}) {
  final path = direct.path.endsWith('.mp4')
      ? direct.path
      : '${direct.path}.mp4';
  final query = Map<String, String>.from(direct.queryParameters);
  if (startAt != null && startAt > Duration.zero) {
    query['start'] = startAt.inSeconds.toString();
  } else {
    query.remove('start');
  }
  return direct.replace(
    path: path,
    queryParameters: query.isEmpty ? null : query,
  );
}

String redactSensitive(String text, {required String apiKey}) {
  var redacted = text;
  if (apiKey.isNotEmpty) redacted = redacted.replaceAll(apiKey, '***');
  redacted = redacted.replaceAllMapped(
    RegExp(r'(ApiKey\s*:\s*)[^\s,;]+', caseSensitive: false),
    (match) => '${match.group(1)}***',
  );
  return redacted.replaceAllMapped(
    RegExp(r'([?&]apikey=)[^&#\s]*', caseSensitive: false),
    (match) => '${match.group(1)}***',
  );
}
