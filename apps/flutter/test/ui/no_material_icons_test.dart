import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ uses AppIcon, never Material Icons', () {
    final offenders = <String>[];
    final pattern = RegExp(r'\bIcons\.');
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (pattern.hasMatch(line)) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
