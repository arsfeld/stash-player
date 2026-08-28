import 'dart:async';

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

/// The exact, and only, keyboard mapping this app supports. Both
/// `dispatchPlayerKeyEvent` below and any `Shortcuts` table Task 11
/// builds for the scene screen must derive from this single map so the
/// two can never drift apart. `LogicalKeyboardKey.space` and `.keyK`
/// both resolve to [PlayerAction.togglePlayPause]; every other bound key
/// maps to exactly one action.
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
/// (`PlayerActionShortcuts` gates by action, not literal key) — this set
/// is also `dispatchPlayerKeyEvent`'s own, independent, *key*-based gate,
/// which gets no such protection for `space` unless the key itself is
/// listed here.
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

/// Ctrl/Alt/Meta — held alongside a bound key, these mean "this
/// keystroke belongs to a different (OS- or app-level) shortcut, not
/// ours," so the match is suppressed entirely rather than fired anyway.
///
/// Shift is deliberately excluded. None of [playerKeyBindings]'s
/// triggers need it held, and — unlike Ctrl/Alt/Meta — an incidentally
/// held Shift isn't a reliable "this keystroke means something else"
/// signal for a single letter/digit key in a media player: it's the kind
/// of modifier a user's finger can land on by accident while reaching
/// for K or F. Treating it as a blocking modifier would silently fail
/// the shortcut in that case, which is worse than just firing it anyway.
final Set<LogicalKeyboardKey> _modifierKeys = {
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

/// Resolves [event] against [playerKeyBindings] and, if eligible, invokes
/// `controller.handleAction` — returning whether the key was consumed.
///
/// Returns [KeyEventResult.ignored] (and never touches [controller])
/// when: [event] isn't a key-down; a Ctrl/Alt/Meta modifier is currently
/// held; the key isn't bound in [playerKeyBindings]; the key is one of
/// [playerTextEntryConflictKeys] while [isTextEditingTarget] is `true`;
/// or the resolved action is [PlayerAction.exitFullscreen] while
/// `controller.state.fullscreen` is `false` — which is what makes Escape
/// a no-op, rather than a swallowed key, outside fullscreen.
///
/// [isModifierPressed] defaults to reading the ambient
/// [HardwareKeyboard] singleton (what real key-event dispatch should
/// use); tests that construct [KeyEvent]s directly without a live
/// binding pass an explicit override instead.
KeyEventResult dispatchPlayerKeyEvent(
  KeyEvent event, {
  required PlaybackController controller,
  bool isTextEditingTarget = false,
  bool Function()? isModifierPressed,
}) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;

  final modified =
      isModifierPressed?.call() ??
      HardwareKeyboard.instance.logicalKeysPressed.any(_modifierKeys.contains);
  if (modified) return KeyEventResult.ignored;

  final action = playerKeyBindings[event.logicalKey];
  if (action == null) return KeyEventResult.ignored;

  if (isTextEditingTarget &&
      playerTextEntryConflictKeys.contains(event.logicalKey)) {
    return KeyEventResult.ignored;
  }

  if (action == PlayerAction.exitFullscreen && !controller.state.fullscreen) {
    return KeyEventResult.ignored;
  }

  // Fired unawaited — `onKeyEvent` must return synchronously — so
  // nothing else is ever positioned to catch a failure here.
  // `PlaybackController`'s own command methods already swallow engine
  // failures into `state.failure` rather than throwing (see its
  // `_runEngineCommand`), but this `catchError` is the last line of
  // defense against a future regression: an uncaught error at this
  // boundary means a red screen in debug, or a logged crash in release,
  // for something as ordinary as pressing a key.
  unawaited(
    controller.handleAction(action).catchError((Object _, StackTrace _) {}),
  );
  return KeyEventResult.handled;
}
