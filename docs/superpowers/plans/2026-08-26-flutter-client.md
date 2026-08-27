# Flutter Desktop Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an isolated experimental Flutter desktop client that connects to Stash, presents the milestone library workflow, plays authenticated media on Linux and macOS, and synchronizes resume and active-play duration.

**Architecture:** `apps/flutter` is one Flutter package split into immutable domain models, side-effecting services, Riverpod controllers, and rendering-only widgets. Small application-owned interfaces (`StashApi`, settings/secrets stores, `ThumbnailRepository`, `PlaybackEngine`, clock/delay functions) keep GraphQL, persistence, filesystem access, and `media_kit` out of widgets and make every controller deterministic in tests.

**Tech Stack:** Flutter desktop (pinned by `flake.lock`), Dart 3, Material 3, Riverpod, `package:http`, `shared_preferences`, `flutter_secure_storage`, `media_kit`, `path_provider`, `url_launcher`, fixture-driven `flutter_test`, and `integration_test`.

**Spec:** `docs/superpowers/specs/2026-08-26-flutter-client-design.md`

**Branch:** `flutter` (already checked out)

## Global Constraints

- Build and run on Linux and macOS from the first increment; shared feature layout, system light/dark theme, and only small window/keyboard platform adaptations.
- Flutter package root is exactly `apps/flutter/`; it is not a Cargo workspace member and existing GTK4, SwiftUI, Rust, Flatpak, and native macOS files remain behaviorally unchanged.
- Application identifier is exactly `dev.arsfeld.stashplayer.flutter`; display name is exactly `Stash Player Flutter`.
- Preferences, secure-storage keys, cache directories, and platform metadata must not overlap released clients.
- Riverpod owns dependency injection and asynchronous state; widgets consume immutable typed state and forward intents only.
- The Flutter client uses direct Dart HTTP and hand-written GraphQL. It does not use Rust FFI, code generation, a normalized GraphQL cache, or a local database.
- Server URL is stored in isolated preferences; API key is stored with `flutter_secure_storage`; empty API keys are valid.
- Runtime `STASH_URL` and `STASH_API_KEY` override persisted values for that process and are never persisted automatically.
- API keys and authenticated URLs must be redacted from logs and errors.
- Library page size is exactly 48; hide-tracked defaults to enabled; thumbnail concurrency is at most 12.
- Resume positions within the final 10 seconds or at/after 97 percent of known duration restart at zero.
- Activity checkpoints occur after approximately 10 seconds of active playback and flush on pause, seek, scene replacement, and disposal; retries wait exactly 1, 2, and 4 seconds.
- Volume shortcuts change volume by exactly 5 percent.
- No golden tests in this milestone. Headless builds do not count as playback validation.
- Do not add top-level performers/studios/tags/markers, O-counter controls, ratings, Picture in Picture, media keys, Now Playing, native menus, packaging, signing, notarization, publishing, previous/next navigation, or replacement/migration logic.
- Every task ends with `dart format --output=none --set-exit-if-changed .`, `flutter analyze --fatal-infos --fatal-warnings`, and relevant tests from `apps/flutter`; retain a green `cargo test -p stash-api -p stash-player-core` at each increment boundary.

## File Structure

The following boundaries are fixed before implementation:

- `apps/flutter/lib/app/`: bootstrap, provider wiring, theme, routing, notices, and connection replacement.
- `apps/flutter/lib/domain/`: immutable decoded models, filters, failures, and playback/library state primitives; no Flutter widgets, HTTP, storage, or `media_kit` imports.
- `apps/flutter/lib/services/`: GraphQL/HTTP, settings, secure credentials, URL redaction, thumbnail cache, and production playback adapter.
- `apps/flutter/lib/features/connection/`: connection controller and reusable connection/settings form.
- `apps/flutter/lib/features/library/`: library controller, toolbar, grid, cards, pagination, and random-play intent.
- `apps/flutter/lib/features/player/`: playback controller, activity synchronization, keyboard mapping, scene screen, controls, and metadata drawer.
- `apps/flutter/lib/shared/`: formatting functions and reusable status/error widgets only.
- `apps/flutter/test/fixtures/`: copied/sanitized GraphQL envelopes consumed by service tests.
- `apps/flutter/test/support/`: explicit fakes and controllable clock/engine shared by controller and widget tests.
- `apps/flutter/integration_test/`: mock-server connection-to-scene smoke test; real playback remains manual.

---

### Task 1: Flutter Package, Isolated Identity, Pinned Tooling, and CI

**Files:**
- Create: `apps/flutter/pubspec.yaml`
- Create: `apps/flutter/analysis_options.yaml`
- Create: `apps/flutter/lib/main.dart`
- Create: `apps/flutter/lib/app/app.dart`
- Create: `apps/flutter/test/app/app_smoke_test.dart`
- Create: generated Flutter desktop scaffolding under `apps/flutter/linux/` and `apps/flutter/macos/`
- Create: `.github/workflows/flutter.yml`
- Modify: `flake.nix:57-133`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the repository's locked nixpkgs input and existing Rust dev shells.
- Produces: `StashPlayerApp extends ConsumerWidget`, a committed `pubspec.lock`, Linux/macOS runners with the isolated identifier, and a two-platform `Flutter` workflow.

- [ ] **Step 1: Generate the desktop package and add only milestone dependencies**

Run from the repository root:

```bash
flutter create --platforms=linux,macos --org dev.arsfeld.stashplayer --project-name stash_player_flutter apps/flutter
cd apps/flutter
flutter pub add flutter_riverpod http shared_preferences flutter_secure_storage media_kit media_kit_video media_kit_libs_video path_provider crypto path url_launcher
```

Keep `pubspec.lock` committed. Add `integration_test: {sdk: flutter}` under `dev_dependencies`. Remove Android/iOS/web/Windows scaffolding if the installed Flutter template creates it. Set `name: stash_player_flutter`, `description: Experimental Linux and macOS client for Stash Player`, and `publish_to: none` in `pubspec.yaml`.

- [ ] **Step 2: Write the failing application identity smoke test**

Create `test/app/app_smoke_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app.dart';

void main() {
  testWidgets('uses the experimental display name and Material 3', (tester) async {
    await tester.pumpWidget(const StashPlayerApp());
    expect(find.text('Stash Player Flutter'), findsOneWidget);
    final context = tester.element(find.byType(MaterialApp));
    expect(Theme.of(context).useMaterial3, isTrue);
  });
}
```

- [ ] **Step 3: Run the test and verify the shell is missing**

Run: `cd apps/flutter && flutter test test/app/app_smoke_test.dart`

Expected: FAIL because `lib/app/app.dart` and `StashPlayerApp` do not exist.

- [ ] **Step 4: Add the minimal Material 3 shell and bootstrap**

