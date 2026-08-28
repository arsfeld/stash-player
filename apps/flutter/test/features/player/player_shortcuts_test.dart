import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/player_shortcuts.dart';

/// The exact Step 2 keyboard mapping table, reproduced independently of
/// `playerKeyBindings` so this test is a genuine check against the spec
/// rather than the production map trivially matching itself.
// Not `const`: see `player_shortcuts.dart`'s own note on why maps/sets
// keyed by `LogicalKeyboardKey` can't be const.
final _expectedBindings = <LogicalKeyboardKey, PlayerAction>{
  LogicalKeyboardKey.space: PlayerAction.togglePlayPause,
  LogicalKeyboardKey.keyK: PlayerAction.togglePlayPause,
  LogicalKeyboardKey.arrowLeft: PlayerAction.seekBackward5,
  LogicalKeyboardKey.arrowRight: PlayerAction.seekForward5,
  LogicalKeyboardKey.keyJ: PlayerAction.seekBackward10,
  LogicalKeyboardKey.keyL: PlayerAction.seekForward10,
  LogicalKeyboardKey.arrowDown: PlayerAction.seekBackward60,
  LogicalKeyboardKey.arrowUp: PlayerAction.seekForward60,
  LogicalKeyboardKey.home: PlayerAction.seekToStart,
  LogicalKeyboardKey.end: PlayerAction.seekToEnd,
  LogicalKeyboardKey.digit9: PlayerAction.volumeDown,
  LogicalKeyboardKey.digit0: PlayerAction.volumeUp,
  LogicalKeyboardKey.keyM: PlayerAction.toggleMute,
  LogicalKeyboardKey.keyF: PlayerAction.toggleFullscreen,
  LogicalKeyboardKey.escape: PlayerAction.exitFullscreen,
};

void main() {
  // `dispatchPlayerKeyEvent` and every test that exercised it were removed
  // (final review §3a): it had zero references in `lib/` and had already
  // drifted from the live dispatch path (`PlayerActionShortcuts` in
  // `scene_screen.dart`, covered by `scene_screen_test.dart`) — notably in
  // Shift handling and key-vs-action gating — despite this file's own
  // now-deleted doc claiming the two "can never drift apart". Only the two
  // pins against genuinely live production data survive here.
  test('playerKeyBindings matches the exact Step 2 table', () {
    expect(playerKeyBindings, _expectedBindings);
  });

  test('the text-entry conflict set is J/K/L/M/F plus arrows/Home/End/Space '
      '(widened by Task 11 — see the set\'s own doc comment for the '
      'empirical finding that required this)', () {
    expect(playerTextEntryConflictKeys, {
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.space,
    });
  });
}
