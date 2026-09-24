# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The shipped app is `apps/flutter/`, a Flutter desktop client for Linux and
macOS (application id `dev.arsfeld.stash-player`). The original Rust/GTK
and Swift/AVKit clients under `crates/` and `apps/macos/` are frozen — see
"Legacy clients (frozen)" under Architecture below.

## Build & run

```sh
# Dev shell — Flutter SDK + the native libs media_kit needs (libmpv on
# Linux; the same runtime libs as the legacy default shell). `.envrc`
# (`use flake`) only activates the default shell, so this one is always
# explicit.
nix develop .#flutter

just flutter-run       # build debug + launch, wired to STASH_URL/STASH_API_KEY
just flutter-check     # format + analyze + test — mirrors CI; run before committing

# Local Flatpak build via the flake (cleans, exports, installs as user):
nix run .#flatpak
flatpak run dev.arsfeld.stash-player
```

`STASH_URL` / `STASH_API_KEY` env vars override the persisted connection
for the running process only (never written back) — see
`apps/flutter/lib/app/providers.dart`'s `environmentProvider` and
`overlayEnvironment` in `lib/domain/connection.dart`. `just --list` lists
every recipe, including platform-specific ones (`flutter-build`,
`flutter-launch`, `flutter-env`) and the legacy Rust ones (`test`, `lint`,
`run`). Full setup, build, and troubleshooting detail lives in
`apps/flutter/README.md`.

## Tests

```sh
just flutter-check                                # Flutter: format, analyze, test — the CI gate
cargo test -p stash-api -p stash-player-core       # legacy Rust crates (frozen, still CI-tested)
```

## Lints

CI still gates the legacy Rust crates on clippy, scoped to `crates/**` and
the workspace manifests (`.github/workflows/tests.yml`). Workspace lints
live in the root `Cargo.toml` under `[workspace.lints]`; `clippy.toml`
holds threshold values. Each crate inherits via `[lints] workspace = true`.

```sh
# What CI enforces:
cargo clippy --workspace --all-targets -- -D warnings
```

Active rules:

- **rust**: `unsafe_code = forbid`, `unreachable_pub = warn`.
- **clippy size/complexity ceilings**: `too_many_lines` (100/fn), `too_many_arguments` (7), `cognitive_complexity` (25), `excessive_nesting` (5), `type_complexity` (250), `fn_params_excessive_bools` / `struct_excessive_bools` (3), `large_enum_variant` (200 B).
- **clippy quality guardrails**: `dbg_macro`, `todo`, `unimplemented`, `semicolon_if_nothing_returned`.

**No `#[allow(...)]` exceptions.** When a lint fires, fix the structure: extract helpers for long functions, group related bool flags into an enum or sub-struct, box heavy enum variants, replace nested `if let` chains with let-chains or early returns, swap `pub` for `pub(crate)` in this binary crate. Don't reach for `glib::ObjectExt::set_data` (forbidden by `unsafe_code`) — keep per-widget state on the model side keyed by index.

`stash-api` integration tests use `wiremock` and JSON fixtures under `crates/stash-api/tests/fixtures/`. Live-server examples (`cargo run -p stash-api --example version|scenes`) read `STASH_URL` + `STASH_API_KEY` from the environment.

## Architecture

### Flutter client (`apps/flutter/`)

The shipped app. Riverpod for state; no routing package —
`lib/app/app_router.dart` hand-rolls a `Navigator` `pages` list over a
small destination union instead.

- **`lib/app/`** — wiring: `AppController` (the `AppDestination` union —
  connection / library / scene — plus bootstrap), `AppRouter`
  (destination → page), `providers.dart` (the
  provider graph: HTTP client, SOCKS proxy, connection store, thumbnail
  repo), `app.dart` (`MaterialApp` + toast/notice plumbing).
- **`lib/domain/`** — pure data + rules, no I/O: `connection.dart`
  (`ConnectionConfig`, the env-override precedence rules), `scene.dart`,
  `scene_filter.dart`, `scene_stream.dart`, `browse_context.dart`
  (prev/next ordering), `job.dart`, `failure.dart`.
- **`lib/features/{connection,library,player}`** — Riverpod controllers +
  screens per area: `connection/` (the connection screen), `library/`
  (grid, toolbar, sort/filter, background-tasks controller), `player/`
  (the video-first scene screen — `scene_controller.dart`,
  `playback_controller.dart` / `playback_engine.dart`,
  `activity_sync.dart`, OSD widgets, keyboard shortcuts).
