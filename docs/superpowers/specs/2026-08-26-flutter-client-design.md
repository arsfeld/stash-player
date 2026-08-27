# Flutter Desktop Client Design

Date: 2026-08-26
Status: Approved for implementation planning

## Context

Stash Player currently has two mature desktop frontends: a GTK4/Relm4 app on
Linux and a SwiftUI/AVKit app on macOS. They share Rust API and core crates, with
the macOS app calling Rust through UniFFI.

This project adds a parallel Flutter client to test whether one polished
desktop codebase can serve Linux and macOS. It is an experiment, not an
immediate replacement. The existing frontends remain the released clients and
provide the behavioral reference while the Flutter client develops.

## Goals

The first milestone will:

- build and run on Linux and macOS from the beginning;
- use a single desktop-first visual design with small platform adaptations;
- keep configuration, credentials, and cache isolated from the existing apps;
- connect to a Stash server and validate credentials;
- provide the existing scene search, sorting, filtering, random-play, and
  pagination behavior;
- play real Stash media with hardware acceleration;
- support resume, seeking, volume, fullscreen, and the existing keyboard
  shortcuts;
- write resume position and play duration back to Stash; and
- run formatting, analysis, tests, and debug builds in CI on both platforms.

## Non-goals

The first milestone will not:

- replace, remove, or change the GTK or SwiftUI frontend;
- reuse the Rust API or core crates through FFI;
- add performers, studios, tags, or markers as top-level library views;
- implement O-counter controls, ratings, Picture in Picture, media keys, Now
  Playing integration, or platform-native application menus;
- add Flatpak packaging, macOS signing, notarization, or release publishing; or
- decide whether Flutter becomes the primary client.

These are parity and migration decisions for later milestones after the
vertical slice has been evaluated.

## Repository and application identity

Development occurs on the `flutter` branch. The Flutter project lives at
`apps/flutter/`; the repository remains a Rust Cargo workspace at its root.
Flutter files do not become Cargo workspace members.

The experimental application uses a distinct platform application identifier,
`dev.arsfeld.stashplayer.flutter`, and the display name `Stash Player
Flutter`. Its preferences, secure-storage keys, cache directory, and platform
metadata must not overlap with either released frontend.

## Architecture

The Flutter project is one application package organized by responsibility:

```text
apps/flutter/
  lib/
    app/                 startup, routing, theme, dependency wiring
    domain/              immutable UI-independent models
    services/            Stash API, settings, secrets, thumbnails
    features/
      connection/        connection screen and controller
      library/           filters, pagination, grid, navigation
      player/            scene screen, playback, activity sync
    shared/              reusable desktop controls and formatting
  test/
    fixtures/            representative Stash GraphQL responses
    services/            protocol and decoding tests
    features/            controller and widget tests
  integration_test/      end-to-end smoke tests
```

Riverpod provides dependency injection and asynchronous state management.
Widgets render immutable state and forward user intents to controllers. They do
not call GraphQL, secure storage, the filesystem, or the playback package
directly.

The app begins as one package because this is an experiment with a small API
surface. Service and controller interfaces preserve extraction boundaries so a
future `stash_api` or player package can be split out without redesigning the
features.

## Components and interfaces

### Application shell

The application shell initializes Flutter and `media_kit`, loads theme and
connection settings, installs Riverpod providers, and selects either the
connection flow or the library. It owns routing and global non-modal notices.

Routing has three destinations in the first milestone:

1. Connection
2. Library
3. Scene player

Settings are available from the library shell and reuse the connection form.
A successful settings change replaces the API client and clears active library
and scene state.

### Stash API

`StashApi` is a small Dart service over `package:http`. It uses hand-written
GraphQL documents and explicit model decoding. It exposes only the milestone's
operations:

- server version for connection validation;
- paginated scene search;
- one scene by ID; and
- `sceneSaveActivity`.

The client sends `ApiKey` on GraphQL and authenticated thumbnail requests. It
constructs media URLs by adding the `apikey` query parameter only when one is
configured and not already present. API keys and authenticated URLs are
redacted from logs and error reports.

Responses are decoded at the service boundary. Missing optional Stash fields
use documented defaults, while missing required IDs, invalid response shapes,
GraphQL errors, and non-success HTTP statuses return typed failures. Widgets
never consume dynamic maps.

