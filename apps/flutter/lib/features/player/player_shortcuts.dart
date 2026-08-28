import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'playback_controller.dart';

/// The single [Intent] every player keyboard shortcut resolves to.
/// `Shortcuts`/`Actions` wiring — here and in the scene screen Task 11
/// builds on top of it — is expressed entirely in terms of this one
/// type, parameterized by [PlayerAction], rather than one bespoke
/// [Intent] subclass per shortcut.
class PlayerIntent extends Intent {
  const PlayerIntent(this.action);

  final PlayerAction action;
}

/// The exact, and only, keyboard mapping this app supports. The scene
/// screen's `Shortcuts` table (`PlayerActionShortcuts` in
/// `scene_screen.dart`) derives from this single map, so there is one
/// source of truth for which key means which action.
/// `LogicalKeyboardKey.space` and `.keyK` both resolve to
/// [PlayerAction.togglePlayPause]; every other bound key maps to exactly
/// one action.
// Not `const`: `LogicalKeyboardKey` overrides `==`/`hashCode` (its
// equality isn't the default identity-based one), and Dart only allows
// primitive-equality keys/elements in a compile-time const map or set.
final Map<LogicalKeyboardKey, PlayerAction> playerKeyBindings = {
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

/// Keys that must yield to normal text editing (cursor movement,
/// selection, character/space insertion) whenever the currently focused
/// widget is an [EditableText], rather than firing their bound
/// [PlayerAction].
///
/// **Widened by Task 11 (verified empirically, not just reasoned about —
/// see `scene_screen_test.dart`'s "text-entry propagation (I7)" group,
/// which builds a real `TextField` nested inside a real player
/// `Shortcuts`/`Actions` composition, `PlayerActionShortcuts`).** An
/// earlier version of this set held only J/K/L/M/F, on the theory that
/// arrows/Home/End/Space were already safe because
/// `DefaultTextEditingShortcuts` (which owns cursor movement, selection,
/// and space handling for a focused [EditableText]) is mounted by
/// `WidgetsApp`, near the app root — *outside*, not inside, any narrower
/// player `Shortcuts` a screen builds. That reasoning about *where*
/// `DefaultTextEditingShortcuts` lives was correct, but the conclusion
/// drawn from it was backwards: Flutter resolves a key event at the
/// *innermost* `Shortcuts` ancestor of the focused widget first, so a
/// player `Shortcuts` table nested *inside* `WidgetsApp` (i.e. anywhere a
/// real screen would put it) intercepts arrows/Home/End *before* they
/// ever reach `DefaultTextEditingShortcuts` — the empirical test proved
/// this directly: with only J/K/L/M/F gated, Home/End/arrow-key
/// keystrokes sent to a focused, nested `TextField` produced a
/// `SeekCommand` on the underlying engine instead of moving the caret.
/// `space` is included too, even though `togglePlayPause`'s *action* was
/// already incidentally gated via `keyK`'s membership in this set
/// (`PlayerActionShortcuts` gates by action, not literal key) — `space`
/// itself has no bound alias to fall back on, so it needs its own entry
/// here.
///
/// J/K/L/M/F remain listed even though the same empirical test showed
/// `sendKeyEvent` never inserts a character into a focused `TextField` in
/// a headless test regardless of gating (basic character entry goes
/// through the platform's separate `TextInputClient`/IME channel, not
/// raw hardware key events) — keeping them gated is still correct
/// production behavior: it stops the *player action* (seek/mute/
/// fullscreen/play-pause) from firing while the user is typing a letter,
/// which is the actual property this set exists to guarantee, independent
/// of how test-simulated character entry happens to work.
final Set<LogicalKeyboardKey> playerTextEntryConflictKeys = {
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
};