- **`lib/services/`** — the I/O ports: `http_stash_api.dart` (`StashApi`
  over GraphQL, 15s request timeout), `platform_connection_store.dart`
  (`shared_preferences` + `flutter_secure_storage`, plus the one-time
  legacy import — `legacy_config.dart`, `legacy_connection_importer.dart`,
  `legacy_secret_reader.dart`), `socks_forward_proxy.dart` (loopback
  HTTP→SOCKS5 hop, since `media_kit`'s player can't be pointed at a proxy
  directly — same rationale as the legacy `stash-player-proxy` crate),
  `media_kit_playback_engine.dart` (adapts `package:media_kit`'s `Player`
  to `PlaybackEngine` behind a narrow `MediaKitPlayerPort` interface so
  tests never touch native playback), `disk_thumbnail_repository.dart`
  (decode + disk cache, namespaced under
  `dev.arsfeld.stashplayer.flutter`), `authenticated_url.dart`.
- **`lib/ui/`**: the drawn widget layer, per `PlatformDialect` (`adwaita`
  | `macos`, from `Theme.of(context).platform`): `theme/` (palettes, type
  scale, component themes, `buildAppTheme`), `icons/` (`AppIcon` → GNOME
  icon-development-kit SVGs on Linux, Lucide on macOS, fetched by
  `tool/fetch_icons.py`, which also rewrites GNOME `url(#gpa:foreground)
  <fallback>` paint values to the fallback colour, since `flutter_svg`
  would otherwise drop the paint and draw the icon blank; a test guards
  this),
  `menu/` (`AppMenu` specs; `NativeMenus` shows them natively via
  `ChannelNativeMenus`, drawn in tests), `widgets/` (strip controls,
  spinner, toast, tile). `lib/ui/` never imports Riverpod.
