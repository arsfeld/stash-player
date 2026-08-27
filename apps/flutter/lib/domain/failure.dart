sealed class Failure implements Exception {
  const Failure(this.message);

  final String message;

  String get userMessage;

  @override
  String toString() => '$runtimeType: $message';
}

final class FormatFailure extends Failure {
  const FormatFailure([
    super.message = 'The server returned an invalid response.',
  ]);

  @override
  String get userMessage => 'The Stash server returned invalid data.';
}

final class GraphQlFailure extends Failure {
  const GraphQlFailure(super.message);

  @override
  String get userMessage => 'The Stash server could not complete that request.';
}

final class HttpFailure extends Failure {
  const HttpFailure(this.statusCode, [String? message])
    : super(message ?? 'The server returned HTTP $statusCode.');

  final int statusCode;

  @override
  String get userMessage =>
      'The Stash server returned an HTTP error ($statusCode).';
}

final class TransportFailure extends Failure {
  const TransportFailure([super.message = 'Unable to reach the Stash server.']);

  @override
  String get userMessage => 'Could not reach the Stash server.';
}

final class NotFoundFailure extends Failure {
  const NotFoundFailure([super.message = 'The requested item was not found.']);

  @override
  String get userMessage => 'The requested item was not found.';
}