Create `lib/app/app.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class StashPlayerApp extends ConsumerWidget {
  const StashPlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        title: 'Stash Player Flutter',
        themeMode: ThemeMode.system,
        theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const Scaffold(body: Center(child: Text('Stash Player Flutter'))),
      );
}
```

Replace `lib/main.dart` with:

```dart
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const ProviderScope(child: StashPlayerApp()));
}
```

- [ ] **Step 5: Set non-overlapping Linux and macOS metadata**

In the generated Linux CMake runner, set `APPLICATION_ID` to `dev.arsfeld.stashplayer.flutter` and binary/display metadata to `stash_player_flutter` / `Stash Player Flutter`. In macOS Xcode configuration files set:

```text
PRODUCT_BUNDLE_IDENTIFIER = dev.arsfeld.stashplayer.flutter
PRODUCT_NAME = Stash Player Flutter
```

Update generated window titles to `Stash Player Flutter`. Verify no Flutter platform file contains `dev.arsfeld.stash-player` or the released macOS bundle identifier.

- [ ] **Step 6: Extend the locked Nix shells without replacing Rust inputs**

Add `pkgs.flutter`, `pkgs.cmake`, `pkgs.ninja`, `pkgs.clang`, and `pkgs.pkg-config` to both platform shells; add `pkgs.mpv` and existing `pkgs.libsecret` on Linux and `pkgs.cocoapods` on Darwin. Preserve all existing Rust, GTK, GStreamer, Flatpak, and xcodegen inputs. Add a shell check that prints `flutter --version` but does not run `flutter upgrade`.

- [ ] **Step 7: Add the dedicated matrix workflow**

Create `.github/workflows/flutter.yml` with independent `ubuntu-latest` and `macos-15` jobs. Each checks out the repository, installs Nix with DeterminateSystems, enters `nix develop`, then runs:

```bash
cd apps/flutter
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
flutter build linux --debug   # Linux job only
flutter build macos --debug   # macOS job only
```

Install Linux runtime build libraries before the Nix command only if Flutter's generated CMake probe reports a system package absent from the shell. Do not edit `.github/workflows/tests.yml`, `flatpak.yml`, or `macos.yml`.

- [ ] **Step 8: Verify scaffold, identity, and both local gates available on this host**

Run:

```bash
cd apps/flutter
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test test/app/app_smoke_test.dart
flutter build linux --debug   # on Linux
flutter build macos --debug   # on macOS
cd ../..
cargo test -p stash-api -p stash-player-core
```

Expected: all host-applicable commands PASS; the non-host build is deferred to its CI runner.

- [ ] **Step 9: Commit**

```bash
git add flake.nix .gitignore .github/workflows/flutter.yml apps/flutter
git commit -m "feat(flutter): scaffold isolated desktop client"
```

---

### Task 2: Typed Domain Models and Stash GraphQL Service

**Files:**
- Create: `apps/flutter/lib/domain/failure.dart`
- Create: `apps/flutter/lib/domain/scene.dart`
- Create: `apps/flutter/lib/domain/scene_filter.dart`
- Create: `apps/flutter/lib/services/authenticated_url.dart`
- Create: `apps/flutter/lib/services/stash_api.dart`
- Create: `apps/flutter/lib/services/http_stash_api.dart`
- Create: `apps/flutter/test/fixtures/version.json`
- Create: `apps/flutter/test/fixtures/find_scenes_default.json`
- Create: `apps/flutter/test/fixtures/find_scenes_partial.json`
- Create: `apps/flutter/test/fixtures/find_scene.json`
- Create: `apps/flutter/test/fixtures/graphql_error.json`
- Create: `apps/flutter/test/services/http_stash_api_test.dart`
- Create: `apps/flutter/test/services/authenticated_url_test.dart`

**Interfaces:**
- Consumes: `package:http` and the GraphQL contract mirrored by `crates/stash-api/src/scenes.rs`.
- Produces: `Future<String> StashApi.version()`, `Future<ScenePage> findScenes(SceneFilter filter, {required int page, required int perPage})`, `Future<Scene?> findScene(String id)`, `Future<void> saveSceneActivity({required String id, required double resumeTime, required double playDuration})`, `Uri authenticatedUrl(Uri baseUri, String source, String apiKey)`, and typed `Failure` subclasses.

- [ ] **Step 1: Define the exact immutable public contract in tests**

Start `test/services/http_stash_api_test.dart` with a recording `http.BaseClient` and these cases:

```dart
test('findScenes sends filters, ApiKey, and decodes typed scenes', () async {
  final transport = RecordingClient(fixture('find_scenes_default.json'));
  final api = HttpStashApi(baseUri: Uri.parse('https://stash.test'), apiKey: 'SECRET', client: transport);
  final page = await api.findScenes(
    const SceneFilter(
      query: 'alpha', sort: SceneSort.rating, direction: SortDirection.ascending,
      minimumRating: 60, organized: true, hideTracked: true,
    ),
    page: 2,
    perPage: 48,
  );
  expect(transport.lastRequest.headers['ApiKey'], 'SECRET');
  expect(transport.lastVariables['filter'], containsPair('sort', 'rating'));
  expect(transport.lastVariables['filter'], containsPair('direction', 'ASC'));
  expect(transport.lastVariables['scene_filter']['rating100'], {'value': 59, 'modifier': 'GREATER_THAN'});
  expect(transport.lastVariables['scene_filter']['o_counter'], {'value': 0, 'modifier': 'EQUALS'});
  expect(page.scenes.single.id, '1001');
});
```

Add explicit tests for empty-key header omission, version validation, `random_42`, optional-field defaults, missing required `id`, malformed `data`, GraphQL errors, HTTP 401/500, nullable `findScene`, and the `sceneSaveActivity` variables `id`, `resume_time`, and `playDuration`.

Use a table-driven test to assert every sort wire value: Date=`date`, Title=`title`, Rating=`rating`, Play count=`play_count`, Duration=`duration`, Date added=`created_at`, Last updated=`updated_at`, and Random with seed 42=`random_42`.

- [ ] **Step 2: Write authenticated URL and redaction tests**

Create `test/services/authenticated_url_test.dart` covering relative and absolute URLs, preserving existing case-insensitive `apikey`, empty keys, query encoding, and redaction:

```dart
test('redacts both headers and authenticated query parameters', () {
  expect(redactSensitive('ApiKey: SECRET https://x.test/v?apikey=SECRET&x=1', apiKey: 'SECRET'),
      'ApiKey: *** https://x.test/v?apikey=***&x=1');
});
```

- [ ] **Step 3: Run service tests and verify missing contracts**

Run: `cd apps/flutter && flutter test test/services`

Expected: FAIL on missing model and service imports.

- [ ] **Step 4: Implement the domain types without `dynamic` escaping the boundary**

Define:

