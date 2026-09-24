import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_menu.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/features/player/player_shortcuts.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';

Iterable<AppMenuAction> _actions(AppMenu menu) =>
    menu.entries.whereType<AppMenuAction>();

void main() {
  test('every shortcut a menu shows is the key bound to what it does', () {
    final dispatched = <PlayerAction>[];
    for (final menu in [
      playbackMenu(const PlaybackState(), dispatched.add),
      viewMenu(const PlaybackState(), dispatched.add),
    ]) {
      for (final action in _actions(menu)) {
        final shortcut = action.shortcut;
        if (shortcut == null) continue;
        dispatched.clear();
        action.onSelected();
        expect(
          playerKeyBindings[shortcut.trigger],
          dispatched.single,
          reason: action.label,
        );
        expect(shortcut.meta || shortcut.control || shortcut.alt, isFalse);
      }
    }
  });

  test('labels follow state', () {
    String label(AppMenu menu, int index) =>
        _actions(menu).elementAt(index).label;
    void noop(PlayerAction _) {}

    expect(label(playbackMenu(const PlaybackState(), noop), 0), 'Play');
    expect(
      label(playbackMenu(const PlaybackState(playing: true), noop), 0),
      'Pause',
    );
    expect(
      _actions(
        playbackMenu(const PlaybackState(muted: true), noop),
      ).any((a) => a.label == 'Unmute'),
      isTrue,
    );
    expect(
      label(viewMenu(const PlaybackState(fullscreen: true), noop), 0),
      'Exit Full Screen',
    );
  });

  test('off the scene screen everything is disabled', () {
    void noop(PlayerAction _) {}
    for (final menu in [playbackMenu(null, noop), viewMenu(null, noop)]) {
      expect(_actions(menu).every((a) => !a.enabled), isTrue);
    }
  });
}
