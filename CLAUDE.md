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
flatpak run one.arsfeld.stash-player
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

`stash-api` integration tests use `wiremock` and JSON fixtures under `crates/stash-api/tests/fixtures/`. Live-server examples (`cargo run -p stash-api --example version|scenes`) read `STASH_URL` + `STASH_API_KEY` from the environment.

## Architecture

Three crates kept narrow so the GUI doesn't tangle with networking:

- **`stash-api`** — thin `reqwest`-based GraphQL client. Hand-rolled queries, no codegen yet. `Client::new(base_url, api_key)` injects an `ApiKey` header on every request and exposes `version`, `find_scenes(filter, page, per_page)`, `find_scene(id)`, `save_scene_activity(id, resume_time, play_duration)`, `fetch_bytes(url)`, and `authenticated_url(url)`. The last one bakes `apikey=` into a query string — needed when the consumer (GStreamer media stack, `<video>` tag) can't carry the request header. It's careful not to double-append if Stash already returned an authenticated URL.
- **`stash-player-core`** — config (`~/.config/stash-player/config.toml` via `directories` + `serde`), Linux Secret Service-backed `secrets` module for the API key, and `cache` paths for `XDG_CACHE_HOME/stash-player/thumbs/`. No `tokio` runtime here, but the secrets module is async because `secret-service` is.
- **`stash-player-ui`** — relm4 binary. `main.rs` initializes GStreamer + CSS + a `RelmApp`, then hands control to `AppModel`.

### UI component layout (`stash-player-ui/src/`)

- `app.rs` — `AppModel` owns the `AdwApplicationWindow`, the shared `stash_api::Client` (built once configured), and an `AdwNavigationView` that pushes/pops Library / Scene / Settings. Subtlety: it listens for `connect_popped` to drop the `ScenePage` controller when its page leaves the stack — otherwise the `MediaFile`/playbin keeps audio playing in the background.
- `pages/library.rs` — `gtk::FlowBox` of scene cards with a top toolbar (search, sort, asc/desc, organized switch, min-rating, "play random"). Infinite scroll via `edge-reached`, 24 scenes per fetch. Thumbnails are decoded + resized to 240×135 RGBA8 via the `image` crate, cached on disk by URL hash + dimensions, gated by a 12-permit semaphore.
- `pages/scene.rs` — inline `VideoPlayer`, metadata, performer chips (`AdwAvatar`), prev/next neighbour navigation honouring the library's current filter.
- `pages/settings.rs` — Stash URL + API key + test-connection button + theme.
- `widgets/video_player.rs` — hand-built GStreamer `playbin3` pipeline driving a `gtk4paintablesink`, painted into a `gtk::Picture` wrapped in `gtk::GraphicsOffload` (4.14+) for compositor-direct video. Custom OSD overlay, mpv-style keyboard shortcuts (see README). Polls position at 4 Hz; suppresses the seek-slider feedback loop with an `Rc<Cell<bool>>` flag. Activity writeback (`sceneSaveActivity`) is throttled to ~10s and flushed on pause / seek / close.
  - The PLAN/README still describes `gtk::MediaFile`; the code has since moved to a hand-built `playbin3` pipeline so we can do things `MediaFile` couldn't (manual sink, more pipeline control). Update docs in lockstep if you reverse this.

### Async pattern

Async work goes through `ComponentSender::oneshot_command` (one `tokio` task per request) rather than long-lived workers. The shared `stash_api::Client` is held by `AppModel` and cloned into each component that needs it via relm4 messages (e.g. `LibraryMsg::SetClient`). `tokio` is `rt-multi-thread` in the UI crate.

## Conventions

- **libadwaita first.** Use Adw widgets (`AdwApplicationWindow`, `AdwNavigationView`, `AdwViewStack`, `AdwPreferencesWindow`, `AdwToastOverlay`, `AdwAvatar`, `AdwBanner`, `AdwToast`) before reaching for raw GTK4. No hand-rolled chrome / settings dialogs — see `PLAN.md` "UX principles".
- **Keep network code in `stash-api`.** UI components shouldn't construct HTTP requests; if a new query is needed, add it to `stash-api` with a fixture-backed test.
- **Authenticated media URLs** must go through `Client::authenticated_url` — GTK's media stack and `<video>`-style consumers can't carry the `ApiKey` header.
- `PLAN.md` is the living design doc and milestone tracker. Skim it before non-trivial UI changes.

## Flatpak notes

- Manifest at `build-aux/one.arsfeld.stash-player.yml` targets `org.gnome.Platform` 50.
- Pulls `org.freedesktop.Platform.codecs-extra` (25.08-extra) so H.264 / H.265 / AAC / AC-3 actually play — the freedesktop runtime ships `gst-libav` but not the encumbered codec libs.
- Local Flatpak builds need network access (`--share=network`) so cargo can fetch crates. Flathub submission would require offline-vendored sources via `flatpak-cargo-generator`.
- Release tagging (`v*`) triggers `.github/workflows/flatpak.yml`, which attaches `stash-player.flatpak` to the GitHub release.