```dart
enum SceneSort { date, title, rating, playCount, duration, createdAt, updatedAt, random }
enum SortDirection { ascending, descending }

class SceneFilter {
  const SceneFilter({this.query = '', this.sort = SceneSort.createdAt,
    this.direction = SortDirection.descending, this.minimumRating,
    this.organized, this.hideTracked = true, this.randomSeed});
  final String query;
  final SceneSort sort;
  final SortDirection direction;
  final int? minimumRating;
  final bool? organized;
  final bool hideTracked;
  final int? randomSeed;
  SceneFilter copyWith({
    String? query,
    SceneSort? sort,
    SortDirection? direction,
    int? minimumRating,
    bool clearMinimumRating = false,
    bool? organized,
    bool clearOrganized = false,
    bool? hideTracked,
    int? randomSeed,
    bool clearRandomSeed = false,
  });
}

class ScenePage { const ScenePage({required this.total, required this.scenes}); final int total; final List<Scene> scenes; }
class Scene {
  const Scene({required this.id, required this.paths, this.title, this.details,
    this.date, this.rating100, this.resumeTime, this.playCount,
    this.playDuration, this.files = const [], this.studio,
    this.performers = const []});
  final String id;
  final ScenePaths paths;
  final String? title;
  final String? details;
  final String? date;
  final int? rating100;
  final double? resumeTime;
  final int? playCount;
  final double? playDuration;
  final List<SceneFile> files;
  final StudioRef? studio;
  final List<PerformerRef> performers;
}
class ScenePaths { const ScenePaths({this.screenshot, this.stream}); final String? screenshot; final String? stream; }
class SceneFile {
  const SceneFile({this.path, this.duration, this.width, this.height, this.videoCodec, this.frameRate});
  final String? path;
  final double? duration;
  final int? width;
  final int? height;
  final String? videoCodec;
  final double? frameRate;
}
class StudioRef { const StudioRef({required this.id, required this.name}); final String id; final String name; }
class PerformerRef { const PerformerRef({required this.id, required this.name}); final String id; final String name; }
```

`Scene.displayTitle` falls back to the first file basename without extension, then `Scene <id>`. `Scene.effectiveResume` returns null for `resume <= 0`, `resume >= duration - 10`, or `resume / duration >= .97`; with unknown duration, any positive resume is retained.

Use `FormatFailure`, `GraphQlFailure`, `HttpFailure`, `TransportFailure`, and `NotFoundFailure`, each with a credential-safe user message.

- [ ] **Step 5: Implement the hand-written GraphQL adapter**

Keep `findScenes`, `findScene`, and `sceneSaveActivity` documents as top-level `const String` values containing exactly the milestone fields from the Rust query. Build variables with `rating100 = minimumRating - 1` because Stash's `GREATER_THAN` is exclusive. `_post<T>` must:

```dart
final response = await client.post(
  baseUri.resolve('graphql'),
  headers: {'content-type': 'application/json', if (apiKey.isNotEmpty) 'ApiKey': apiKey},
  body: jsonEncode({'query': document, 'variables': variables}),
);
```

Reject non-2xx before decoding, reject a non-map envelope/data node, combine GraphQL error messages after redaction, and decode every response into immutable Dart values before returning.

- [ ] **Step 6: Implement authenticated URLs and log-safe text**

`authenticatedUrl(Uri baseUri, String source, String apiKey)` resolves relative sources, returns an existing `apikey` query unchanged using a case-insensitive key check, and appends `apikey` only for non-empty keys. `redactSensitive` replaces the configured raw key and any `apikey` query value without altering other parameters.

- [ ] **Step 7: Run focused and full Flutter checks**

Run:

```bash
cd apps/flutter
flutter test test/services
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/flutter/lib/domain apps/flutter/lib/services apps/flutter/test/fixtures apps/flutter/test/services
git commit -m "feat(flutter): add typed Stash API client"
```

---

### Task 3: Isolated Settings, Secure Credentials, and Connection Flow

**Files:**
- Create: `apps/flutter/lib/domain/connection.dart`
- Create: `apps/flutter/lib/services/connection_store.dart`
- Create: `apps/flutter/lib/services/platform_connection_store.dart`
- Create: `apps/flutter/lib/features/connection/connection_controller.dart`
- Create: `apps/flutter/lib/features/connection/connection_screen.dart`
- Create: `apps/flutter/test/support/fakes.dart`
- Create: `apps/flutter/test/features/connection/connection_controller_test.dart`
- Create: `apps/flutter/test/features/connection/connection_screen_test.dart`

**Interfaces:**
- Consumes: `StashApi`, `shared_preferences`, `flutter_secure_storage`, and `Platform.environment`.
- Produces: `ConnectionConfig`, `ConnectionStore.load/save`, `ConnectionController.testAndSave`, and `ConnectionScreen(onConnected, initialConfig, settingsMode)`.

- [ ] **Step 1: Write controller tests for load, override, validation, and persistence**

Use `FakeConnectionStore` and an injected `StashApi Function(ConnectionConfig)` factory. Cover:

```dart
test('environment values override storage but are not persisted', () async {
  final store = FakeConnectionStore(saved: const ConnectionConfig(serverUrl: 'https://saved', apiKey: 'saved'));
  final controller = ConnectionController(store: store, environment: const {
    'STASH_URL': 'https://env', 'STASH_API_KEY': 'env-key',
  }, apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'));
  await controller.load();
  expect(controller.state.config.serverUrl, 'https://env');
  expect(controller.state.config.apiKey, 'env-key');
  expect(store.saveCalls, isEmpty);
});
```

Also test malformed/non-HTTP(S) URL, empty API key success, 401 authentication copy, unreachable server copy, successful version display, saving only entered form values, and no save after failed validation.

- [ ] **Step 2: Write connection widget tests**

Assert URL and optional API-key fields, masked key toggle, `Test connection` button, progress state, keyboard traversal, field-scoped URL error, server error text, settings-mode `Cancel`, and callback only after success.

- [ ] **Step 3: Run tests and verify they fail before implementation**

Run: `cd apps/flutter && flutter test test/features/connection`

Expected: FAIL on missing connection files.

- [ ] **Step 4: Implement isolated storage keys and environment overlay**

Use these exact constants in `platform_connection_store.dart`:

```dart
const serverUrlPreferenceKey = 'dev.arsfeld.stashplayer.flutter.server_url';
const apiKeySecureStorageKey = 'dev.arsfeld.stashplayer.flutter.api_key';
```

`PlatformConnectionStore.loadStored()` reads shared preferences and secure storage separately. `loadEffective(environment)` overlays a key only when that environment entry exists; an explicitly empty `STASH_API_KEY` therefore overrides a stored key for an unauthenticated development server. `save` writes the URL preference and secure key but is called only after validation.

- [ ] **Step 5: Implement explicit connection state and controller**

Define `ConnectionPhase { initial, loading, ready, failed }` and immutable `ConnectionState(config, phase, serverVersion, fieldError, failure)`. `testAndSave` trims the URL, validates `http`/`https` plus host, creates an API, calls `version`, persists on success, and exposes typed actionable copy without embedding the key or authenticated URL.