No normalized GraphQL cache, generated GraphQL client, or local database is
introduced. The small operation surface does not justify their setup or stale
cache semantics in the first milestone.

### Configuration and credentials

The server URL is stored in the Flutter application's isolated preferences.
The API key is stored through `flutter_secure_storage`, using macOS Keychain and
Linux Secret Service. An empty key is valid for Stash servers without API
authentication.

For development, `STASH_URL` and `STASH_API_KEY` override stored values for the
current process. Environment values are never persisted automatically.

### Library

`LibraryController` owns one immutable state containing:

- search text;
- sort key and direction;
- minimum rating;
- organized filter;
- hide-tracked filter, enabled by default;
- random seed when random sorting is active;
- loaded scenes, current page, total count, and loading state; and
- a monotonically increasing request generation.

The page size is 48 scenes. Filter changes reset paging and increment the
generation. Results from older generations are discarded, and accepted pages
are deduplicated by scene ID. Paging continues after layout until the viewport
is filled or the server reports no more results, preventing large windows from
stalling after one non-scrollable page.

Random play generates a fresh stable seed, requests the first scene using
Stash's seeded random sort, and opens it in the player. Previous and next
navigation are not part of this milestone because they are not required for
the selected connection-to-playback vertical slice.

Thumbnails are fetched with the authenticated HTTP client. At most 12 fetches
run concurrently. Decoded thumbnails are cached in the experimental app's
cache directory using source URL and requested dimensions as the cache key.
Failures produce a stable placeholder and do not fail the library request.

### Playback

Playback uses `media_kit` behind an application-owned `PlaybackEngine`
interface. The production adapter wraps the package's player and video
controller. Tests use a fake engine with deterministic event streams and a
controllable clock.

`PlaybackController` owns:

- media loading and disposal;
- playing, buffering, duration, and position state;
- resume seeking;
- play/pause, absolute and relative seeking, volume, mute, and fullscreen;
- keyboard action mapping;
- progress accumulation and activity checkpoints; and
- playback error reporting.

The scene's stream URL always passes through the authenticated-URL helper.
Resume positions at or below zero start at the beginning. A saved position
within the final ten seconds or at or beyond 97 percent of known duration is
also treated as complete and starts at the beginning.

Only wall-clock time spent in the playing state contributes to
`playDuration`. Activity checkpoints are attempted after approximately ten
seconds of active playback and are flushed on pause, seek, scene replacement,
and controller disposal. Each checkpoint sends the current resume position and
the play-duration delta accumulated since the last successful checkpoint.
Failed checkpoints retry after 1, 2, and 4 seconds. If all three retries fail,
the unsaved delta remains queued for the next periodic or lifecycle flush and a
non-modal warning is shown. Sync failures never interrupt playback.

The first milestone supports these shortcuts on both platforms:

| Key | Action |
| --- | --- |
| Space or `k` | Play or pause |
| Left or Right | Seek backward or forward 5 seconds |
| `j` or `l` | Seek backward or forward 10 seconds |
| Up or Down | Seek backward or forward 60 seconds |
| Home or End | Seek to start or end |
| `9` or `0` | Decrease or increase volume 5 percent |
| `m` | Toggle mute |
| `f` | Toggle fullscreen |
| Escape | Exit fullscreen |

## Interface design

The client uses one responsive, desktop-first Material 3 design on both
platforms. It follows system light or dark appearance by default. Small
platform adaptations are limited to expected window and keyboard behavior;
the feature layout remains shared.

The first-launch connection screen contains the Stash URL, optional API key,
connection test, and actionable validation errors.

The library uses an adaptive scene grid and a compact toolbar containing
search, sort, direction, minimum rating, organized, hide tracked, and random
play. Controls remain keyboard reachable and retain descriptive tooltips.
Narrow windows wrap or collapse secondary filters without hiding search or
random play.

The scene screen is video first. Video occupies the available content area,
and scene metadata opens in an overlay drawer so it never resizes the player.
Transport controls are visible for mouse users and auto-hide while playing.
Playback failure leaves metadata accessible and presents Retry and Open in
Stash actions.

## Error handling

Errors appear at the smallest recoverable scope:

- connection and authentication errors remain on the connection screen;
- library errors preserve accepted scenes and show inline retry;
- thumbnail errors show placeholders;
- playback errors preserve scene context and offer Retry and Open in Stash;
- activity-sync errors retain the unsaved delta, retry after 1, 2, and 4
  seconds, and show a non-modal warning after the third failure; and
- unexpected application failures are logged without credentials or
  authenticated URLs.

Controllers model initial, loading, empty, ready, and failed states explicitly.
Cancellation or request-generation checks prevent late asynchronous results
from overwriting newer user intent.

## Testing

### Service tests

Fixture-driven tests verify GraphQL documents and variables, `ApiKey` header
behavior, unauthenticated servers, authenticated URL construction, response
decoding, optional fields, HTTP failures, GraphQL failures, filters,
pagination, random seeds, and activity mutations.

### Controller tests

Fakes for API, preferences, secure storage, clock, and playback verify:

- connection and credential persistence;
- filter resets, paging, deduplication, and stale-response rejection;
- random play;
- resume rules and seek behavior;
- play-duration accounting;
- checkpoint throttling and all flush triggers;
- retention and the 1, 2, and 4 second retry schedule for failed activity
  updates; and
- teardown of player and asynchronous work.

### Widget tests

Widget tests cover connection validation, library states and controls,
responsive layouts, scene and player states, keyboard actions, theme behavior,
and user-visible failures. Golden tests are excluded initially because
cross-platform font and rasterization differences would add maintenance
without proving the vertical slice.

### Integration and manual verification

Integration smoke tests exercise connection, library loading, filtering, and
opening a scene against the repository's development Stash setup. The mock
Stash server is suitable for API and UI flows but cannot validate playback.

Before the milestone is accepted, manual verification on Linux and macOS must
use representative H.264 and H.265 media from a real development Stash server.
It must confirm rendering, hardware acceleration where the host supports it,
audio, seeks, fullscreen, shortcuts, resume, and activity writeback. Headless
CI builds are not evidence of runtime playback behavior.

## Tooling and CI

The Nix flake pins Flutter and the Linux native dependencies used by
`media_kit` and secure storage. The development shell supports Flutter format,
analysis, tests, Linux builds, and the existing Rust commands. macOS uses the
same pinned Flutter SDK while obtaining Apple's build tools from Xcode on the
host.

A dedicated Flutter workflow runs on Linux and macOS and performs:

1. dependency resolution;
2. formatting verification;
3. static analysis with warnings treated as failures;
4. unit and widget tests; and
5. a debug desktop build for the runner's platform.

The existing Rust, Flatpak, and macOS-native workflows remain unchanged.

## Delivery sequence

Implementation planning will divide the milestone into these increments:

1. Flutter project, pinned tooling, application identity, and CI foundation.
2. Configuration, secure credentials, Stash API, and connection screen.
3. Library models, filters, pagination, thumbnails, and responsive interface.
4. Playback engine, scene screen, controls, shortcuts, resume, and activity
   synchronization.
5. Integration smoke coverage, developer documentation, and real Linux/macOS
   runtime validation.

Each increment must keep both existing frontends buildable and keep the Flutter
test suite green.

## Acceptance criteria

The first milestone is complete when all of the following are true:

- a fresh checkout can enter the documented development environment and build
  the Flutter app on Linux and macOS without a separate code-generation step;
- the Flutter app uses its own application identity, settings, credentials, and
  cache;
- users can configure an authenticated or unauthenticated Stash server and
  receive actionable validation failures;
- the library supports search; Date, Title, Rating, Play count, Duration, Date
  added, Last updated, and Random sorting; direction; minimum rating;
  organized; hide tracked; a stable random seed; and continuous pagination;
- representative scenes play with audio and hardware acceleration where the
  host supports it on Linux and macOS;
- playback controls, fullscreen, and all listed keyboard shortcuts work;
- saved positions resume unless they represent a completed scene;
- resume time and actual playing-duration deltas reach Stash on the periodic
  checkpoint and every specified flush boundary;
- automated Flutter checks and debug builds pass on both CI platforms; and
- the existing Rust, GTK, SwiftUI, Flatpak, and native macOS checks are not
  regressed.

After these criteria pass, the experiment will be evaluated before any parity,
packaging, or replacement work begins.
