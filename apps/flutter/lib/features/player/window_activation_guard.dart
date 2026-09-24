/// Tells the player whether a press on the video is the click that brought
/// its window into focus.
///
/// Clicking an unfocused window both focuses it and delivers the click:
/// Flutter's macOS view accepts the first mouse, and GTK passes it
/// through. A viewer clicking the player to bring it forward means
/// "focus", not "pause", so the video surface asks this guard before
/// toggling playback.
///
/// Focus and the press arrive in either order. macOS reports the app
/// active before it delivers the click, so the press lands on a window
/// that already reads as focused; Linux can deliver the press first. A
/// press is therefore the activation click when the window is still
/// unfocused, or when focus arrived within [_grace] and no press has
/// claimed it yet. Either way, one focus gain swallows one press.
class WindowActivationGuard {
  WindowActivationGuard({required bool focused, DateTime Function()? clock})
    : _focused = focused,
      _clock = clock ?? DateTime.now;

  /// How recently focus must have arrived for a press to count as the
  /// click that delivered it. The two reach the UI thread back to back, so
  /// the real gap is a few milliseconds even when a frame runs long. The
  /// margin only costs a click made this soon after switching to the app
  /// from the keyboard.
  static const _grace = Duration(milliseconds: 300);

  final DateTime Function() _clock;
  bool _focused;

  /// When focus last arrived, until a press claims it. Null while
  /// unfocused, and once claimed.
  DateTime? _focusGainedAt;

  /// Whether a press landed before the focus change it caused, which
  /// makes that press the activation click and leaves nothing for the
  /// focus change to arm.
  bool _pressedWhileUnfocused = false;

  void focusChanged(bool focused) {
    if (focused == _focused) return;
    _focused = focused;
    _focusGainedAt = focused && !_pressedWhileUnfocused ? _clock() : null;
    _pressedWhileUnfocused = false;
  }

  /// Records a press and returns whether it is the activation click.
  /// Report every press exactly once: the first one after a focus gain
  /// uses that activation up.
  bool recordPress() {
    if (!_focused) {
      final first = !_pressedWhileUnfocused;
      _pressedWhileUnfocused = true;
      return first;
    }
    final gainedAt = _focusGainedAt;
    _focusGainedAt = null;
    return gainedAt != null && _clock().difference(gainedAt) < _grace;
  }
}
