# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

The project is a Rust 2024 edition Cargo workspace; the binary is `stash-player-ui`.

```sh
# Dev shell (NixOS) — pulls Rust + GTK4/libadwaita + GStreamer plugins (incl.
# gst-plugins-rs for gtk4paintablesink) + libsecret. direnv is wired via
# .envrc, so `direnv allow` does the same.
nix develop
cargo run -p stash-player-ui

# Local Flatpak build via the flake (cleans, exports, installs as user):
nix run .#flatpak
flatpak run dev.arsfeld.stash-player
```

`STASH_URL` / `STASH_API_KEY` env vars (loaded via `.env` for dev convenience) override the persisted config + keyring entry on launch (see `crates/stash-player-ui/src/main.rs`). The keyring is the real source of truth for the API key.

Logging is `tracing-subscriber` with default `info,stash_player_ui=debug`; tweak with `RUST_LOG=...`.

## Tests

Only `stash-api` and `stash-player-core` are tested. The UI crate has no tests by design — relm4 + GStreamer needs end-to-end runs.

```sh
# Mirror what CI runs (.github/workflows/tests.yml):
cargo test -p stash-api -p stash-player-core

# Single test:
cargo test -p stash-api version_query_round_trips
```

## Lints

Workspace lints live in the root `Cargo.toml` under `[workspace.lints]`; `clippy.toml` holds threshold values. Each crate inherits via `[lints] workspace = true`. CI gates the build on `cargo clippy --workspace --all-targets -- -D warnings`, so any warning fails the pipeline.

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

Three crates kept narrow so the GUI doesn't tangle with networking:

- **`stash-api`** — thin `reqwest`-based GraphQL client. Hand-rolled queries, no codegen yet. `Client::new(base_url, api_key)` injects an `ApiKey` header on every request and exposes `version`, `find_scenes(filter, page, per_page)`, `find_scene(id)`, `save_scene_activity(id, resume_time, play_duration)`, `increment_o(id)` / `reset_o(id)` (Stash's per-scene "O counter" mutations — both return the new count), `fetch_bytes(url)`, and `authenticated_url(url)`. The last one bakes `apikey=` into a query string — needed when the consumer (GStreamer media stack, `<video>` tag) can't carry the request header. It's careful not to double-append if Stash already returned an authenticated URL.
- **`stash-player-core`** — config (via `directories` + `serde`), `secrets` module for the API key (Linux Secret Service or macOS Keychain depending on `target_os`, both behind the same async facade), and `cache` paths for thumbnails. The secrets module is async on both platforms — Linux because `secret-service` is, macOS because we wrap `security-framework` in `tokio::task::spawn_blocking`. `playback` holds `SeekTracker`, the pure position model shared by the UI's player (and available to the macOS app if its seek handling ever needs the same treatment).
- **`stash-player-ui`** — relm4 binary. The Linux app. `main.rs` initializes GStreamer + CSS + a `RelmApp`, then hands control to `AppModel`.
- **`stash-player-ffi`** — UniFFI bridge consumed by the macOS SwiftUI app. Sync FFI methods (`connect`, `list_scenes`, `get_scene`, `save_activity`, `increment_o`, `reset_o`, `authenticated_url`, `fetch_thumbnail`, `load_saved_credentials`, `save_credentials`) wrap the same `stash-api` Client; calls run on a global multi-thread tokio runtime via `block_on`. Swift dispatches off the main thread with `Task.detached`. `list_scenes` takes an `FfiSceneFilter` record mirroring `stash_api::SceneFilter` field-for-field (sort, direction, min rating, organized, hide-tracked, random seed) — the macOS library owns its filter state in Swift and rebuilds the FFI record per request.

### UI component layout (`stash-player-ui/src/`)

- `app.rs` — `AppModel` owns the `AdwApplicationWindow`, the shared `stash_api::Client` (built once configured), and an `AdwNavigationView` that pushes/pops Library / Scene / Settings. Subtlety: it listens for `connect_popped` to drop the `ScenePage` controller when its page leaves the stack — otherwise the player's `playbin3` pipeline keeps audio playing in the background.
- `pages/library.rs` — `gtk::FlowBox` of scene cards with a top toolbar (search, sort, asc/desc, organized switch, min-rating, hide-tracked switch, "play random"). The hide-tracked switch defaults ON so the library opens to "untracked only" (`o_counter = 0`). Pagination re-checks the scroll adjustment after every page lands and on every scroll, 48 scenes per fetch — an `edge-reached` trigger alone stalls on a large monitor, where the first page never overflows the viewport and so nothing ever scrolls. Thumbnails are decoded + resized to 240×135 RGBA8 via the `image` crate, cached on disk by URL hash + dimensions, gated by a 12-permit semaphore.
- `pages/scene/` — video-first scene page. `mod.rs` owns the component:
  the player fills the content area of an `adw::OverlaySplitView` pinned
  to `collapsed: true`, so the metadata drawer (performers, about, file
  info) overlays the video rather than reallocating it. Title and
  subtitle live in the header's `adw::WindowTitle`; autoplay and "Open in
  Stash" in its `⋯` menu; prev/next, the O-counter, and the rating are
  rendered by the player OSD and round-trip through a single
  `SetSceneActions` / `SceneAction` message pair so the player stays
  ignorant of what they mean. `SceneActionState.o_count` is
  `Option<i32>` — `None` means no scene is loaded (mid-navigation) and
  gates the OSD O-counter group insensitive, a different absence than
  `rating100`'s `None` ("loaded, but unrated"). `metadata.rs` holds the
  `populate_*` helpers — all of which **clear before building**, since
  appending to a persistent container is what made the File rows
  accumulate across navigations. Prev/next set a `navigating` flag
  rather than swapping the stack, so the paintable widget is never
  remapped mid-browse.
- `pages/settings.rs` — Stash URL + API key + test-connection button + theme.
- `widgets/video_player/` — hand-built GStreamer `playbin3` pipeline
  driving a `gtk4paintablesink`, painted into a `gtk::Picture` wrapped in
  `gtk::GraphicsOffload` (4.14+) for compositor-direct video. `pipeline.rs`
  owns the GStreamer half; `mod.rs` the relm4 component. Custom OSD
  overlay, mpv-style keyboard shortcuts (see README). Polls position at
  4 Hz into a `stash_player_core::playback::SeekTracker`, which ignores
  readings inconsistent with an outstanding seek — without it, `ACCURATE`
  seeks that outlast a poll interval let a stale position clobber the
  model and every subsequent relative seek lands in the same place.
  Activity writeback (`sceneSaveActivity`) is throttled to ~10s and
  flushed on pause / seek / close.

### macOS app (`apps/macos/`)

SwiftUI + AVKit, peer frontend to the Linux GTK app. Xcode project is
generated by `xcodegen` from `apps/macos/project.yml` — never hand-edit
`StashPlayer.xcodeproj`; regenerate it instead. Sources live under
`apps/macos/StashPlayer/` (`StashPlayerApp.swift`, `AppState.swift`,
`ContentView.swift`, `Settings/`, `Library/`, `Scene/`). Generated UniFFI
bindings drop into `apps/macos/StashPlayer/Generated/` and are checked in.

Feature surface mirrors the GTK app (PLAN.md milestone 7): library
toolbar with sort/direction/min-rating/organized/hide-tracked/play-random,
scene detail with prev/next navigation honouring the active filter,
performer chips, star-rating overlay, O-counter increment/reset, "Open
in Stash". Player layered on `AVPlayerView` via `NSViewRepresentable`
(`Scene/PlayerView.swift`) — keyboard shortcuts (Space/k, ←/→ ∓5s, j/l
∓10s, ↑/↓ ±60s, m/f/9/0) intercept `keyDown`; native window-level
fullscreen via `window?.toggleFullScreen(_:)`. Activity throttle in
`SceneView` is a 0.25 Hz periodic time observer with a 10s flush
interval, plus rate-KVO that flushes on pause and `tearDownPlayer(flush:)`
that flushes on prev/next swap and disappear. macOS-native extras
(`Scene/NowPlaying.swift`): `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`
power media keys / AirPods / menu-bar Now Playing widget; PiP is on by
default via `AVPlayerView.allowsPictureInPicturePlayback`.

**Build script gotcha:** `build-aux/build-macos-xcframework.sh` runs
`mktemp -d -t stash-player-ffi-headers.XXXXXX`. The Xs are required —
GNU coreutils mktemp (which the Nix dev shell ships) refuses templates
without them. **xcodebuild gotcha:** running inside `nix develop` puts
clang-wrapper's `ld` ahead of Xcode's, which makes the linker reject
`-Xlinker` flags. Run xcodebuild outside the dev shell, or with a
clean PATH (`env -i PATH=/usr/bin:/bin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...`).
The `nix run .#macos` flake app already does this implicitly because
`writeShellApplication`'s `runtimeInputs` doesn't pull in the cc-wrapper
that `mkShell` does.

Build flow: `./build-aux/build-macos-xcframework.sh` builds
`stash-player-ffi` for `aarch64-apple-darwin` (with `MACOSX_DEPLOYMENT_TARGET=14.0`
to match the Swift target), runs `uniffi-bindgen --language swift`, and
packages everything as `apps/macos/StashPlayerFFI.xcframework`. The Xcode
target links the xcframework as a static dependency. Re-run the script
after any Rust change in `stash-player-ffi` or its deps.

Flake shortcuts (defined per-system in `flake.nix`):

- `nix develop` — pinned Rust toolchain + `xcodegen` + `MACOSX_DEPLOYMENT_TARGET=14.0`. On Linux, the same shell still pulls in GTK4/libadwaita/GStreamer/libsecret for the relm4 binary.
- `nix run .#macos-build` — runs `build-macos-xcframework.sh` + `xcodegen generate`. No xcodebuild.
- `nix run .#macos` — same plus `xcodebuild -derivedDataPath build-aux/macos-derived` and launches the resulting `.app` via `open -a`. This is the one-shot dev-loop entry point.
- `nix run .#flatpak` (Linux only) — unchanged.

Apple toolchain (`xcodebuild`, `xcrun`, `lipo`, `open`) is not in nixpkgs; it's picked up from the host via the user's `$PATH`, which `writeShellApplication` preserves.

The macOS Keychain entry uses `service = "stash-player"`, `account =
"stash-api-key"`. AVPlayer plays the URL returned by
`StashPlayer.authenticatedUrl(...)` (i.e. with `?apikey=` baked in,
because AVPlayer can't carry an `ApiKey` request header — same constraint
as GStreamer). UI code goes in `apps/macos/`; new GraphQL queries still go
in `stash-api` so both frontends pick them up.

### Async pattern

Async work goes through `ComponentSender::oneshot_command` (one `tokio` task per request) rather than long-lived workers. The shared `stash_api::Client` is held by `AppModel` and cloned into each component that needs it via relm4 messages (e.g. `LibraryMsg::SetClient`). `tokio` is `rt-multi-thread` in the UI crate.

## Conventions

- **libadwaita first.** Use Adw widgets (`AdwApplicationWindow`, `AdwNavigationView`, `AdwViewStack`, `AdwPreferencesWindow`, `AdwToastOverlay`, `AdwAvatar`, `AdwBanner`, `AdwToast`) before reaching for raw GTK4. No hand-rolled chrome / settings dialogs — see `PLAN.md` "UX principles".
- **Keep network code in `stash-api`.** UI components shouldn't construct HTTP requests; if a new query is needed, add it to `stash-api` with a fixture-backed test.
- **Authenticated media URLs** must go through `Client::authenticated_url` — GTK's media stack and `<video>`-style consumers can't carry the `ApiKey` header.
- `PLAN.md` is the living design doc and milestone tracker. Skim it before non-trivial UI changes.

## Flatpak notes

- Manifest at `build-aux/dev.arsfeld.stash-player.yml` targets `org.gnome.Platform` 50.
- Pulls `org.freedesktop.Platform.codecs-extra` (25.08-extra) so H.264 / H.265 / AAC / AC-3 actually play — the freedesktop runtime ships `gst-libav` but not the encumbered codec libs.
- Local Flatpak builds need network access (`--share=network`) so cargo can fetch crates. Flathub submission would require offline-vendored sources via `flatpak-cargo-generator`.
- Release tagging (`v*`) triggers `.github/workflows/flatpak.yml`, which attaches `stash-player.flatpak` to the GitHub release.
