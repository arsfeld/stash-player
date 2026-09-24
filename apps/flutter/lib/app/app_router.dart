import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connection/connection_controller.dart';
import '../features/connection/connection_screen.dart';
import '../features/connection/connection_settings_dialog.dart';
import '../features/library/library_screen.dart';
import '../features/player/scene_screen.dart';
import '../ui/widgets/app_dialog.dart';
import 'app_controller.dart';

/// Switches on [AppController]'s current [AppDestination] and renders it
/// through a plain [Navigator] `pages` list — no routing package. The
/// library page always sits at the bottom of the stack when showing a
/// scene, so popping the scene page (back gesture, system back, app bar
/// back button) lands back on the library.
class AppRouter extends ConsumerWidget {
  const AppRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final destination = ref.watch(appControllerProvider);

    return Navigator(
      pages: _pagesFor(destination),
      onDidRemovePage: (page) {
        final app = ref.read(appControllerProvider.notifier);
        switch (page.name) {
          case _scenePageName:
            app.showLibrary();
          case _settingsPageName:
            // Also runs when the page leaves because the destination already
            // changed (a successful save). closeSettings is a no-op then.
            app.closeSettings();
        }
      },
    );
  }

  List<Page<void>> _pagesFor(AppDestination destination) =>
      switch (destination) {
        ConnectionDestination() => const [
          MaterialPage<void>(
            key: ValueKey('connection'),
            name: _connectionPageName,
            child: _ConnectionDestinationScreen(),
          ),
        ],
        LibraryDestination(:final settingsOpen) => [
          _libraryPage,
          if (settingsOpen) _settingsPage,
        ],
        SceneDestination(:final sceneId, :final browse) => [
          _libraryPage,
          MaterialPage<void>(
            key: ValueKey('scene-$sceneId'),
            name: _scenePageName,
            child: SceneScreen(sceneId: sceneId, browse: browse),
          ),
        ],
      };
}

const _connectionPageName = 'connection';
const _libraryPageName = 'library';
const _scenePageName = 'scene';
const _settingsPageName = 'settings';

const _libraryPage = MaterialPage<void>(
  key: ValueKey('library'),
  name: _libraryPageName,
  child: LibraryScreen(),
);

const _settingsPage = AppDialogPage<void>(
  key: ValueKey('settings'),
  name: _settingsPageName,
  child: ConnectionSettingsDialog(),
);

/// The first-launch / no-saved-connection screen. Never seeds
/// `initialConfig` — [ConnectionScreen] loads and populates its own
/// fields, per its documented contract.
class _ConnectionDestinationScreen extends ConsumerWidget {
  const _ConnectionDestinationScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ConnectionScreen(
    onConnected: () {
      final config = ref.read(connectionControllerProvider).state.config;
      ref.read(appControllerProvider.notifier).replaceConnection(config);
    },
  );
}
