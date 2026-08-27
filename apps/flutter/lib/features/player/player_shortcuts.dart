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

/// Keys whose plain character has no built-in [EditableText] handling of
/// its own — unlike the arrow keys and Home/End, which move the text
/// cursor and so are already consumed by a focused text field before
/// they could ever reach a `Shortcuts` ancestor, these five fall straight
/// through unhandled. Left ungated, typing them into the metadata/search
/// UI would silently double as a player shortcut, which is exactly the
/// "search box becomes unusable" hazard this set exists to prevent.
final Set<LogicalKeyboardKey> playerTextEntryConflictKeys = {
  LogicalKeyboardKey.keyJ,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyL,
  LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.keyF,
};

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

  controller.handleAction(action);
  return KeyEventResult.handled;
}