- [ ] **Step 6: Build the reusable first-launch/settings form**

`ConnectionScreen` owns only text/focus controllers; it watches a Riverpod controller and forwards `load`, `testAndSave`, and cancel intents. Keep the URL and random-play-equivalent primary action visible at narrow widths by using `ConstrainedBox(maxWidth: 640)` plus `Wrap` for buttons. Add descriptive tooltips to reveal-key and connection actions.

- [ ] **Step 7: Verify connection behavior**

Run:

```bash
cd apps/flutter
flutter test test/features/connection
flutter test test/services
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/flutter/lib/domain/connection.dart apps/flutter/lib/services/connection_store.dart apps/flutter/lib/services/platform_connection_store.dart apps/flutter/lib/features/connection apps/flutter/test/support apps/flutter/test/features/connection
git commit -m "feat(flutter): add secure connection flow"
```

---

### Task 4: Application Providers, Routing, Theme, and Connection Replacement

**Files:**
- Create: `apps/flutter/lib/app/providers.dart`
- Create: `apps/flutter/lib/app/app_controller.dart`
- Create: `apps/flutter/lib/app/app_router.dart`
- Create: `apps/flutter/lib/app/notices.dart`
- Modify: `apps/flutter/lib/app/app.dart`
- Modify: `apps/flutter/lib/main.dart`
- Create: `apps/flutter/test/app/app_controller_test.dart`
- Modify: `apps/flutter/test/app/app_smoke_test.dart`

**Interfaces:**
- Consumes: `ConnectionStore`, `ConnectionConfig`, and the `StashApi` factory from Tasks 2-3.
- Produces: `AppController.bootstrap/replaceConnection`, `AppRoute.connection/library/scene`, `globalNoticeProvider`, and replaceable `stashApiProvider` wiring used by all later features.

- [ ] **Step 1: Write shell-state and routing tests**

Test four deterministic cases: no saved URL selects connection; a valid stored/effective connection selects library; bootstrap failure stays on connection with the error; successful settings replacement creates a new API instance, invalidates library and scene providers, returns to library, and emits `Connected to <version>` as a non-modal notice.

Add a widget test that pumps the app at 1000×700 in light and dark platform brightness and verifies the same destination renders with the matching brightness.

- [ ] **Step 2: Run the shell tests and verify missing providers**

Run: `cd apps/flutter && flutter test test/app`

Expected: FAIL because app controller/router providers are absent.

- [ ] **Step 3: Implement replaceable dependency wiring**

In `providers.dart`, expose typed Riverpod providers for `ConnectionStore`, environment, HTTP client, API factory, effective connection, and current API. Tests override them at the root `ProviderScope`; production providers construct platform implementations. Do not read providers through globals.

`AppController.replaceConnection(config)` must await validation/persistence through the connection controller, replace the current API/config only after success, then increment a shared connection generation and return to the library:

```dart
ref.read(connectionGenerationProvider.notifier).state++;
state = const AppDestination.library();
```

Define `connectionGenerationProvider` as `StateProvider<int>((ref) => 0)`. Every later library, scene, and playback provider watches it, so a successful settings change disposes all connection-bound state without forward references to features that do not exist in this task.

- [ ] **Step 4: Implement three destinations without a routing package**

Use a sealed `AppDestination` (`connection`, `library`, `scene(sceneId)`) owned by `AppController`. `AppRouter` switches on that value and uses `Navigator` pages so back from scene returns to library. Settings is a modal route containing `ConnectionScreen(settingsMode: true)` and does not replace the active API until validation succeeds.

- [ ] **Step 5: Add global non-modal notices**

Model `AppNotice(message, severity, id)` and render it through a root `ScaffoldMessenger`. Connection and library errors remain local; only successful reconnection, activity warnings, and unexpected safe failures use the root messenger.

- [ ] **Step 6: Verify bootstrap and replacement**

Run:

```bash
cd apps/flutter
flutter test test/app test/features/connection
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/flutter/lib/app apps/flutter/lib/main.dart apps/flutter/test/app
git commit -m "feat(flutter): wire application shell and routing"
```

---

### Task 5: Library Controller, Filters, Random Play, and Continuous Paging

**Files:**
- Create: `apps/flutter/lib/features/library/library_state.dart`
- Create: `apps/flutter/lib/features/library/library_controller.dart`
- Create: `apps/flutter/test/features/library/library_controller_test.dart`

**Interfaces:**
- Consumes: `StashApi.findScenes`, immutable `SceneFilter`, and an injected `int Function()` seed generator.
- Produces: `LibraryController` intents, immutable `LibraryState`, `RandomSceneSelection`, and `libraryControllerProvider`, which watches Task 4's `connectionGenerationProvider`.

- [ ] **Step 1: Write state-machine tests with controllable API completions**

Cover initial defaults, all filter changes, pagination, and races. The stale response test must issue generation 0, change search to generation 1, complete generation 1 first, then complete generation 0 and assert only generation 1 remains. The dedupe test returns IDs `[1, 2]` then `[2, 3]` and expects `[1, 2, 3]`.

Use this viewport-fill test:

```dart
test('continues loading until viewport is filled or results exhaust', () async {
  api.pages.addAll([
    ScenePage(total: 120, scenes: scenes(48, start: 0)),
    ScenePage(total: 120, scenes: scenes(48, start: 48)),
  ]);
  await controller.loadInitial();
  await controller.ensureViewportFilled(contentExtent: 500, viewportExtent: 900);
  expect(api.requestedPages, [1, 2]);
});
```

Also test no duplicate concurrent load, short page exhaustion, total-count exhaustion, error preserving accepted scenes with retry, random seed stability during normal random paging, and `playRandom` generating a fresh seed and requesting page 1/per-page 1.

- [ ] **Step 2: Run the controller tests and verify missing implementation**

Run: `cd apps/flutter && flutter test test/features/library/library_controller_test.dart`

Expected: FAIL on missing library controller types.

- [ ] **Step 3: Define explicit immutable library phases and state**

Define:

```dart
enum LibraryPhase { initial, loading, empty, ready, failed }

class LibraryState {
  const LibraryState({
    this.filter = const SceneFilter(), this.scenes = const [], this.page = 0,
    this.total = 0, this.phase = LibraryPhase.initial, this.generation = 0,
    this.hasMore = true, this.failure,
  });
  final SceneFilter filter;
  final List<Scene> scenes;
  final int page;
  final int total;
  final LibraryPhase phase;
  final int generation;
  final bool hasMore;
  final Failure? failure;
}
```

Keep `isLoading` derivable from phase rather than as a second mutable truth.

- [ ] **Step 4: Implement reset-and-fetch behavior**

