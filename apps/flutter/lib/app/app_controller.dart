import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/browse_context.dart';
import '../domain/connection.dart';
import '../features/connection/connection_controller.dart';
import '../services/socks_forward_proxy.dart';
import 'notices.dart';
import 'providers.dart';

/// The three top-level places the app can show. Hand-rolled sealed union
/// (no routing package, per the project's constraints) so [AppRouter] can
/// switch on it exhaustively.
sealed class AppDestination {
  const AppDestination();

  const factory AppDestination.connection() = ConnectionDestination;
  const factory AppDestination.library() = LibraryDestination;
  const factory AppDestination.scene(String sceneId, {BrowseContext? browse}) =
      SceneDestination;
}

final class ConnectionDestination extends AppDestination {
  const ConnectionDestination();
}

final class LibraryDestination extends AppDestination {
  const LibraryDestination();
}

final class SceneDestination extends AppDestination {
  const SceneDestination(this.sceneId, {this.browse});

  final String sceneId;

  /// Where this scene sits in the ordering the user was browsing, when
  /// there is one. `null` for any entry point with no ordering behind
  /// it, in which case prev/next render dead rather than the type
  /// inventing a position.
  final BrowseContext? browse;

  @override
  bool operator ==(Object other) =>
      other is SceneDestination &&
      other.sceneId == sceneId &&
      other.browse == browse;

  @override
  int get hashCode => Object.hash(sceneId, browse);
}

/// Owns which [AppDestination] is showing, and the two shell-level intents
/// that change it: the app's initial bootstrap, and replacing the active
/// connection from settings (or from the first-launch connection screen).
class AppController extends Notifier<AppDestination> {
  @override
  AppDestination build() => const AppDestination.connection();

  /// Decides the app's starting destination.
  ///
  /// Reads storage directly (via [connectionStoreProvider] /
  /// [environmentProvider]) rather than going through
  /// [connectionControllerProvider]'s own `load()`. That keeps this
  /// read's outcome from leaking into the connection screen's state: the
  /// screen calls `load()` itself on mount and reports its own errors
  /// inline, so a stale failure left behind by bootstrap would otherwise
  /// flash a scary error in front of a brand-new user who simply has
  /// nothing configured yet. A read failure here is reported as a
  /// dismissible [globalNoticeProvider] notice instead — and only when it
  /// actually happens, never for a plain empty config, which is the
  /// normal first-run case and gets no notice at all.
  Future<void> bootstrap() async {
    final environment = ref.read(environmentProvider);
    try {
      final config = await ref.read(connectionStoreProvider).load(environment);
      _applySocksProxy(config);
      state = config.serverUrl.isEmpty
          ? const AppDestination.connection()
          : const AppDestination.library();
    } catch (_) {
      ref
          .read(globalNoticeProvider.notifier)
          .show(
            AppNotice(
              message: 'Could not load saved connection settings.',
              severity: AppNoticeSeverity.error,
            ),
          );
      state = const AppDestination.connection();
    }
  }

  /// Validates and persists [config] as the active connection, then makes
  /// it the active one.
  ///
  /// Used both by the first-launch connection screen and by the settings
  /// screen's success callback. If [config] was *just* validated and
  /// saved by the caller (the common case: the connection screen's own
  /// "Test connection" button already ran `testAndSave` before invoking
  /// its `onConnected` callback), this skips repeating that network round
  /// trip. Only on success does it bump [connectionGenerationProvider] —
  /// which invalidates [stashApiProvider] and every later library/scene
  /// provider that depends on the active connection — and return to the
  /// library; a failed attempt leaves the current destination and the
  /// connection screen's own inline error alone.
  Future<void> replaceConnection(ConnectionConfig config) async {
    final connection = ref.read(connectionControllerProvider);
    final alreadyReady =
        connection.state.phase == ConnectionPhase.ready &&
        connection.state.config == config;
    if (!alreadyReady) {
      await connection.testAndSave(config);
    }
    if (connection.state.phase != ConnectionPhase.ready) return;

    _applySocksProxy(connection.state.config);
    ref.read(connectionGenerationProvider.notifier).state++;
    state = const AppDestination.library();

    ref
        .read(globalNoticeProvider.notifier)
        .show(
          AppNotice(
            message: 'Connected to ${connection.state.serverVersion}',
            severity: AppNoticeSeverity.success,
          ),
        );
  }

  /// Points the loopback forward proxy at whatever [config] configures, so
  /// the very next request (API, thumbnail or video) takes the new route.
  ///
  /// Done here rather than in a provider body because this class already
  /// owns both moments the active connection is decided: bootstrap, and a
  /// settings change. A parse failure resolves to null, which the connection
  /// form has already refused to save, and which means "no proxy" anyway.
  void _applySocksProxy(ConnectionConfig config) {
    final proxy = ref.read(socksForwardProxyProvider);
    if (proxy == null) {
      if (config.socksProxy.isNotEmpty) {
        ref
            .read(globalNoticeProvider.notifier)
            .show(
              AppNotice(
                message:
                    'Could not start the local proxy, so the SOCKS setting '
                    'is not in use. Stash will be contacted directly.',
                severity: AppNoticeSeverity.warning,
              ),
            );
      }
      return;
    }
    proxy.endpoint = SocksEndpoint.tryParse(config.socksProxy);
  }

  /// Returns from a scene back to the library, e.g. when the router
  /// observes the scene page being popped.
  void showLibrary() {
    state = const AppDestination.library();
  }

  /// Navigates to a scene by id, optionally carrying [browse] so the
  /// scene screen can step to the neighbouring scenes.
  void openScene(String sceneId, {BrowseContext? browse}) {
    state = AppDestination.scene(sceneId, browse: browse);
  }
}

final appControllerProvider = NotifierProvider<AppController, AppDestination>(
  AppController.new,
);
