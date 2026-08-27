Uri authenticatedUrl(Uri baseUri, String source, String apiKey) {
  final uri = Uri.tryParse(source)?.hasScheme == true
      ? Uri.parse(source)
      : baseUri.resolve(source);
  final hasApiKey = uri.queryParameters.keys.any(
    (key) => key.toLowerCase() == 'apikey',
  );
  if (hasApiKey || apiKey.isEmpty) return uri;

  final separator = uri.hasQuery ? '&' : '?';
  return Uri.parse(
    '$uri${separator}apikey=${Uri.encodeQueryComponent(apiKey)}',
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
