import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/system_appearance.dart';

void main() {
  group('parseFontName', () {
    test('splits a Pango description into family and size', () {
      expect(SystemAppearance.parseFontName('Adwaita Sans 11'), (
        family: 'Adwaita Sans',
        sizePt: 11.0,
      ));
      expect(SystemAppearance.parseFontName('Cantarell 10.5'), (
        family: 'Cantarell',
        sizePt: 10.5,
      ));
    });

    test('a name with no size keeps the family only', () {
      expect(SystemAppearance.parseFontName('Inter'), (
        family: 'Inter',
        sizePt: null,
      ));
    });

    test('empty or missing is unknown', () {
      expect(SystemAppearance.parseFontName(null), isNull);
      expect(SystemAppearance.parseFontName('   '), isNull);
    });
  });

  group('fromEvent', () {
    test('decodes accent and font', () {
      expect(
        SystemAppearance.fromEvent({
          'accent': 0xFFE66100,
          'fontName': 'Adwaita Sans 12',
        }),
        const SystemAppearance(
          accent: Color(0xFFE66100),
          fontFamily: 'Adwaita Sans',
          fontSizePt: 12,
        ),
      );
    });

    test('nulls stay unknown', () {
      expect(
        SystemAppearance.fromEvent({'accent': null, 'fontName': null}),
        SystemAppearance.none,
      );
    });

    test('malformed input decodes to unknown rather than throwing', () {
      expect(SystemAppearance.fromEvent('nonsense'), SystemAppearance.none);
      expect(
        SystemAppearance.fromEvent({'accent': 'blue', 'fontName': 7}),
        SystemAppearance.none,
      );
    });
  });
}