Every filter intent copies the filter, clears/creates random seed as appropriate, resets page/scenes/total, increments generation, and fetches page 1. On response, compare the captured generation before updating state. Accept a page by ordered ID dedupe. `retry` requests the same next page without removing accepted scenes.

- [ ] **Step 5: Implement continuous paging and random play**

`ensureViewportFilled({required double contentExtent, required double viewportExtent})` loads one page at a time while `contentExtent <= viewportExtent`, `hasMore`, and not loading; the widget calls it again with newly measured extent after each accepted page. `playRandom()` creates a fresh non-negative 32-bit seed, requests `SceneSort.random/randomSeed=<seed>`, page 1, perPage 1, and returns the first scene or an explicit empty result.

- [ ] **Step 6: Verify the complete library state machine**

Run:

```bash
cd apps/flutter
flutter test test/features/library/library_controller_test.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/flutter/lib/features/library/library_state.dart apps/flutter/lib/features/library/library_controller.dart apps/flutter/test/features/library/library_controller_test.dart
git commit -m "feat(flutter): add race-safe library state"
```

---

### Task 6: Authenticated Thumbnail Fetching, Resizing, Cache, and Concurrency

**Files:**
- Create: `apps/flutter/lib/services/thumbnail_repository.dart`
- Create: `apps/flutter/lib/services/disk_thumbnail_repository.dart`
- Create: `apps/flutter/lib/shared/scene_placeholder.dart`
- Create: `apps/flutter/test/services/thumbnail_repository_test.dart`

**Interfaces:**
- Consumes: authenticated URL helper, `http.Client`, `getApplicationCacheDirectory`, and source URL/requested dimensions.
- Produces: `ThumbnailRepository.load(source, width, height) -> Future<Uint8List?>`, a 12-permit production repository, and stable `ScenePlaceholder` for null/failure.

- [ ] **Step 1: Write cache-key, authentication, resize, and semaphore tests**

Inject an HTTP fetch function, cache root, image resizer, and concurrency limit. Assert:

- same URL + dimensions hits disk on the second call without HTTP;
- different width or height produces a different SHA-256 filename;
- fetch receives the authenticated URL and `ApiKey` header when configured;
- existing `apikey` is not duplicated;
- 13 blocked requests never exceed 12 simultaneous fetches;
- failed HTTP/decode returns null, releases its permit, and is not cached;
- cache path begins `<application-cache>/dev.arsfeld.stashplayer.flutter/thumbnails/`.

- [ ] **Step 2: Run the service test and verify the repository is missing**

Run: `cd apps/flutter && flutter test test/services/thumbnail_repository_test.dart`

Expected: FAIL on missing thumbnail service.

- [ ] **Step 3: Implement deterministic disk keys and bounded fetches**

Build the key as:

```dart
final key = sha256.convert(utf8.encode('$source\n${width}x$height')).toString();
final file = File(path.join(cacheRoot.path, 'dev.arsfeld.stashplayer.flutter', 'thumbnails', '$key.png'));
```

Use an internal FIFO permit queue capped at 12. Within `try/finally`, fetch bytes, reject non-2xx, decode using `ui.instantiateImageCodec(bytes, targetWidth: width, targetHeight: height)`, encode the first frame as PNG, atomically write a temporary sibling then rename, and return bytes. Log only `redactSensitive` output.

- [ ] **Step 4: Add the stable placeholder widget**

`ScenePlaceholder` is a fixed aspect-ratio Material surface with `Icons.movie_outlined` and semantic label `Thumbnail unavailable`. It is used for missing URL, load failure, and decode failure and never throws into the grid.

- [ ] **Step 5: Verify thumbnails independently of library requests**

Run:

```bash
cd apps/flutter
flutter test test/services/thumbnail_repository_test.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/flutter/lib/services/thumbnail_repository.dart apps/flutter/lib/services/disk_thumbnail_repository.dart apps/flutter/lib/shared/scene_placeholder.dart apps/flutter/test/services/thumbnail_repository_test.dart
git commit -m "feat(flutter): cache bounded authenticated thumbnails"
```

---

### Task 7: Responsive Library Screen and Keyboard-Reachable Controls

**Files:**
- Create: `apps/flutter/lib/features/library/library_screen.dart`
- Create: `apps/flutter/lib/features/library/library_toolbar.dart`
- Create: `apps/flutter/lib/features/library/scene_grid.dart`
- Create: `apps/flutter/lib/features/library/scene_card.dart`
- Create: `apps/flutter/lib/shared/formatters.dart`
- Modify: `apps/flutter/lib/app/app_router.dart`
- Create: `apps/flutter/test/features/library/library_screen_test.dart`
- Create: `apps/flutter/test/shared/formatters_test.dart`

**Interfaces:**
- Consumes: `LibraryController`, `ThumbnailRepository`, `AppController.openScene`, and `AppController.openSettings`.
- Produces: adaptive `LibraryScreen`, visible filter intent mapping, measured viewport-fill callbacks, and scene navigation by ID.

- [ ] **Step 1: Write formatter and library widget tests**

Test exact duration labels (`0:05`, `1:02:03`), rating labels, title fallback, initial/loading/empty/ready/failed states, and inline retry preserving cards. At widths 1200 and 620, assert search and `Play random` remain visible; secondary controls may wrap into a second row or `Filters` popup at 620.

Assert all sort labels exactly: `Date`, `Title`, `Rating`, `Play count`, `Duration`, `Date added`, `Last updated`, `Random`. Traverse with Tab and assert focus reaches search, sort, direction, minimum rating, organized, hide tracked, random, settings, and the first scene card. Assert every icon-only control has a descriptive tooltip.

- [ ] **Step 2: Run widget tests and verify missing screen widgets**

Run: `cd apps/flutter && flutter test test/features/library test/shared/formatters_test.dart`

Expected: FAIL on missing widgets/formatters.

- [ ] **Step 3: Implement the compact responsive toolbar**

Use `LayoutBuilder`: at `maxWidth >= 760`, a `Wrap` displays every control; below 760, search and `Play random` stay in the primary row and a keyboard-accessible `MenuAnchor` contains sort, direction, minimum rating, organized, and hide tracked. Debounce search for 250 ms in the widget and cancel the timer on dispose; all other controls dispatch immediately.

- [ ] **Step 4: Implement adaptive grid, cards, and viewport feedback**

Use `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 320, childAspectRatio: 16/12)` and a `ScrollController`. Trigger `loadMore` within 600 logical pixels of the bottom. After each frame in which scene count changes, measure `position.maxScrollExtent` and `position.viewportDimension`, then call `ensureViewportFilled`; stop callbacks when the widget is unmounted.

Cards use a 16:9 thumbnail, display title, formatted duration, rating, and resume indicator. `InkWell` activation and Enter/Space both call `openScene(scene.id)`.

- [ ] **Step 5: Render every explicit recoverable state**

