import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/shared/diagnostics.dart';

void main() {
  test('tags each line with its channel and writes it where a terminal can '
      'actually see it', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);

    logDiagnostic('playback', 'scene 1: open 40ms');

    // Asserting through `debugPrint` is the point of this test, not an
    // implementation detail: `dart:developer`'s `log()` delivers only to
    // the VM service, so it is invisible in a `flutter run` console.
    // Diagnostics that only DevTools can see do not answer "why is this
    // slow" for someone watching a terminal.
    expect(lines.single, endsWith('scene 1: open 40ms'));
    expect(lines.single, startsWith('[playback'));
  });

  test('stamps every line with elapsed milliseconds, so lines from different '
      'channels can be lined up against each other', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);

    logDiagnostic('playback', 'stalled');
    logDiagnostic('media_proxy', '#12 host:443 tunnel');

    // Without a shared clock on both channels there is no way to tell
    // whether a 60-second stall was spent opening connections or waiting
    // on one, which is the whole question these logs exist to answer.
    expect(lines[0], matches(RegExp(r'^\[playback \+\d+ms\] stalled$')));
    expect(
      lines[1],
      matches(RegExp(r'^\[media_proxy \+\d+ms\] #12 host:443 tunnel$')),
    );
  });
}
