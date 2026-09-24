import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/player/playback_controller.dart';
import '../features/player/playback_menu.dart';
import '../features/player/playback_state.dart';
import '../shared/diagnostics.dart';
import '../ui/menu/app_menu.dart';
import '../ui/menu/platform_menu_adapter.dart';
import 'app_controller.dart';
import 'providers.dart';

/// The macOS menu bar. Everywhere else this is just [child]: Linux apps
/// following GNOME's conventions have no menu bar.
///
/// Playback and View items act on the scene screen's playback controller
/// and are disabled on every other screen.
class AppMenuBar extends ConsumerWidget {
  const AppMenuBar({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;

    final onScene = ref.watch(appControllerProvider) is SceneDestination;
    // Only watched on the scene screen, and only for the three fields the
    // menu actually shows (`select`): the controller is created lazily,
    // the first time a scene loads, and the menu bar must not be what
    // creates it — and `PlaybackController` notifies on every position and
    // buffered event during playback (many times a second), which would
    // otherwise rebuild this widget, and so resend the whole menu bar to
    // AppKit, on every one of them (`PlatformMenuItem` has no `==`, so
    // `PlatformMenuBar` can't tell two menus built from the same state
    // apart and would call `Menu.setMenus` regardless).
    final shown = onScene
        ? ref.watch(
            playbackControllerProvider.select(
              (c) => (c.state.playing, c.state.muted, c.state.fullscreen),
            ),
          )
        : null;
    final state = shown == null
        ? null
        : PlaybackState(
            playing: shown.$1,
            muted: shown.$2,
            fullscreen: shown.$3,
          );
    void dispatch(PlayerAction action) {
      if (!onScene) return;
      unawaited(
        ref
            .read(playbackControllerProvider)
            .handleAction(action)
            .catchError((Object _, StackTrace _) {}),
      );
    }

    return PlatformMenuBar(
      menus: buildMacMenuBar(
        playback: playbackMenu(state, dispatch),
        view: viewMenu(state, dispatch),
        onCheckForUpdates: () => unawaited(
          ref
              .read(updatesChannelProvider)
              .invokeMethod<void>('checkForUpdates')
              .catchError((Object error) => logDiagnostic('updates', '$error')),
        ),
      ),
      child: child,
    );
  }
}

/// The whole menu bar, as data. `PlatformMenuBar` replaces the menu bar
/// `MainMenu.xib` loads, so everything the app menu needs is listed here,
/// including Sparkle's "Check for Updates…", which reaches the native side
/// over `stash_player/updates`.
List<PlatformMenuItem> buildMacMenuBar({
  required AppMenu playback,
  required AppMenu view,
  required VoidCallback onCheckForUpdates,
}) => [
  PlatformMenu(
    label: 'Stash Player',
    menus: [
      PlatformMenuItemGroup(
        members: [
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
          PlatformMenuItem(
            label: 'Check for Updates…',
            onSelected: onCheckForUpdates,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.servicesSubmenu,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.hideOtherApplications,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.showAllApplications,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ],
      ),
    ],
  ),
  PlatformMenu(
    label: 'Edit',
    menus: [
      PlatformMenuItemGroup(
        members: [
          _editItem(
            'Cut',
            LogicalKeyboardKey.keyX,
            const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          _editItem(
            'Copy',
            LogicalKeyboardKey.keyC,
            CopySelectionTextIntent.copy,
          ),
          _editItem(
            'Paste',
            LogicalKeyboardKey.keyV,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          _editItem(
            'Select All',
            LogicalKeyboardKey.keyA,
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
        ],
      ),
    ],
  ),
  toPlatformMenu('Playback', playback),
  toPlatformMenu('View', view),
  const PlatformMenu(
    label: 'Window',
    menus: [
      PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.minimizeWindow,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.zoomWindow,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ),
    ],
  ),
];

/// An Edit item that runs [intent] on whatever has focus: the same intent
/// the focused text field's own ⌘ shortcut would run. When Flutter handles
/// the key itself (a focused text field), AppKit never sees it, so the
/// item only fires from a mouse click or when nothing in Flutter wanted
/// the key.
PlatformMenuItem _editItem(
  String label,
  LogicalKeyboardKey key,
  Intent intent,
) => PlatformMenuItem(
  label: label,
  shortcut: SingleActivator(key, meta: true),
  onSelected: () {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null) Actions.maybeInvoke(focused, intent);
  },
);
