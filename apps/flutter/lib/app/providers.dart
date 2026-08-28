import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../domain/connection.dart';
import '../features/connection/connection_controller.dart';
import '../services/connection_store.dart';
import '../services/disk_thumbnail_repository.dart';
import '../services/http_stash_api.dart';
import '../services/stash_api.dart';
import '../services/thumbnail_repository.dart';

/// The process environment consulted for `STASH_URL` / `STASH_API_KEY`
/// overrides. Real runs read [Platform.environment] directly; tests
/// override this with a fixed map so `overlayEnvironment` behaves
/// deterministically.
final environmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);

/// A single shared HTTP client for the lifetime of the app.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
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