- Initial/loading with no data: centered progress and `Loading scenes` semantics.
- Empty: `No scenes match these filters` and a `Clear filters` action.
- Ready: accepted grid plus bottom-page progress when loading more.
- Failed with accepted scenes: cards remain plus inline banner and `Retry`.
- Failed without accepted scenes: centered safe error and `Retry`.

- [ ] **Step 6: Verify responsive and accessible library behavior**

Run:

```bash
cd apps/flutter
flutter test test/features/library test/shared
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/flutter/lib/features/library apps/flutter/lib/shared apps/flutter/lib/app/app_router.dart apps/flutter/test/features/library apps/flutter/test/shared
git commit -m "feat(flutter): build responsive scene library"
```

---

### Task 8: Application-Owned Playback Engine and `media_kit` Adapter

**Files:**
- Create: `apps/flutter/lib/features/player/playback_engine.dart`
- Create: `apps/flutter/lib/services/media_kit_playback_engine.dart`
- Create: `apps/flutter/test/support/fake_playback_engine.dart`
- Create: `apps/flutter/test/services/media_kit_playback_engine_test.dart`

**Interfaces:**
- Consumes: `media_kit.Player` and `media_kit_video.VideoController` only inside the production adapter.
- Produces: `PlaybackEngine` streams/commands, `PlaybackSnapshot`, `MediaKitPlaybackEngine`, and deterministic `FakePlaybackEngine` for all remaining tests.

- [ ] **Step 1: Define the adapter contract in a conformance test**

The interface is exact:

```dart
abstract interface class PlaybackEngine {
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<String> get errors;
  Widget buildVideoSurface({Key? key});
  Future<void> open(Uri uri, {bool play = false});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double zeroToOne);
  Future<void> setMuted(bool muted);
  Future<void> dispose();
}
```

Test that the adapter maps package volume 0-100 to interface 0-1, forwards open/play/pause/seek/mute, maps player streams, reports package errors as credential-safe strings, and disposes exactly once. Inject a narrow `MediaKitPlayerPort` in tests so no native player starts.

- [ ] **Step 2: Run the adapter test and verify the abstraction is absent**

Run: `cd apps/flutter && flutter test test/services/media_kit_playback_engine_test.dart`

Expected: FAIL on missing engine files.

- [ ] **Step 3: Implement the production adapter**

Construct one `Player` and one `VideoController(player)`. `buildVideoSurface` returns `Video(key: key, controller: videoController, fit: BoxFit.contain)`. Map `player.stream.playing`, `buffering`, `position`, `duration`, and `error`; call `player.open(Media(uri.toString()), play: play)`; clamp volume to 0-1 before multiplying by 100. Keep every `media_kit` and `media_kit_video` import in this file.

- [ ] **Step 4: Implement the deterministic fake**

The fake owns broadcast stream controllers, records typed command objects in order, exposes `emitPlaying/Buffering/Position/Duration/Error`, and closes streams during `dispose`. It must throw if a command is issued after disposal so teardown leaks surface in tests.

- [ ] **Step 5: Verify the playback boundary**

Run:

```bash
cd apps/flutter
flutter test test/services/media_kit_playback_engine_test.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/flutter/lib/features/player/playback_engine.dart apps/flutter/lib/services/media_kit_playback_engine.dart apps/flutter/test/support/fake_playback_engine.dart apps/flutter/test/services/media_kit_playback_engine_test.dart
git commit -m "feat(flutter): isolate media kit playback engine"
```

---

### Task 9: Playback Controller, Resume, Seeking, Volume, Fullscreen, and Shortcuts

**Files:**
- Create: `apps/flutter/lib/features/player/playback_state.dart`
- Create: `apps/flutter/lib/features/player/playback_controller.dart`
- Create: `apps/flutter/lib/features/player/player_shortcuts.dart`
- Create: `apps/flutter/test/features/player/playback_controller_test.dart`
- Create: `apps/flutter/test/features/player/player_shortcuts_test.dart`

**Interfaces:**
- Consumes: `Scene`, authenticated URL helper, `PlaybackEngine`, and an injected fullscreen callback.
- Produces: `PlaybackController.loadScene/playPause/seekAbsolute/seekRelative/setVolume/toggleMute/setFullscreen/handleAction/dispose`, `PlayerAction`, immutable `PlaybackState`, and `playbackControllerProvider`, which watches Task 4's `connectionGenerationProvider`.

- [ ] **Step 1: Write resume, control, and teardown tests**

Cover resume `null`, zero, middle, final 10 seconds, 97 percent, beyond duration, and positive resume with unknown duration. Assert stream source always passes through the authenticated helper before `engine.open`, then the effective resume seek occurs before play.

Cover relative clamping at zero/duration; Home/End; volume clamped to 0-1 in .05 steps; mute; fullscreen entry/exit; Escape doing nothing when not fullscreen; replacement disposing subscriptions but not the shared engine; controller disposal flushing via the Task 10 hook and disposing the engine exactly once; late events after replacement ignored by a monotonically increasing scene generation.

- [ ] **Step 2: Write the exact keyboard mapping table as parameterized tests**

Map `LogicalKeyboardKey.space` and `keyK` to toggle; Left/Right to -/+5; J/L to -/+10; Down/Up to -/+60; Home/End to start/end; Digit9/Digit0 to -/+0.05 volume; M to mute; F to fullscreen toggle; Escape to exit fullscreen. Assert modified text-entry keystrokes and unknown keys return `KeyEventResult.ignored`.

- [ ] **Step 3: Run focused tests and verify missing playback controller**

Run: `cd apps/flutter && flutter test test/features/player/playback_controller_test.dart test/features/player/player_shortcuts_test.dart`

Expected: FAIL on missing controller/state/actions.

- [ ] **Step 4: Implement explicit state and generation-safe stream binding**

Define `PlaybackPhase { initial, loading, ready, failed, disposed }` and immutable state fields: `scene`, `playing`, `buffering`, `duration`, `position`, `volume`, `muted`, `fullscreen`, `controlsVisible`, `failure`, and `generation`. On `loadScene`, increment generation, cancel prior stream subscriptions, reset transient state, resolve/authenticate stream URL, open it, seek effective resume, and bind streams with captured-generation checks.

- [ ] **Step 5: Implement clamped commands and action mapping**

`seekAbsolute` clamps to `[Duration.zero, duration]` when duration is known and flushes activity before the engine seek. `seekRelative` uses the controller's accepted position, not a stale engine query. `setVolume` clamps to `[0,1]`; digit shortcuts change by `.05`. Fullscreen state changes only after the injected platform/window callback succeeds.

Use Flutter `Shortcuts`/`Actions` with one `PlayerIntent(PlayerAction)` type. Put focus on the video region when the scene opens, but return ignored for editable text controls so typing `j`, `k`, `l`, `m`, or `f` remains possible in the metadata/search UI.

- [ ] **Step 6: Verify all playback actions without native media**

Run:

```bash
cd apps/flutter
flutter test test/features/player/playback_controller_test.dart test/features/player/player_shortcuts_test.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS using only `FakePlaybackEngine`.

- [ ] **Step 7: Commit**

```bash
git add apps/flutter/lib/features/player/playback_state.dart apps/flutter/lib/features/player/playback_controller.dart apps/flutter/lib/features/player/player_shortcuts.dart apps/flutter/test/features/player
git commit -m "feat(flutter): add deterministic playback controls"
```

---

### Task 10: Wall-Clock Activity Accounting, Checkpoints, Retry, and Flush Boundaries

**Files:**
- Create: `apps/flutter/lib/features/player/activity_sync.dart`
- Modify: `apps/flutter/lib/features/player/playback_controller.dart`
- Modify: `apps/flutter/lib/features/player/playback_state.dart`
- Create: `apps/flutter/test/support/fake_clock.dart`
- Create: `apps/flutter/test/features/player/activity_sync_test.dart`
- Modify: `apps/flutter/test/features/player/playback_controller_test.dart`

**Interfaces:**
- Consumes: `StashApi.saveSceneActivity`, scene ID, resume-position callback, injected `DateTime Function()`, injected `Future<void> Function(Duration)`, and notice callback.
- Produces: `ActivitySync.playingChanged/tick/flush/replaceScene/dispose`, queued unsaved active duration, exact retry schedule, and non-modal warning after the third retry failure.

- [ ] **Step 1: Write clock-controlled accounting and retry tests**

Tests advance a fake monotonic clock without sleeping. Prove:

- buffering/paused wall time contributes zero;
- exactly active playing intervals contribute to `playDuration`;
- a periodic tick before 10 active seconds sends nothing and at 10 seconds sends resume plus delta;
- successful checkpoint resets only the acknowledged delta;
- active time accrued during an in-flight request remains queued;
- pause, absolute/relative seek, replacement, and dispose each flush;
- failed request attempts occur immediately, then after 1, 2, and 4 seconds;
- after four total attempts (initial plus three retries), delta remains queued and one warning is emitted;
- the next lifecycle/periodic flush includes retained delta and clears it only on success;
- sync failure never calls pause or changes playing state;
- dispose cancels periodic work and does not emit callbacks after teardown.

- [ ] **Step 2: Run activity tests and verify the component is missing**

Run: `cd apps/flutter && flutter test test/features/player/activity_sync_test.dart`

Expected: FAIL on missing activity synchronization type.

- [ ] **Step 3: Implement monotonic accumulation and single-flight serialization**

Store `playStartedAt`, `queuedActive`, `lastSuccessfulCheckpointAt`, and one `_flushTail` future. Treat playback as active only while engine state is `playing && !buffering`; reevaluate on both streams. On active true, start an interval if absent. Before every flush or transition to inactive, accumulate `clock() - playStartedAt` exactly once. Serialize flushes so overlapping periodic/lifecycle triggers cannot double-send a delta.

Snapshot the queued delta at request start. On success subtract only that snapshot, preserving time added while the request ran. Send seconds as `double`, with the current engine position as `resumeTime`.

- [ ] **Step 4: Implement retries and retained-warning behavior**

Attempt once immediately. After each of the first three failures await, in order:

```dart
const retryDelays = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];
```

After the final failed retry, keep the snapshot queued, call `onWarning('Playback progress could not be synced. Playback will continue and retry later.')` once for that failed flush, and complete normally rather than throwing into playback.

- [ ] **Step 5: Wire all flush boundaries into the playback controller**

Call `playingChanged` from accepted engine playing events. Call `flush` before seek commands. Call `replaceScene` before changing the scene ID. Await `dispose` before engine disposal. Use a periodic timer only as a wakeup; the fake-clock elapsed calculation decides whether approximately 10 active seconds have actually accumulated.

- [ ] **Step 6: Verify accounting, retries, and controller integration**

Run:

```bash
cd apps/flutter
flutter test test/features/player/activity_sync_test.dart test/features/player/playback_controller_test.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS with asserted delays `[1s, 2s, 4s]` and no real sleeps.

- [ ] **Step 7: Commit**

```bash
git add apps/flutter/lib/features/player apps/flutter/test/features/player apps/flutter/test/support/fake_clock.dart
git commit -m "feat(flutter): synchronize playback activity reliably"
```

---

### Task 11: Video-First Scene Screen, Metadata Drawer, Controls, and Recovery UI

**Files:**
- Create: `apps/flutter/lib/features/player/scene_controller.dart`
- Create: `apps/flutter/lib/features/player/scene_screen.dart`
- Create: `apps/flutter/lib/features/player/video_surface.dart`
- Create: `apps/flutter/lib/features/player/transport_controls.dart`
- Create: `apps/flutter/lib/features/player/scene_metadata_drawer.dart`
- Create: `apps/flutter/lib/services/external_url_launcher.dart`
- Modify: `apps/flutter/lib/app/app_router.dart`
- Create: `apps/flutter/test/features/player/scene_screen_test.dart`

**Interfaces:**
- Consumes: `StashApi.findScene`, `PlaybackController`, `PlaybackEngine.buildVideoSurface`, global notices, base Stash URL, and `ExternalUrlLauncher.open(Uri)`.
- Produces: `SceneController.load/retry`, explicit scene states, video-first `SceneScreen`, metadata overlay, Retry/Open-in-Stash recovery, and `sceneControllerProvider`, which watches Task 4's `connectionGenerationProvider`.

- [ ] **Step 1: Write scene controller and widget tests**

Cover initial/loading/ready/not-found/failed scene loads, late scene result rejection, and controller teardown. Widget tests assert:

- video uses all content behind an overlay drawer rather than shrinking when metadata opens;
- title, details, date, studio, performers, duration, resolution, codec, and frame rate render with safe absent-field fallbacks;
- transport exposes play/pause, seek bar, elapsed/duration, volume, mute, fullscreen, and metadata controls with semantics/tooltips;
- controls remain visible while paused/buffering and auto-hide after 3 seconds while playing with no pointer/keyboard activity;
- pointer movement or keyboard action reveals controls and resets the timer;
- playback failure keeps metadata reachable and shows `Retry` and `Open in Stash`;
- `Open in Stash` resolves `/scenes/<percent-encoded-id>` against the configured server and never includes `apikey`;
- all shortcuts invoke the same controller actions as visible controls;
- Escape exits fullscreen.

- [ ] **Step 2: Run scene tests and verify the screen is missing**

Run: `cd apps/flutter && flutter test test/features/player/scene_screen_test.dart`

Expected: FAIL on missing scene UI/controller.

- [ ] **Step 3: Implement scene loading and replacement**

`SceneController.load(id)` increments a request generation, exposes loading, calls `findScene`, maps null to `NotFoundFailure`, and only accepts the response if generation still matches. On accepted scene call `PlaybackController.loadScene`; Retry repeats the same ID. Dispose invalidates generation, cancels outstanding UI timers/subscriptions, and disposes playback.

