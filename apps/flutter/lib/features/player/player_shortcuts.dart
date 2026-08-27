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

/// Keys whose plain character has no built-in [EditableText] handling of
/// its own, so they need an explicit escape hatch here to keep typing
/// them possible in the metadata/search UI.
///
/// **Correction (fix round 1):** an earlier version of this comment
/// claimed the arrow keys and Home/End are excluded because they're
/// "already consumed by a focused text field before they could ever
/// reach a `Shortcuts` ancestor." That's wrong for the composition this
/// app will actually use. Flutter resolves a key event at the
/// *innermost* `Shortcuts` ancestor of the currently-focused widget
/// first, and `DefaultTextEditingShortcuts` — which owns cursor
/// movement, selection, and space/character insertion for a focused
/// [EditableText] — is mounted up in `WidgetsApp`, near the app root:
/// *outside*, not inside, any narrower scene-screen-level player
/// `Shortcuts` Task 11 builds. If a text field ends up nested *inside*
/// that player `Shortcuts` subtree (e.g. a search/metadata field on the
/// scene screen), the player's own bindings for arrows/Home/End/Space
/// would resolve *first* and win over `DefaultTextEditingShortcuts`'s
/// cursor-movement/space-insertion handling — the opposite of what the
/// old comment assumed.
///
/// This set only covers what's provably safe to gate *right now*
/// (J/K/L/M/F, which have no competing binding anywhere in the
/// framework). There is no real `Shortcuts`/`Actions` composition built
/// yet for this to be tested against (Task 11 owns that). Task 11 needs
/// to verify empirically — a real `TextField` nested under a real player
/// `Shortcuts` widget — whether arrows/Home/End/Space need to join this
/// set too, and widen it if so.
final Set<LogicalKeyboardKey> playerTextEntryConflictKeys = {
  LogicalKeyboardKey.keyJ,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyL,
  LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.keyF,
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
