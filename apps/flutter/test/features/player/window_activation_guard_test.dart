import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/window_activation_guard.dart';

import '../../support/fake_clock.dart';

void main() {
  late FakeClock clock;

  setUp(() => clock = FakeClock());

  WindowActivationGuard guard({required bool focused}) =>
      WindowActivationGuard(focused: focused, clock: clock.now);

  test('a press on a window that was focused all along is a normal press', () {
    expect(guard(focused: true).recordPress(), isFalse);
  });

  test('a press that lands while the window is still unfocused is the '
      'activation click (the order Linux can deliver them in)', () {
    expect(guard(focused: false).recordPress(), isTrue);
  });

  test('a press moments after the window gains focus is the activation '
      'click (the order macOS delivers them in)', () {
    final g = guard(focused: false)..focusChanged(true);
    clock.advance(const Duration(milliseconds: 50));

    expect(g.recordPress(), isTrue);
  });

  test('a press well after the window gained focus is a normal press', () {
    final g = guard(focused: false)..focusChanged(true);
    clock.advance(const Duration(seconds: 1));

    expect(g.recordPress(), isFalse);
  });

  test('only the first press after gaining focus is swallowed', () {
    final g = guard(focused: false)..focusChanged(true);
    clock.advance(const Duration(milliseconds: 20));
    expect(g.recordPress(), isTrue);

    clock.advance(const Duration(milliseconds: 20));
    expect(g.recordPress(), isFalse);
  });

  test('a press that arrives before the focus change uses up that '
      'activation, so the next press is normal', () {
    final g = guard(focused: false);
    expect(g.recordPress(), isTrue);

    g.focusChanged(true);
    clock.advance(const Duration(milliseconds: 20));
    expect(g.recordPress(), isFalse);
  });

  test('a window that never reports focus still swallows only one press', () {
    final g = guard(focused: false);
    expect(g.recordPress(), isTrue);

    expect(g.recordPress(), isFalse);
  });

  test('losing focus and gaining it again arms a fresh activation', () {
    final g = guard(focused: false);
    expect(g.recordPress(), isTrue);
    g
      ..focusChanged(true)
      ..focusChanged(false)
      ..focusChanged(true);
    clock.advance(const Duration(milliseconds: 20));

    expect(g.recordPress(), isTrue);
  });

  test('a repeated focus report on an already focused window arms nothing', () {
    final g = guard(focused: true)..focusChanged(true);

    expect(g.recordPress(), isFalse);
  });
}
