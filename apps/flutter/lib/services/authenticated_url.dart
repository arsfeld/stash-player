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

/// Stash's progressive MP4 transcode of whatever [direct] points at: the
/// same scene's `stream` route with `.mp4` appended.
///
/// Reached only when Stash sent no endpoint list for a scene at all: an
/// older server, or a scene with no primary file. A current server
/// enumerates its own routes in `sceneStreams` and those are used exactly
/// as it gave them, so what is left for this to do is synthesize the
/// single MP4 entry such a server would have listed, which keeps the
/// fallback ladder two rungs long rather than one.
///
/// No playback offset travels through here. A progressive transcode is
/// produced as it is sent, so it has no timeline to seek within and a
/// starting point has to be baked into the URL as Stash's own `start=`
/// query parameter, but that happens where a stream is actually opened,
/// against whatever route was chosen. Doing it there rather than here is
/// what lets a WEBM endpoint stay one: appending `.mp4` to any route but
/// the direct stream asks Stash for something it does not serve.
///
/// Appending is idempotent, so a URL that is already the transcode comes
/// back unchanged and a retry cannot append twice.
Uri transcodedStreamUrl(Uri direct) => direct.replace(
  path: direct.path.endsWith('.mp4') ? direct.path : '${direct.path}.mp4',
);

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