- **Native runners** — `linux/runner/my_application.cc` and
  `macos/Runner/MainFlutterWindow.swift` implement the
  `stash_player/legacy_secret` method channel (`readApiKey`) that
  `LegacySecretReader` calls: `secret_password_lookup_sync` on Linux,
  `SecItemCopyMatching` on macOS — both read the legacy client's stored
  key without touching `flutter_secure_storage`'s own namespace.
  `macos/Runner/AppDelegate.swift` owns the `SPUStandardUpdaterController`
  (Sparkle) and the "Check for Updates…" menu action. The runners also
  implement `stash_player/menu` (`NSMenu` / `GtkMenu` popups;
  `native_menu_channel.cc` on Linux, which also answers `popup-failed`
  when a GTK popup's grab fails, so `ChannelNativeMenus` falls back to
  `DrawnMenus`), `stash_player/appearance` (OS accent colour, plus
  GNOME's UI font via the settings portal; `appearance_channel.cc`), and
  on macOS `stash_player/updates` (Sparkle). The macOS menu bar is built
  in Dart (`lib/app/app_menu_bar.dart`), watching only `playing`/
  `muted` from the playback controller so it isn't re-sent
  to AppKit on every playback tick; it replaces `MainMenu.xib`'s bar at
  startup, and the xib itself is trimmed to its app menu only.
- **Flatpak's libmpv stack** — `build-aux/dev.arsfeld.stash-player.yml`
  builds `libass`, `libplacebo`, and `libmpv` from source as their own
  modules before the app module, since `media_kit_libs_linux` needs
  libmpv present in the sandbox when the Flutter build links it. See
  "Flatpak notes" below.

### Legacy clients (frozen)

`crates/` (Rust) and `apps/macos/` (SwiftUI) are the original clients.
Neither ships anymore — `apps/flutter/` took over their app identities and
update channel — and no new features land here. `crates/` is still built,
linted, and tested by CI (`tests.yml`, scoped to `crates/**` and the
workspace manifests); `apps/macos/` is no longer built by CI at all, only
locally via `nix run .#macos`.

- **`stash-api`** — thin `reqwest`-based GraphQL client. `Client::new(base_url, api_key)` injects an `ApiKey` header and exposes `version`, `find_scenes`, `find_scene`, `save_scene_activity`, `increment_o`/`reset_o`, `fetch_bytes`, and `authenticated_url` (bakes `apikey=` into a query string for consumers that can't carry the header, careful not to double-append).
- **`stash-player-core`** — config (`directories` + `serde`), `secrets` (Secret Service on Linux / Keychain on macOS, async on both), `cache` paths for thumbnails, and `playback::SeekTracker`, the pure position model the GTK player polls into.
- **`stash-player-proxy`** — the loopback SOCKS forward proxy the GTK and macOS players route media bytes through (the Flutter client has its own Dart equivalent, `socks_forward_proxy.dart`, above).
- **`stash-player-ui`** — the relm4/GTK4/libadwaita binary. `app.rs` owns the `AdwNavigationView` (Library/Scene/Settings); `pages/library.rs` the `FlowBox` grid; `pages/scene/` the video-first scene page; `widgets/video_player/` the hand-built `playbin3` + `gtk4paintablesink` pipeline with mpv-style shortcuts.
- **`stash-player-ffi`** — UniFFI bridge consumed by the SwiftUI app; wraps the same `stash-api` `Client` behind sync methods, called via `block_on` on a global tokio runtime.
- **`apps/macos/`** — SwiftUI + AVKit, generated by `xcodegen` from `project.yml` (never hand-edit `StashPlayer.xcodeproj`). Mirrors the GTK feature surface; `Scene/PlayerView.swift` wraps `AVPlayerView`; `Scene/NowPlaying.swift` wires `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter`.

```sh
nix develop
cargo run -p stash-player-ui   # GTK client

nix run .#macos                # SwiftUI app: rust → xcframework → xcodeproj → xcodebuild → launch
nix run .#macos-build          # same, minus the launch (refreshes Generated/)
```

Gotchas worth keeping if you touch this code: `build-aux/build-macos-xcframework.sh`'s `mktemp -d -t stash-player-ffi-headers.XXXXXX` needs the `XXXXXX` (GNU mktemp requirement); `xcodebuild` must run outside `nix develop`'s PATH, or with a clean one (`env -i PATH=/usr/bin:/bin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...`), since clang-wrapper's `ld` there rejects `-Xlinker` flags — `nix run .#macos` already does this via `writeShellApplication`.

## Conventions

- **Keep network code in the API layer.** Flutter: `lib/services/stash_api.dart`'s `StashApi` interface and `http_stash_api.dart`'s implementation — feature/UI code shouldn't construct HTTP requests itself. Legacy Rust: the same rule for `stash-api`, with a fixture-backed test per query.
- **Authenticated media URLs** go through each client's `authenticated_url` (`lib/services/authenticated_url.dart`, or `stash_api::Client::authenticated_url`) — `media_kit`'s libmpv backend, GStreamer, and AVPlayer can't carry an `ApiKey` request header.
- **Design docs:** `docs/superpowers/specs/` holds the living design docs for current work (e.g. `2026-09-23-flutter-first-class-release-design.md`). `PLAN.md` is the frozen GTK client's original milestone tracker — see the legacy-document note at its top.
- **libadwaita first** (legacy GTK client only): Adw widgets (`AdwApplicationWindow`, `AdwNavigationView`, `AdwViewStack`, `AdwToastOverlay`, …) before raw GTK4; no hand-rolled chrome or settings dialogs.

## Flatpak notes

- Manifest at `build-aux/dev.arsfeld.stash-player.yml` targets `org.gnome.Platform`/`Sdk` 50, plus the SDK's `llvm21` extension — Flutter's Linux build drives CMake with clang/clang++, which the GNOME runtime doesn't otherwise provide.
- `libass`, `libplacebo`, and `libmpv` are built from source as their own modules (each pinned by git tag + commit), since the runtime doesn't ship them and `media_kit_libs_linux` needs libmpv present at build time — before the `stash-player` module runs `flutter build linux --release` inside the sandbox.
- Pulls `org.freedesktop.Platform.codecs-extra` (25.08-extra) so H.264 / H.265 / AAC / AC-3 actually play — libmpv links the runtime's FFmpeg, and codecs-extra supplies the encumbered decoders at the same mount point as before.
- The `stash-player` module's `build-args` include `--share=network`, since `flutter pub get` and the Flutter tool's own bootstrapping need network access inside the sandbox — the same allowance the legacy Rust build used for cargo.
- `--filesystem=xdg-config/stash-player:ro` exposes the legacy GTK client's config directory read-only, for the one-time connection import; nothing else legacy is shared.
- `nix run .#flatpak` builds and installs it locally via a separate `nixpkgs-flatpak` flake input, pinned independently of the main `nixpkgs` (whose older `appstream` can't read SVG icons during `appstreamcli compose`).
- Release tagging (`v*`) triggers `.github/workflows/flatpak.yml`, which attaches `stash-player.flatpak` to the GitHub release; its cache key is `hashFiles('apps/flutter/pubspec.lock', 'build-aux/dev.arsfeld.stash-player.yml')`.
