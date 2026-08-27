import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/authenticated_url.dart';

void main() {
  test('resolves relative sources and appends an encoded key', () {
    expect(
      authenticatedUrl(
        Uri.parse('https://stash.test/'),
        'scene/1/stream?x=1',
        'a key',
      ),
      Uri.parse('https://stash.test/scene/1/stream?x=1&apikey=a+key'),
    );
  });

  test('keeps absolute URLs and existing case-insensitive apikey values', () {
    expect(
      authenticatedUrl(
        Uri.parse('https://stash.test/'),
        'https://media.test/v?ApiKey=server-key&x=1',
        'client-key',
      ),
      Uri.parse('https://media.test/v?ApiKey=server-key&x=1'),
    );
  });

  test('does not append an empty key', () {
    expect(
      authenticatedUrl(Uri.parse('https://stash.test/'), '/scene/1/stream', ''),
      Uri.parse('https://stash.test/scene/1/stream'),
    );
  });

  test('preserves fragments while authenticating relative URLs', () {
    expect(
      authenticatedUrl(
        Uri.parse('https://stash.test/'),
        'scene/1/stream?x=1#player',
        'a key',
      ),
      Uri.parse('https://stash.test/scene/1/stream?x=1&apikey=a+key#player'),
    );
  });

  test('preserves fragments while authenticating absolute URLs', () {
    expect(
      authenticatedUrl(
        Uri.parse('https://stash.test/'),
        'https://media.test/v#player',
        'client-key',
      ),
      Uri.parse('https://media.test/v?apikey=client-key#player'),
    );
  });

  test('redacts both headers and authenticated query parameters', () {
    expect(
      redactSensitive(
        'ApiKey: SECRET https://x.test/v?apikey=SECRET&x=1',
        apiKey: 'SECRET',
      ),
      'ApiKey: *** https://x.test/v?apikey=***&x=1',
    );
    expect(
      redactSensitive(
        'https://x.test/v?ApiKey=server-issued&x=1',
        apiKey: 'SECRET',
      ),
      'https://x.test/v?ApiKey=***&x=1',
    );
  });
}
