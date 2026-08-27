import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connection/connection_controller.dart';
import '../features/connection/connection_screen.dart';
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
        if (page.name == _scenePageName) {
          ref.read(appControllerProvider.notifier).showLibrary();
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
        LibraryDestination() => const [_libraryPage],
        SceneDestination(:final sceneId) => [
          _libraryPage,
          MaterialPage<void>(
            key: ValueKey('scene-$sceneId'),
            name: _scenePageName,
            child: _ScenePlaceholder(sceneId: sceneId),
          ),
        ],
      };
}

const _connectionPageName = 'connection';
const _libraryPageName = 'library';
const _scenePageName = 'scene';

const _libraryPage = MaterialPage<void>(
  key: ValueKey('library'),
  name: _libraryPageName,
  child: _LibraryPlaceholder(),
);

/// The first-launch / no-saved-connection screen. Never seeds
/// `initialConfig` — [ConnectionScreen] loads and populates its own
/// fields, per its documented contract.
class _ConnectionDestinationScreen extends ConsumerWidget {
  const _ConnectionDestinationScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ConnectionScreen(
    settingsMode: false,
    onConnected: () {
      final config = ref.read(connectionControllerProvider).state.config;
      ref.read(appControllerProvider.notifier).replaceConnection(config);
    },
  );
}

/// Stand-in for the library feature, which Task 5+ builds. Exists only so
/// this task's shell/routing has something to show and a way to reach
/// connection settings.
class _LibraryPlaceholder extends StatelessWidget {
  const _LibraryPlaceholder();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Library'),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Connection settings',
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => const _SettingsRoute(),
            ),
          ),
        ),
      ],
    ),
    body: const Center(child: Text('Library — coming soon.')),
  );
}

/// Modal settings route. Only replaces the active connection once
/// [ConnectionScreen] itself reports success, and dismisses itself
/// promptly afterward rather than staying mounted.
class _SettingsRoute extends ConsumerWidget {
  const _SettingsRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ConnectionScreen(
    settingsMode: true,
    onConnected: () async {
      final config = ref.read(connectionControllerProvider).state.config;
      await ref.read(appControllerProvider.notifier).replaceConnection(config);
      if (context.mounted) Navigator.of(context).pop();
    },
    onCancel: () => Navigator.of(context).pop(),
  );
}

/// Stand-in for the scene feature, which Task 5+ builds. Nothing in this
/// task navigates here yet; this exists so [AppRouter]'s `scene(sceneId)`
/// case has somewhere to render.
class _ScenePlaceholder extends StatelessWidget {
  const _ScenePlaceholder({required this.sceneId});

  final String sceneId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Scene $sceneId')),
    body: const Center(child: Text('Scene — coming soon.')),
  );
}
