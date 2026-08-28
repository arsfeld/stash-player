# Stash Player (Flutter) — experimental

**This is an experimental desktop client.** It is not a replacement for
either released `stash-player` frontend — the GTK4/libadwaita client
(`crates/stash-player-ui`) or the SwiftUI/AVKit macOS app
(`apps/macos/`). Those two remain the supported, released clients; this
Flutter app is a from-scratch vertical slice (connection → library →
scene playback) built to evaluate Flutter as a third desktop toolchain,
kept fully isolated from the Rust/Swift codebases under `apps/flutter/`.

It targets Linux and macOS desktop only — no mobile, no web.

## Prerequisites

Flutter only exists inside the pinned Nix dev shell (`nix develop` at
the repository root); there is no supported "without Nix" path for this
app, unlike the Rust clients. The shell provides the pinned Flutter SDK
plus the native libraries `media_kit` needs for hardware-accelerated
video (see [Troubleshooting](#troubleshooting) below).

```sh
# from the repository root
nix develop
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

Three options, described in the root README's ["Local development
backend"](../../README.md#local-development-backend) section (all
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

Isolated from both released clients so all three can coexist on one
machine without colliding:

| What | Identifier |
| --- | --- |
| Application id (Linux `APPLICATION_ID`, macOS `PRODUCT_BUNDLE_IDENTIFIER`) | `dev.arsfeld.stashplayer.flutter` |
| Display name (window title / `MaterialApp.title`) | `Stash Player Flutter` |
| Server URL preference key (`shared_preferences`) | `dev.arsfeld.stashplayer.flutter.server_url` |
| API key secure-storage key (`flutter_secure_storage`) | `dev.arsfeld.stashplayer.flutter.api_key` |
| Thumbnail disk cache root | `<application-cache>/dev.arsfeld.stashplayer.flutter/thumbnails/` |

(`<application-cache>` is whatever `path_provider`'s
`getApplicationCacheDirectory()` resolves to per platform — e.g.
`~/.cache/<app>` on Linux.)

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
dev shell (`nix develop`) provides these on Linux; running outside that
shell (or outside the pub packages' bundled macOS frameworks) is
unsupported and will fail to open any stream, mock or real. If
`flutter run`/`flutter test -d linux` reports it can't find `libmpv` or
similar, you are almost certainly outside `nix develop`.

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
["Keyboard shortcuts (player)"](../../README.md#keyboard-shortcuts-player)
section.

## Architecture

See the repository root [`CLAUDE.md`](../../CLAUDE.md) for the full
picture. In short: `lib/domain/` is pure data + rules (no I/O), `lib/services/`
implements the I/O ports (`StashApi` via `HttpStashApi`, `PlaybackEngine`
via `MediaKitPlaybackEngine`, connection/thumbnail storage), and
`lib/features/` holds the Riverpod controllers and screens for
connection, library, and the video-first scene experience. `lib/app/`
wires it all together (`AppRouter`, `AppController`, the provider graph
in `providers.dart`).
