# stash-player — Plan

A native Linux desktop client for [Stash](https://github.com/stashapp/stash):
browse the library and play scenes locally.

## Decisions locked in

| Concern | Choice |
| --- | --- |
| Platform | Linux desktop only (Wayland + X11 via GTK) |
| Language | Rust (2024 edition) |
| UI framework | [relm4](https://relm4.org) on GTK4 + libadwaita |
| UI design goal | User-friendly, GNOME HIG-compliant, polished out of the box |
| Video pipeline | GTK's built-in `gtk::MediaFile` (GStreamer under the hood) |
| Stash API | GraphQL over HTTP (Stash exposes `/graphql`) |

Rationale on the big ones:

- **relm4 + GTK4 + libadwaita** gives us a polished native Linux look, a real
  video widget (`gtk4paintablesink` drops GStreamer frames straight into a GTK
  paintable), and the Elm-style message/component model that suits a media
  client well. libadwaita is non-negotiable for the UI: we use its widgets
  (`AdwApplicationWindow`, `AdwNavigationView`, `AdwViewStack`,
  `AdwPreferencesWindow`, `AdwToastOverlay`, `AdwAvatar`, etc.) so the app
  feels at home on GNOME and looks friendly to non-technical users — no raw
  GTK4 chrome, no hand-rolled settings dialogs.
- **`gtk::MediaFile`** wraps GStreamer for us — it implements both
  `GdkPaintable` and `GtkMediaStream`, so we drop it straight into a
  `gtk::Picture` and get prepared / duration / playing / error signals
  back. We give up `playbin3`-level pipeline control (manual sink
  selection, HLS-vs-progressive fallback), but in exchange the player
  surface is a few hundred lines instead of thousands. We can drop to
  `gstreamer-rs` directly if a feature we need (subtitle tracks,
  transcode-fallback on pipeline error) forces it.

## Crate plan

Workspace with focused crates so the GUI doesn't get tangled with networking:

```
stash-player/
├── Cargo.toml                  # workspace
├── crates/
│   ├── stash-api/              # GraphQL client, auth, types
│   ├── stash-player-core/      # app state, config, persistence
│   └── stash-player-ui/        # relm4 components, the binary
└── PLAN.md
```

### `stash-api`
- `reqwest` (rustls) + `graphql_client` for typed queries against Stash's schema.
- Pull schema once via introspection, commit the SDL, code-gen typed structs.
- Surface today: `Client::new(base_url, api_key)`, `version()`,
  `find_scenes(filter, page, per_page)`, `find_scene(id)`, `fetch_bytes(url)`,
  `authenticated_url(url)` (appends `apikey=` for consumers that can't
  carry our request header — e.g. GTK's media stack).
- Activity tracking lands with milestone 3: `save_activity(id, resume_time,
  play_duration)` (Stash's `sceneSaveActivity` mutation increments play
  count when `playDuration` is set) and the scene query starts pulling
  `resume_time` / `play_count` so we can seek to the saved position on
  load. Performers / tags / markers queries come with milestone 5.

### `stash-player-core`
- Config: `~/.config/stash-player/config.toml` (server URL, theme).
  Use `directories` + `serde`.
- Secrets: API key in the system keyring via the `keyring` crate
  (Secret Service on Linux), never in the TOML.
- Local cache: thumbnails are decoded to fixed-size RGBA8 and written as
  flat files under `XDG_CACHE_HOME/stash-player/thumbs/`, keyed by a hash
  of the source URL with the dimensions baked into the filename so a
  resize at compile time invalidates old entries automatically. SQLite
  was in the original plan but has earned no work yet — recently-viewed
  and any other structured cache will land alongside the feature that
  needs them.
- Async runtime: `tokio` multi-thread.

### `stash-player-ui` (binary)

UX principles for this crate:
- Built on **libadwaita** widgets first, plain GTK4 only when Adw doesn't
  cover the case. Adaptive layouts (`AdwBreakpoint`) so the window works
  resized small.
- Friendly empty states, inline error banners (`AdwBanner`), and toasts
  (`AdwToast`) instead of modal error dialogs.
- First-run experience: a welcome screen that walks the user through Stash
  URL + API key entry rather than dumping them into a settings page.
- Keyboard-friendly but mouse-first; every primary action has a visible
  button, not just a shortcut.

relm4 components, top-down:

- `AppModel` — root component. Owns navigation stack and connection status.
- `LibraryPage` — main grid plus a top toolbar (search, sort dropdown,
  asc/desc toggle, organized switch, min-rating filter, "play random"
  button). Grid is currently a `gtk::FlowBox` paged in batches of 24 on
  `edge-reached`. Virtualizing it (`gtk::GridView` + `ListStore`) and the
  Performers / Studios / Tags / Markers sidebar are milestone-5 polish.
- `ScenePage` — inline `VideoPlayer` at the top, then title +
  studio/date/duration/resolution subtitle, autoplay toggle, prev/next
  navigation honouring the library's current filter, performers chips
  (Adw avatars), details, and a file-info group.
- `VideoPlayer` widget (used inline on `ScenePage`, not a separate page):
  `gtk::MediaFile` painted into a `gtk::Picture` wrapped in a
  `gtk::GraphicsOffload` for compositor-direct video. Custom OSD with
  seek/transport/volume/fullscreen and mpv-style keyboard shortcuts.
  Marker scrubber + speed control are milestone-5 polish.
- `SettingsPage` — Stash URL + API key entry, "test connection" button,
  theme.
- Async work: the shared `stash_api::Client` is held by `AppModel` and
  cloned into each component that needs it. Off-thread work goes through
  `ComponentSender::oneshot_command` (one task per request) rather than
  long-lived workers — simpler, and the relm4 worker pattern wasn't
  buying us anything yet.

## Playback details

- `gtk::MediaFile` for the stream, painted into a `gtk::Picture` wrapped
  in `gtk::GraphicsOffload` (4.14+) so frames go straight to the Wayland
  compositor instead of through GSK. Same trick `GtkVideo` uses internally.
- Stream URL comes from `scene.paths.stream`; we run it through
  `Client::authenticated_url` to bake the API key into the query string,
  since the media stack can't carry our `ApiKey` request header.
- HLS-vs-progressive selection is GStreamer's problem now; we don't pick.
  If a scene fails to play we surface the error and the user can fall
  back to the browser via the existing "Open in Stash" button. A real
  transcoded-URL fallback would mean dropping to `gstreamer-rs`, which
  we'll do if the cost shows up.
- Position persistence: throttle `sceneSaveActivity` to ~once per 10s and
  flush on pause / seek / close. Apply the saved `resume_time` after the
  stream is prepared.
- Hardware accel: VA-API is picked up by GStreamer automatically when
  `gstreamer1.0-vaapi` is installed — document as a runtime dep.

## Build, run, package

- `cargo run -p stash-player-ui` for dev.
- System deps: `gtk4`, `gstreamer1.0`, `gstreamer1.0-plugins-{base,good,bad,ugly}`,
  `gstreamer1.0-libav`, `gst-plugin-gtk4` (or `gtk4paintablesink`).
- Packaging: Flatpak first (Freedesktop runtime ships GStreamer + GTK4),
  AppImage as a fallback. Skip distro packaging until v1 stabilizes.

## Milestones

1. **Skeleton — done.** Workspace + four crates, relm4/libadwaita window,
   settings page with URL + API-key entry, "test connection" round-trip
   that hits Stash's `version` query. API key persists to the Linux
   Secret Service; URL persists to `~/.config/stash-player/config.toml`.
   Substituted `version` for "scene count" since it auths cheaper and
   needs no scene query yet.
2. **Library browse — done (modulo polish).** Scene query hand-rolled in
   `stash-api::find_scenes`; UI navigates between Library / Scene /
   Settings via `AdwNavigationView`. The library is a `gtk::FlowBox` of
   card cells (thumbnail + title + studio · duration + an "O n" pill
   when the counter is non-zero), with infinite scroll triggered on
   `edge-reached` (24 scenes per fetch) and a top toolbar carrying the
   search entry, sort dropdown, asc/desc toggle, organized switch,
   min-rating filter, hide-tracked switch (default ON — opens to
   `o_counter = 0` only), and a "play random" shortcut
   (uses Stash's seeded `random_<seed>` sort so paging stays stable).
   Stash's screenshot endpoint serves a mix of JPEG and WebP, so
   thumbnails are decoded + cropped + resized with the `image` crate to
   a fixed 240×135 RGBA8 and handed to GTK as `gdk::MemoryTexture` via
   the same authenticated reqwest client used for GraphQL. Decoded
   bitmaps are cached on disk under `XDG_CACHE_HOME/stash-player/thumbs/`
   keyed by URL hash + dimensions, with a 12-permit semaphore capping
   concurrent fetches. Scene detail page shows the inline player +
   metadata + performers chips + prev/next neighbor navigation.
   Open polish for later: virtualize the grid (FlowBox holds the full
   list in memory; fine for hundreds, not great for tens of thousands),
   filter chips for performer / studio / tag, sidebar for the
   non-Scenes entity types (Performers / Studios / Tags / Markers).
3. **Local playback — done bar activity tracking.** `gtk::MediaFile`
   painted into `gtk::Picture` inside `gtk::GraphicsOffload`, with a
   custom OSD (seek + transport + volume + fullscreen), mpv-style
   keyboard shortcuts, click-to-toggle / double-click-fullscreen, and
   auto-hiding controls. Plan originally specified raw `playbin3` +
   `gtk4paintablesink`; we ended up letting `gtk::MediaFile` wrap that
   for us (see "Decisions" above). Resume + `sceneSaveActivity` writeback
   is the remaining piece.
4. **Full library polish (≈3 days).** Performers / Tags / Studios / Markers
   pages, search, keyboard shortcuts, theme.
5. **Packaging (≈1 day).** Flatpak manifest, README, screenshots.
6. **macOS frontend — walking skeleton landed.** SwiftUI app at
   `apps/macos/` driven by the same Rust crates via UniFFI. New
   `stash-player-ffi` crate exposes a flat sync API to Swift; AppKit
   Keychain replaces the Linux Secret Service through a cfg-gated
   `stash-player-core::secrets` backend. Walking-skeleton scope:
   Settings → connect → library grid (free-text search, infinite scroll,
   24/page) → Scene detail → AVKit `VideoPlayer` with resume +
   `sceneSaveActivity` writeback on close. The Linux GTK app is
   untouched. Confirmed working against the user's real Stash server.
7. **macOS feature parity with Linux — done.** macOS app now matches the
   GTK app's feature surface across library, scene detail, and player.
   - `stash-player-ffi::list_scenes` takes an `FfiSceneFilter` record
     mirroring `stash_api::SceneFilter` (sort, direction, min rating,
     organized, hide-tracked, random seed). `increment_o` / `reset_o`
     mutations also crossed the bridge.
   - Library toolbar: sort dropdown (8 keys from `SortKey::ALL`),
     asc/desc toggle, min-rating dropdown (Any/1–5★), organized
     toggle, hide-tracked toggle (default ON), and "play random" button
     that programmatically pushes a fresh `SceneNavigation` onto the
     `NavigationStack` path.
   - Scene detail: prev/next toolbar buttons that fetch the neighbour
     via `listScenes(filter, page=target+1, perPage=1)` and swap the
     scene in place; horizontal performer chips with SF Symbol avatars;
     star-rating capsule overlay on the player surface; O-counter pill +
     increment + reset buttons in the metadata header; "Open in Stash"
     toolbar button that opens `<base>/scenes/<id>` in the system
     browser.
   - Player ergonomics: `KeyCapturingPlayerView` (NSViewRepresentable
     wrapping `AVPlayerView`) intercepts Space/k = play-pause, ←/→ =
     ∓5s, j/l = ∓10s, ↑/↓ = ±60s, m = mute, f = fullscreen, 9/0 =
     volume. `window?.toggleFullScreen(_:)` gives native window-level
     fullscreen rather than AVPlayerView's video-only mode.
   - Activity throttle: a periodic time observer at 0.25 Hz drives a
     ~10s throttled `sceneSaveActivity` flush. KVO on `rate` flushes on
     pause; `tearDownPlayer(flush:true)` flushes on prev/next swap and
     view disappear.
8. **macOS-native wins — done.** Picture-in-Picture is on by default via
   `AVPlayerView.allowsPictureInPicturePlayback`; `NowPlayingController`
   wires the `MPRemoteCommandCenter` (play/pause/toggle, ±10s skip,
   scrubber) and `MPNowPlayingInfoCenter` (title, studio, artwork,
   elapsed time) so media keys, AirPods controls, the menu-bar Now
   Playing widget, and the lock screen all drive playback. App
   `.commands` registers Cmd-1 = Library, Cmd-, = Settings. SwiftUI
   honours the system theme automatically — no picker needed.
9. **macOS productionization (≈1 day).** Path to a publishable build.
   Add `x86_64-apple-darwin` to the build script's `TARGETS` and `lipo
   -create` the slices for a universal staticlib. Switch
   `NSAllowsArbitraryLoads = true` to per-domain `NSExceptionDomains`
   keyed off `Config.stash_url` so HTTP-only deployments still work
   without blanket ATS bypass. Add a GitHub Actions workflow on
   `macos-latest` that runs `cargo test`, the xcframework build, and
   `xcodebuild`; publish a notarized `.app` (or `.dmg`) via
   `actions/upload-artifact` on tag pushes. Code-signing and
   notarization need an Apple Developer ID — gate the workflow on
   secrets being present so forks still get a clean unsigned build.

## Open questions (do not block plan; resolve before coding the relevant bit)

1. **App name & branding** — keeping `stash-player` as the binary name and
   crate name? Any preferred display name / icon direction?
2. **Marker UX** — Stash markers are rich (tags + timestamps). Do you want
   chapter-style jumping in the player, a marker list panel, or both?
3. **Multiple Stash instances** — single instance only, or should config
   support switching between several?

### Resolved

- **Stash instance for development** — defaults to
  `https://stash.example.com` (the user's Tailscale-served Stash; the
  alternate `stash.arsfeld.one` SSO front-door rejects ApiKey auth).
  Settings page is the entry point on first run; no separate wizard.
- **Activity sync** — yes, we write back. Resume position throttled to
  ~10s and flushed on pause / seek / close; play count increments via
  `sceneSaveActivity`'s `playDuration` parameter.
- **O-counter support** — shipped. Scene page exposes increment + reset
  buttons (`sceneIncrementO` / `sceneResetO`); library has a Hide-tracked
  toggle (default ON) that filters `o_counter = 0` so the user opens to
  scenes they haven't tracked yet.