- [ ] **Step 4: Build the video-first stack and overlay drawer**

Use a full-size `Stack`:

1. black `Positioned.fill` video surface;
2. controls overlay at the bottom;
3. metadata `Align(right)` drawer with max width 420 and a scrim.

The drawer uses `AnimatedSlide`/`Material` in the stack, never a `Row`, `NavigationRail`, or resizing split pane. On wide and narrow widget sizes, assert the video surface's measured size is identical before and after opening metadata.

- [ ] **Step 5: Implement transport, focus, and auto-hide**

`video_surface.dart` renders `engine.buildVideoSurface(key: const Key('player-video'))`; only the adapter imports and constructs the package's `Video` widget. The scene/controller layers remain package-independent. Use `MouseRegion`, `Focus`, and a 3-second timer; do not hide controls while paused, buffering, focused on a control, hovering controls, or metadata is open.

- [ ] **Step 6: Implement failure recovery and safe external URL**

When engine loading fails, leave scene title and metadata button enabled over the black surface. Retry re-authenticates the stream URL via `loadScene`; Open in Stash uses only the configured base URL and scene ID. Define `ExternalUrlLauncher` as `Future<bool> open(Uri uri)` and implement it with `url_launcher.launchUrl`; never pass it an authenticated media URL.

- [ ] **Step 7: Verify scene UI, shortcuts, and responsive overlay**

Run:

```bash
cd apps/flutter
flutter test test/features/player
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/flutter/lib/features/player apps/flutter/lib/app/app_router.dart apps/flutter/test/features/player
git commit -m "feat(flutter): build video-first scene experience"
```

---

### Task 12: Integration Smoke Test, Developer Documentation, and Milestone Validation

**Files:**
- Create: `apps/flutter/integration_test/connection_library_scene_test.dart`
- Create: `apps/flutter/README.md`
- Create: `docs/flutter-runtime-validation.md`
- Modify: `tools/mock-stash/server.py`
- Modify: `tools/mock-stash/README.md`
- Modify: `README.md`
- Modify: `.github/workflows/flutter.yml`

**Interfaces:**
- Consumes: repository mock Stash server for API/UI smoke, real development Stash for playback, and every public user flow from Tasks 1-11.
- Produces: repeatable mock integration command, documented Linux/macOS launch/build commands, a signed-off manual playback checklist, and final CI coverage.

- [ ] **Step 1: Extend the mock only for deterministic test observability**

Keep its `/stream` endpoint a documented 404. Add in-memory recording for `sceneSaveActivity` and a test-only `GET /__test__/activity` JSON endpoint returning ordered `{id, resume_time, playDuration}` calls. Add `POST /__test__/reset` to clear only recorded activity. Do not add real video or authentication bypass behavior.

- [ ] **Step 2: Write the connection-to-scene integration smoke test**

Launch the app with `STASH_URL=http://127.0.0.1:9999` and empty `STASH_API_KEY`. The test must:

```dart
await tester.pumpAndSettle();
expect(find.text('Aurora Over Tromsø'), findsOneWidget);
await tester.enterText(find.byKey(const Key('library-search')), 'Kyoto');
await tester.pump(const Duration(milliseconds: 300));
await tester.pumpAndSettle();
expect(find.text('Kyoto Cherry Blossoms'), findsOneWidget);
await tester.tap(find.text('Kyoto Cherry Blossoms'));
await tester.pumpAndSettle();
expect(find.text('Retry'), findsOneWidget); // mock stream intentionally returns 404
expect(find.byTooltip('Show scene information'), findsOneWidget);
```

Use stable keys/types exported by the actual widgets rather than text-only lookup where localization or duplicate labels make a finder ambiguous.

- [ ] **Step 3: Run the smoke test against the repository mock**

In terminal one:

```bash
python3 tools/mock-stash/server.py
```

In terminal two:

```bash
cd apps/flutter
STASH_URL=http://127.0.0.1:9999 STASH_API_KEY= flutter test integration_test/connection_library_scene_test.dart -d linux
```

Expected: PASS through connection, library, filter, scene metadata, and recoverable playback failure. On macOS, replace `-d linux` with `-d macos`.

- [ ] **Step 4: Document the reproducible development loop**

`apps/flutter/README.md` must contain exact `nix develop`, `flutter pub get`, `flutter run -d linux|macos`, format/analyze/test/build commands, mock-server limitations, real Stash options (`docker compose` or `devenv up`), runtime environment override semantics, cache/settings/key names, and troubleshooting for Linux Secret Service and `media_kit` native libraries.

Update the root README repository layout and build sections to describe Flutter as experimental; do not describe it as replacing either released client.

- [ ] **Step 5: Create and execute the real playback acceptance checklist on Linux**

Create `docs/flutter-runtime-validation.md` with a table recording date, commit SHA, OS/hardware, media codec, result, and notes for:

- H.264 and H.265 video rendering;
- hardware decoder shown by the host's player diagnostics where supported;
- audio;
- play/pause, scrub/absolute seek, and every relative seek shortcut;
- Home/End, volume ±5 percent, mute, fullscreen, and Escape;
- mid-scene resume and completed-scene restart;
- periodic resume/play-duration writeback after 10 active seconds;
- pause, seek, replacement, and close/dispose flushes;
- network failure warning with uninterrupted playback and later recovery.

Run the checklist against a real development Stash instance and representative media on Linux. Record observed results; do not mark unrun checks passed.

- [ ] **Step 6: Execute the same real playback checklist on macOS**

Run the identical checklist on macOS with representative H.264/H.265 media and record VideoToolbox/hardware behavior where supported. Any unavailable host or failed item remains explicitly unchecked and blocks milestone acceptance, but does not block committing the implementation and documentation.

- [ ] **Step 7: Add integration smoke to CI without claiming playback coverage**

In each Flutter workflow job, start `python3 tools/mock-stash/server.py` in the background, register a shell trap to terminate it, wait for `http://127.0.0.1:9999/graphql` to accept requests, run the platform integration smoke, and then run the debug build. Name the step `Connection/library smoke (mock stream; no playback validation)`.

- [ ] **Step 8: Run the final automated gates**

Run from the repository root:

```bash
cd apps/flutter
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
flutter build linux --debug   # Linux
flutter build macos --debug   # macOS
cd ../..
cargo test -p stash-api -p stash-player-core
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: every host-applicable command PASS. Confirm the dedicated GitHub workflow passes both platform jobs and existing Rust/Flatpak/native-macOS workflows remain green.

- [ ] **Step 9: Commit**

```bash
git add apps/flutter/integration_test apps/flutter/README.md docs/flutter-runtime-validation.md tools/mock-stash README.md .github/workflows/flutter.yml
git commit -m "test(flutter): validate desktop vertical slice"
```
