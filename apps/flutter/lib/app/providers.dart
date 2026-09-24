import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../domain/connection.dart';
import '../domain/system_appearance.dart';
import '../features/connection/connection_controller.dart';
import '../features/connection/connection_sheet.dart';
import '../services/channel_connection_sheet.dart';
import '../services/channel_native_menus.dart';
import '../services/channel_native_toolbar.dart';
import '../services/connection_store.dart';
import '../services/disk_thumbnail_repository.dart';
import '../services/http_stash_api.dart';
import '../services/socks_forward_proxy.dart';
import '../services/stash_api.dart';
import '../services/system_appearance_channel.dart';
import '../services/thumbnail_repository.dart';
import '../shared/diagnostics.dart';
import '../ui/menu/drawn_menus.dart';
import '../ui/menu/native_menus.dart';
import '../ui/toolbar/native_toolbar.dart';

/// The process environment consulted for `STASH_URL` / `STASH_API_KEY`
/// overrides. Real runs read [Platform.environment] directly; tests
/// override this with a fixed map so `overlayEnvironment` behaves
/// deterministically.
final environmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);

/// The loopback forward proxy every outbound request may be routed
/// through, or null when the app is running without one.
///
/// App bootstrap binds it and overrides this provider with the result;
/// binding is async, which a synchronous provider body cannot do. Null is
/// the honest value for a test (and for a bootstrap whose bind failed):
/// with no proxy to hop through, requests go direct.
final socksForwardProxyProvider = Provider<SocksForwardProxy?>((ref) => null);

/// A single shared HTTP client for the lifetime of the app.
///
/// `findProxy` is consulted per request and reads the proxy's *current*
/// state, so changing the SOCKS setting takes effect without rebuilding
/// this client or anything holding it.
final httpClientProvider = Provider<http.Client>((ref) {
  final proxy = ref.watch(socksForwardProxyProvider);
  final client = IOClient(
    HttpClient()..findProxy = (_) => proxy?.proxyDirective ?? 'DIRECT',
  );
  ref.onDispose(client.close);
  return client;
});

/// Where the persisted connection lives. Platform storage needs async
/// initialisation ([PlatformConnectionStore.create]), which can't happen
/// inside a synchronous provider body — app bootstrap in `main.dart`
/// awaits that construction and overrides this provider with the result
/// before the widget tree is built. Tests override it with a
/// `FakeConnectionStore`.
final connectionStoreProvider = Provider<ConnectionStore>((ref) {
  throw UnsupportedError(
    'connectionStoreProvider must be provided by app bootstrap.',
  );
});

/// Builds a [StashApi] for a given [ConnectionConfig]. Production always
/// constructs an [HttpStashApi] against the shared [httpClientProvider];
/// tests override this to hand back fakes instead.
final stashApiFactoryProvider = Provider<StashApiFactory>((ref) {
  final client = ref.watch(httpClientProvider);
  return (config) => HttpStashApi(
    baseUri: Uri.parse(config.serverUrl),
    apiKey: config.apiKey,
    client: client,
  );
});

/// Bumped by [AppController.replaceConnection] once a settings change is
/// validated and persisted. Every provider whose value depends on "the
/// currently active connection" — [effectiveConnectionProvider] and
/// [stashApiProvider] here, and every later library/scene/playback
/// provider — watches this so a successful reconnection tears down and
/// rebuilds all connection-bound state in one step, without those
/// providers needing to know about each other.
final connectionGenerationProvider = StateProvider<int>((ref) => 0);

/// The connection config currently backing the app's API calls, re-read
/// from storage whenever [connectionGenerationProvider] changes.
///
/// This deliberately does not read [connectionControllerProvider]'s own
/// state: that state only reflects whatever the connection/settings form
/// last loaded or submitted, and is empty until a screen mounts and calls
/// `load()`. Reading the store directly means library/scene features see
/// the active connection immediately after a bootstrap that skipped the
/// connection screen entirely (the common "already configured" case).
final effectiveConnectionProvider = FutureProvider<ConnectionConfig>((ref) {
  ref.watch(connectionGenerationProvider);
  final store = ref.watch(connectionStoreProvider);
  final environment = ref.watch(environmentProvider);
  return store.load(environment);
});

