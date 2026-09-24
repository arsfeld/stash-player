# Stash Player (Flutter)

The Stash Player desktop app for Linux and macOS. Released as a Flatpak
and a notarized macOS app from `v1.0.0` on. It took over the app
identities and Sparkle update channel of two earlier, now-frozen clients
— the GTK4/libadwaita app (`crates/stash-player-ui`) and the SwiftUI/AVKit
macOS app (`apps/macos/`) — which remain in the repo, buildable, but no
longer released; see the root [README's "A note on the older
versions"](../../README.md#a-note-on-the-older-versions) section.

It targets Linux and macOS desktop — no mobile, no web. Windows is a
target only in the thin sense that CI compiles one: the `Flutter Windows`
job in `.github/workflows/flutter.yml` runs `flutter build windows
--release` on every push to `main` and every PR, and uploads the result
as a build artifact. Nothing validates that artifact — there is no Windows
dev shell, no test (unit or integration) runs on Windows, and nobody
launches the app there. Read a green Windows job as "the embedder and the
native plugins still link", not as support.

## Prerequisites

Flutter only exists inside the pinned Nix dev shell (`nix develop .#flutter`
at the repository root); there is no supported "without Nix" path for this
app, unlike the Rust clients. That shell — separate from the repository's
`default` shell, which skips the Flutter SDK but still carries the same
shared GTK3/mpv (and `mpv.pc` shim) runtime libs — provides the pinned
Flutter SDK plus the native libraries `media_kit` needs for
hardware-accelerated video (see [Troubleshooting](#troubleshooting)
below). The two shells are split so Rust-only contributors don't pay for
the multi-GB Flutter closure, and so `clang` (needed to build the Flutter
Linux embedder) never shadows the legacy Rust client's own `cc`/`ld`
inside `nix develop`'s default shell.

```sh
# from the repository root
nix develop .#flutter
cd apps/flutter
flutter pub get
```

## Run

```sh
flutter run -d linux    # Linux
flutter run -d macos    # macOS
```

On first launch (no persisted connection), the app opens the connection
screen — enter a Stash **URL** and, if your server has auth enabled, an
**API key** — then "Test connection". Once verified, both persist
(URL to platform preferences, key to the system keyring) and the app
starts straight into the library on future launches.

### Pointing at a Stash server

Three options, described in [`tools/dev-stash/README.md`](../../tools/dev-stash/README.md)
and [`tools/mock-stash/README.md`](../../tools/mock-stash/README.md) (all
driven from the repository root, not from `apps/flutter/`):

| | `tools/mock-stash/` | `docker compose up -d` | `devenv up` |
| --- | --- | --- | --- |
| Video playback | **No** — `/stream` is a documented 404 stub | Yes | Yes |
| Good for | Offline UI work, the integration smoke test | Real Stash, no Nix needed | Real Stash, fastest on Nix machines |

```sh
# Fast, offline, no video — see "Mock server limitations" below
python3 ../../tools/mock-stash/server.py

# Real Stash with real media (either works; see the root README for details)
( cd ../.. && docker compose up -d && tools/dev-stash/populate.sh )
# or
( cd ../.. && devenv up )   # in another terminal: tools/dev-stash/populate.sh
```

Then launch with the server's URL (and API key, if any) as environment
overrides — see "Runtime environment overrides" below — or just enter
them in the connection screen:

```sh
STASH_URL=http://127.0.0.1:9999 STASH_API_KEY= flutter run -d linux
```

### Mock server limitations

`tools/mock-stash/server.py` implements enough of the Stash GraphQL
schema to drive the library, search/sort/filter, scene metadata, and the
O-counter — but its `/stream` endpoint is a **documented 404 stub**, by
design (see that file's own docstring). Pointing this app at the mock
will always show the scene screen's blocking playback-failure state with
a "Retry" affordance; that is expected, not a bug. The mock also exposes
two test-only endpoints purely for automated assertions —
`GET /__test__/activity` and `POST /__test__/reset` — see
[`tools/mock-stash/README.md`](../../tools/mock-stash/README.md). Real
video, audio, seeking, and activity-writeback validation all require one
of the real-Stash options above (or a real production server), which is
exactly what [`docs/flutter-runtime-validation.md`](../../docs/flutter-runtime-validation.md)
is for.

## Runtime environment overrides

`STASH_URL` / `STASH_API_KEY` process environment variables override the
persisted connection for the lifetime of the process — read via
`Platform.environment` in `lib/app/providers.dart`'s `environmentProvider`
and applied by `overlayEnvironment` (`lib/domain/connection.dart`).
Precedence rule, exactly:

- A field is overridden whenever its environment variable is **present
  at all** — including set-but-empty.
- An explicitly empty `STASH_API_KEY=` is a valid override: it points
  the app at an unauthenticated server even if a real key is already
  stored in the keyring. This is intentional — the mock server and many
  dev backends run with no auth.
- An **absent** variable leaves the persisted value untouched.
- Neither override is ever written back to storage — they apply only to
  the running process.

```sh
STASH_URL=http://127.0.0.1:9999 STASH_API_KEY= flutter run -d linux
```

## Cache, settings, and key names

This client took over the app id and display name of the two frozen
clients it replaces, so a packaged install of one supersedes the other —
that's the point, see "Releasing" below. Everything else — preference
keys, secure-storage key, and cache directory — stays under the
`dev.arsfeld.stashplayer.flutter` namespace the app has always used, so a
locally built dev copy of this app never collides with a `cargo run`
build of the legacy GTK client on the same machine:

| What | Identifier |
| --- | --- |
| Application id (Linux `APPLICATION_ID`, macOS `PRODUCT_BUNDLE_IDENTIFIER`) | `dev.arsfeld.stash-player` |
| Display name (window title / `MaterialApp.title`) | `Stash Player` |
| Server URL preference key (`shared_preferences`) | `dev.arsfeld.stashplayer.flutter.server_url` |
| API key secure-storage key (`flutter_secure_storage`) | `dev.arsfeld.stashplayer.flutter.api_key` |
| Legacy import flag (`shared_preferences`) | `dev.arsfeld.stashplayer.flutter.legacy_import_attempted` |
| Thumbnail disk cache root | `<application-cache>/dev.arsfeld.stashplayer.flutter/thumbnails/` |

(`<application-cache>` is whatever `path_provider`'s
`getApplicationCacheDirectory()` resolves to per platform — e.g.
`~/.cache/<app>` on Linux.)

## Upgrading from the legacy clients

On first launch — only when no connection is already stored, and only
once per install (`legacyImportAttemptedPreferenceKey` above, set before
the result is used, whatever the outcome) — the app looks for a
connection saved by the legacy GTK or SwiftUI client and imports it, so a
user upgraded into this client lands in their library instead of an
empty connection screen. It reads, never writes:

| | URL + SOCKS proxy (`config.toml`) | API key |
| --- | --- | --- |
| Linux | `$XDG_CONFIG_HOME/stash-player/config.toml` (the Flatpak's per-app path), falling back to the host's `~/.config/stash-player/config.toml`, exposed read-only by the manifest | Secret Service item, attributes `application=stash-player`, `key=stash-api-key` (`linux/runner/my_application.cc`) |
| macOS | `~/Library/Application Support/one.arsfeld.stash-player/config.toml` | Keychain generic password, service `stash-player`, account `stash-api-key` (`macos/Runner/MainFlutterWindow.swift`) |

Only the Stash URL, API key, and SOCKS proxy are imported — nothing else
(volume, autoplay, etc.) carries over. The proxy's scheme is stripped
(`socks5h://host:port` → `host:port`); an HTTP proxy or one with
credentials imports as "no proxy", since this client can't honour those.
An empty API key is valid (some servers run with auth disabled).
`STASH_URL` / `STASH_API_KEY` environment overrides still win over
whatever the import produces. The legacy `config.toml` and keyring/
Keychain entry are never modified or deleted, so rolling back to an
older release keeps working. See
`lib/services/{legacy_config,legacy_secret_reader,legacy_connection_importer,platform_connection_store}.dart`
and the design doc's [§4](../../docs/superpowers/specs/2026-09-23-flutter-first-class-release-design.md#4-one-time-connection-import)
for the full flow.

## Format, analyze, test, build

Mirrors what CI (`.github/workflows/flutter.yml`) runs, in this order:

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .   # CI gate — run `dart format .` to fix
flutter analyze --fatal-infos --fatal-warnings       # CI gate
flutter test
flutter build linux --debug    # Linux
flutter build macos --debug    # macOS
```

CI runs one more build the Nix dev shell can't: `flutter build windows
--release`, on a `windows-latest` runner with an SDK pinned by hand to the
flake's Flutter version. See the caveat at the top of this file for what
that job does and doesn't prove.

### Run the integration smoke test

`integration_test/connection_library_scene_test.dart` boots the real app
(the actual `main()`, not a hand-wired test harness) against the
repository mock server and walks connection → library → search filter →
scene navigation → the mock's expected (recoverable) playback failure.
It does **not** validate real playback — see "Mock server limitations"
above and the real-hardware checklist in
[`docs/flutter-runtime-validation.md`](../../docs/flutter-runtime-validation.md).

```sh
# terminal one, from the repository root
python3 tools/mock-stash/server.py

# terminal two
cd apps/flutter
STASH_URL=http://127.0.0.1:9999 STASH_API_KEY= flutter test integration_test/connection_library_scene_test.dart -d linux
# macOS: replace -d linux with -d macos
```

**Port 9999 is often already taken.** A real Stash server (a personal
instance, `docker compose up -d`, `devenv up`, …) commonly listens on
this same port, and the mock will fail to bind with "Address already in
use" if one is already running. CI runners don't have this problem
(nothing else is listening on a fresh runner), so the committed default
above stays `9999` — but locally, run both the mock and the test against
an alternate port instead of stopping whatever else owns 9999:

```sh
MOCK_STASH_PORT=19999 python3 tools/mock-stash/server.py

cd apps/flutter
STASH_URL=http://127.0.0.1:19999 STASH_API_KEY= flutter test integration_test/connection_library_scene_test.dart -d linux
```

Expected: PASS through connection, library, filter, scene metadata, and
the recoverable playback failure (a "Retry" affordance, since the mock's
`/stream` intentionally 404s). CI runs the same shape automatically —
see the "Connection/library smoke (mock stream; no playback validation)"
step in `.github/workflows/flutter.yml`, which starts the mock, waits
for it to accept requests, runs this test, and tears the mock down
before continuing to the debug build.

## Troubleshooting

**Linux Secret Service.** `flutter_secure_storage` reads/writes the API
key through the Secret Service D-Bus API (`gnome-keyring`, KWallet's
Secret Service shim, etc.). If nothing implementing that API is running
— common in a bare container or a minimal window manager session — a
secure-storage read throws, and a *locked* keyring (no session unlocked
it yet) is a real crash path encountered while building this app. Make
sure a Secret Service provider is running and unlocked before launching;
on most desktop sessions this happens automatically at login. You can
sanity-check it independently of the app with:

```sh
secret-tool store --label=probe test-attr probe-value   # prompts if locked
secret-tool lookup test-attr probe-value
secret-tool clear test-attr probe-value
```

**`media_kit` native libraries.** Real playback needs `media_kit`'s
native decode/render libraries (`libmpv` and friends on Linux,
`media_kit_libs_video`'s bundled frameworks on macOS). The pinned Nix
dev shell (`nix develop .#flutter`) provides these on Linux; running
outside that shell (or outside the pub packages' bundled macOS
frameworks) is unsupported and will fail to open any stream, mock or
real. If `flutter run`/`flutter test -d linux` reports it can't find
`libmpv` or similar, you are almost certainly outside `nix develop
.#flutter`.

**`flutter build macos` fails inside `nix develop .#flutter`.** It dies
in `debug_unpack_macos`/`release_unpack_macos` with `Failed to extract
architectures "arm64"` and, underneath it, `lipo: can't create temporary
output file: …/FlutterMacOS.lipo (Permission denied)`. nixpkgs assembles
the Flutter SDK as a farm of symlinks into the read-only Nix store, and
`flutter_tools` copies `FlutterMacOS.framework` with `rsync -av` — no
`-L` — so the copy in `build/` is still links into the store, and the
`--chmod` rsync is given applies to the links instead of their targets.
`lipo` then has nowhere writable to put its temp file. Nothing outside
Flutter can fix it: the copy and the thinning happen inside one build
target. Everything else in the shell is fine on macOS — `flutter pub
get`, `dart format`, `flutter analyze` and `flutter test` all work — so
this is specific to producing a macOS app bundle. CI sidesteps it by
installing the same pinned SDK outside Nix (see the `Flutter macOS` job);
locally, build from a non-Nix Flutter SDK of the same version.

**`pumpAndSettle()` hangs on the scene screen — use a bounded pump loop
instead.** This bit Task 12 while writing the integration smoke test,
and will bite any future integration test that navigates into the scene
screen too: the instant that screen mounts, the real
`MediaKitPlaybackEngine` opens a `package:media_kit` `Player`, which
allocates a live native video texture immediately — independent of
whether the stream ever actually starts playing (a 404, like the mock's,
still allocates the texture before the failure is reported). A live
`Texture` widget continuously requests new frames on this platform, so
`SchedulerBinding` never reports "no frame scheduled" once one is on
screen: `WidgetTester.pumpAndSettle()` doesn't fail fast in that
situation, it runs to its full default 10-minute timeout and then
throws `pumpAndSettle timed out`. This reproduced as a clean, consistent
hang — not a flake — while developing
`integration_test/connection_library_scene_test.dart`. Once any test
navigates to the scene screen, replace `pumpAndSettle()` with a bounded
pump loop that polls for the widget you actually expect and fails
explicitly on a generous timeout instead (see that test's own
`_pumpUntilFound` helper).

## Keyboard shortcuts (player)

Same mpv-style bindings as the GTK client — see the root README's
["Keyboard shortcuts"](../../README.md#keyboard-shortcuts) section.

**Fullscreen is not implemented on either platform.** `F` and `Esc` are
wired to the same `PlayerAction`s as every other shortcut, but
`PlaybackController`'s `FullscreenRequester` always reports failure (no
window-manager integration exists yet on Linux or macOS for this client),
so both bindings are harmless no-ops and the on-screen fullscreen button
is disabled with a "not yet implemented" tooltip rather than a control
that claims a window state the OS never actually entered (final review
C4). See `docs/flutter-runtime-validation.md` rows L13/L14/M13/M14, which
are marked `NOT IMPLEMENTED` rather than `UNRUN` for the same reason.
Wiring a real platform hook (Linux: GTK `gtk_window_fullscreen`; macOS:
`NSWindow.toggleFullScreen(_:)`, as the SwiftUI app already does) is
follow-up work, not part of this vertical slice.

## Architecture

See the repository root [`CLAUDE.md`](../../CLAUDE.md) for the full
picture. In short: `lib/domain/` is pure data + rules (no I/O), `lib/services/`
implements the I/O ports (`StashApi` via `HttpStashApi`, `PlaybackEngine`
via `MediaKitPlaybackEngine`, connection/thumbnail storage), and
`lib/features/` holds the Riverpod controllers and screens for
connection, library, and the video-first scene experience. `lib/app/`
wires it all together (`AppRouter`, `AppController`, the provider graph
in `providers.dart`).

## Releasing

Push a `vX.Y.Z` tag on `main`. That's the whole trigger:

- [`flatpak.yml`](../../.github/workflows/flatpak.yml) builds the manifest
  in [`build-aux/dev.arsfeld.stash-player.yml`](../../build-aux/dev.arsfeld.stash-player.yml)
  and attaches `stash-player.flatpak` to the GitHub release.
- [`macos.yml`](../../.github/workflows/macos.yml) builds `StashPlayer.app`,
  Developer ID–signs and notarizes it, attaches
  `StashPlayer-macos-arm64.zip` to the release, and — in its `appcast`
  job — regenerates and publishes the Sparkle appcast to `gh-pages`, so
  existing installs pick up the update.

Both workflows also run on every push/PR for build verification; only a
`v*` tag publishes. `workflow_dispatch`'s `notarize` input on `macos.yml`
notarizes a non-tag build, for testing a release candidate before tagging.

Bump the pinned Flutter version (currently 3.41.6) in three places
together, in the same commit as any `flake.lock` bump that changes what
`nix develop .#flutter` resolves to: the `flutter-version` inputs in
[`flutter.yml`](../../.github/workflows/flutter.yml) and
[`macos.yml`](../../.github/workflows/macos.yml), and the Flutter SDK
archive URL + sha256 in the Flatpak manifest.

Icons: GNOME's [icon-development-kit](https://gitlab.gnome.org/Teams/Design/icon-development-kit) (CC0-1.0) on Linux and [Lucide](https://lucide.dev) (ISC) on macOS; licence texts ship in `apps/flutter/assets/icons/`.
