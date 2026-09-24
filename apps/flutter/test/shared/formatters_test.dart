import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/shared/formatters.dart';

void main() {
  group('formatDuration', () {
    test('formats seconds under a minute as 0:ss', () {
      expect(formatDuration(5), '0:05');
      expect(formatDuration(0), '0:00');
      expect(formatDuration(59), '0:59');
    });

    test('formats minutes-and-seconds under an hour as m:ss', () {
      expect(formatDuration(60), '1:00');
      expect(formatDuration(125), '2:05');
      expect(formatDuration(3599), '59:59');
    });

    test('formats an hour or more as h:mm:ss, minutes zero-padded', () {
      expect(formatDuration(3600), '1:00:00');
      expect(formatDuration(3723), '1:02:03');
      expect(formatDuration(7325), '2:02:05');
    });

    test('rounds fractional seconds to the nearest whole second', () {
      expect(formatDuration(5.4), '0:05');
      expect(formatDuration(5.6), '0:06');
      // Rounds up into the next minute rather than truncating to 0:59.
      expect(formatDuration(59.6), '1:00');
    });
  });

  group('formatRating', () {
    test('formats a 0-100 rating100 value as a 0.0-5.0 star rating', () {
      expect(formatRating(0), '0.0');
      expect(formatRating(20), '1.0');
      expect(formatRating(70), '3.5');
      expect(formatRating(100), '5.0');
    });
  });
}