/// The [StashApi] instance library/scene/playback features should use.
/// Rebuilt (via [effectiveConnectionProvider]) whenever
/// [connectionGenerationProvider] changes, so a settings-driven
/// reconnection always produces a fresh instance pointed at the new
/// server/key rather than reusing one built against the old connection.
final stashApiProvider = FutureProvider<StashApi>((ref) async {
  final config = await ref.watch(effectiveConnectionProvider.future);
  final factory = ref.watch(stashApiFactoryProvider);
  return factory(config);
});

/// The [ThumbnailRepository] library/scene features should use. Rebuilt
/// (via [effectiveConnectionProvider]) whenever [connectionGenerationProvider]
/// changes, the same way [stashApiProvider] is — a settings-driven
/// reconnection must not keep serving thumbnails fetched under the old
/// server's URL/key.
final thumbnailRepositoryProvider = FutureProvider<ThumbnailRepository>((
  ref,
) async {
  final config = await ref.watch(effectiveConnectionProvider.future);
  final client = ref.watch(httpClientProvider);
  return DiskThumbnailRepository.create(
    baseUri: Uri.parse(config.serverUrl),
    apiKey: config.apiKey,
    client: client,
  );
});

/// Wires up [connectionControllerProvider] — which throws until overridden
/// (see its doc comment) — from the replaceable pieces above. Defined once
/// here so every root `ProviderScope` (production in `main.dart`, or a
/// test) only needs to override [connectionStoreProvider],
/// [environmentProvider], and/or [stashApiFactoryProvider] and include
/// this override to get a correctly wired controller, instead of
/// reconstructing a `ConnectionController` by hand at every call site.
final connectionControllerOverride = connectionControllerProvider.overrideWith(
  (ref) => ConnectionController(
    store: ref.watch(connectionStoreProvider),
    environment: ref.watch(environmentProvider),
    apiFactory: ref.watch(stashApiFactoryProvider),
  ),
);

/// The desktop's accent colour and UI font. Only the Linux and macOS
/// runners implement the channel; everywhere else (including tests, which
/// run as Android) this is permanently unknown, and the theme uses its
/// built-in defaults. A channel error is logged and otherwise ignored for
/// the same reason.
final systemAppearanceProvider = StreamProvider<SystemAppearance>((ref) {
  if (defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.macOS) {
    return Stream.value(SystemAppearance.none);
  }
  return watchSystemAppearance().handleError(
    (Object error) => logDiagnostic(
      'appearance',
      'using the built-in accent and font: $error',
    ),
  );
});

/// How popup menus are shown: natively on the two desktop platforms the
/// runners implement the channel for, drawn everywhere else (including
/// tests, which run as Android).
final nativeMenusProvider = Provider<NativeMenus>(
  (ref) => switch (defaultTargetPlatform) {
    TargetPlatform.linux || TargetPlatform.macOS => ChannelNativeMenus(),
    _ => const DrawnMenus(),
  },
);

/// The window toolbar the library publishes its controls to: the real
/// `NSToolbar` on macOS, none elsewhere (Linux draws its own strip, and
/// tests run as Android).
final nativeToolbarProvider = Provider<NativeToolbar?>((ref) {
  if (defaultTargetPlatform != TargetPlatform.macOS) return null;
  final toolbar = ChannelNativeToolbar();
  unawaited(toolbar.reset());
  return toolbar;
});

/// The native connection sheet: an AppKit sheet on macOS, none elsewhere.
/// [ConnectionSheetNotifier.disable] drops it for the rest of the session
/// when it fails to open, and every host falls back to the drawn form.
final connectionSheetProvider =
    NotifierProvider<ConnectionSheetNotifier, ConnectionSheet?>(
      ConnectionSheetNotifier.new,
    );

class ConnectionSheetNotifier extends Notifier<ConnectionSheet?> {
  @override
  ConnectionSheet? build() {
    if (defaultTargetPlatform != TargetPlatform.macOS) return null;
    final sheet = ChannelConnectionSheet();
    unawaited(sheet.reset());
    return sheet;
  }

  void disable() => state = null;
}

/// Asks the macOS runner to run Sparkle's "Check for Updates…" (see
/// `UpdatesChannel` in `MainFlutterWindow.swift`).
final updatesChannelProvider = Provider<MethodChannel>(
  (ref) => const MethodChannel('stash_player/updates'),
);
