# Flutter client — real-hardware playback validation

This checklist is the manual, real-Stash, real-media acceptance gate for
the Flutter desktop client's playback surface (`apps/flutter/`). It
exists because none of the automated coverage in this repository — unit
tests, widget tests, or the mock-server integration smoke test
(`apps/flutter/integration_test/connection_library_scene_test.dart`) —
can validate actual video decode, audio, or hardware acceleration:
`tools/mock-stash/server.py` keeps `/stream` a documented 404 by design,
so every automated run of this client exercises the scene screen's
*failure* path, never real playback. **A headless build, a CI run, or a
mock-backed test passing is not playback validation and must never be
recorded as such in this document.**

## Status: MILESTONE ACCEPTANCE PENDING

**No row in either table below has been executed against a real Stash
instance with real media.** Every row is explicitly marked `UNRUN` —
except four (L13/L14/M13/M14), marked `NOT IMPLEMENTED` because there is
no fullscreen behavior yet to validate (final review C4) — with the
reason it could not be run, or does not yet exist to run, in this
environment. Per this checklist's
own governing brief: an unavailable host or a failed item remains
explicitly unchecked and **blocks milestone acceptance**, but does not
block committing the implementation and this document. Do not treat
anything below as a pass, and do not infer a pass from the automated
gates (`flutter test`, `flutter analyze`, `flutter build *_ --debug`,
the mock-backed integration smoke test, or CI) — none of them touch real
media.

**Why every row is unrun in this environment:**

- **Linux** — a display and the Flutter Linux toolchain are available on
  this host, and the mock-server-backed integration smoke test genuinely
  ran here (see `.superpowers/sdd/2026-08-26-flutter-client/task-12-report.md`
  for that run's output). There is no `docker compose`/`devenv`-provisioned
  Stash configured for this task (no `.env`, no `STASH_URL` pointed at a
  server this task stood up) and no representative media library of its
  own to exercise H.264/H.265 decode, hardware acceleration, or audio
  against. Standing up `docker compose` or `devenv` with a populated
  library was out of scope for this task (see the task brief's explicit
  ruling) and was not done.

  This host does happen to have a real, already-running Stash instance
  (a pre-existing `stash.service` system unit, unrelated to this repo's
  dev tooling, bound to port 9999) — but it is **explicitly out of
  bounds for this checklist and was not used for any row above**: it is
  someone's personal library, this checklist's own steps write resume
  positions and play durations back via `sceneSaveActivity`, and running
  it against that instance would mutate real personal data without that
  person's authorization. Using it is not a call this document's author
  gets to make unilaterally; it is being surfaced separately as an
  option for that person to authorize (or not) themselves. Do not point
  this checklist at it without that explicit sign-off recorded here.
- **macOS** — no macOS host was available in this environment at all, so
  none of the macOS rows could be attempted regardless of Stash/media
  availability.

Whoever performs the real validation run should replace the `UNRUN`
cells below in place — do not delete rows or renumber the checklist; a
partially-completed table with some genuine `PASS`/`FAIL` rows and some
still-`UNRUN` rows is the expected intermediate state of this document
until every row on both platforms is genuinely executed.

## How to run this checklist for real

1. Stand up a real Stash instance with representative media — either
   `docker compose up -d` + `tools/dev-stash/populate.sh`, or
   `devenv up` + the same populate script (see the root README's "Local
   development backend" section). The mock server
   (`tools/mock-stash/`) **cannot** be used for any row here — its
   `/stream` 404s unconditionally.
2. Make sure the library actually contains at least one H.264 and one
   H.265 (HEVC) file — `tools/dev-stash/populate.sh`'s curated clip set
   should cover both; confirm with the file info panel in the
   metadata drawer (video codec is shown there) if in doubt.
3. Launch the client per `apps/flutter/README.md`
   (`flutter run -d linux` / `-d macos`), pointed at that real instance.
4. Work through every row below in order, recording:
   - **Date** the row was actually executed.
   - **Commit SHA** (`git rev-parse HEAD`) the build under test was
     built from.
   - **OS / hardware** — distro + GPU on Linux, macOS version + chip on
     macOS.
   - **Media codec** — the actual codec of the file used for that row.
   - **Result** — `PASS`, `FAIL`, or leave `UNRUN` with a reason if the
     row still can't be executed.
   - **Notes** — anything observed, especially for hardware-decoder rows
     (see below) or any deviation from the expected behavior.
5. "Hardware decoder shown by the host's player diagnostics" means:
   confirm decode is actually offloaded, not just that video renders.
   - **Linux**: `intel_gpu_top` / `nvidia-smi dmon` / `radeontop`
     showing video-decode engine utilization while the scene plays, or
     `vainfo`-confirmed VA-API profile in use if `media_kit`'s backend
     surfaces it in logs.
   - **macOS**: Activity Monitor's GPU history / `powermetrics
     --samplers gpu` showing the video decode block active, or an
     Instruments "Hardware Decode" trace, while the scene plays.
   - If the host has no hardware decoder for a given codec, record
     `PASS (software decode — no hw decoder on this host)` rather than
     `FAIL`, and say so in Notes.

## Linux

| # | Item | Date | Commit SHA | OS / Hardware | Media codec | Result | Notes |
| - | --- | --- | --- | --- | --- | --- | --- |
| L1 | H.264 video renders correctly | — | — | — | H.264 | UNRUN | No real Stash instance / representative media on this host — see "Why every row is unrun" above. |
| L2 | H.265 (HEVC) video renders correctly | — | — | — | H.265 | UNRUN | Same as L1. |
| L3 | Hardware decoder shown active by host player diagnostics (where supported) | — | — | — | — | UNRUN | Same as L1; also needs `intel_gpu_top`/`nvidia-smi`/`radeontop` run alongside playback. |
| L4 | Audio plays, in sync, at the file's native level | — | — | — | — | UNRUN | Same as L1. |
| L5 | Play / pause (Space, K, and the on-screen button) | — | — | — | — | UNRUN | Same as L1. |
| L6 | Scrub / absolute seek by dragging the seek bar | — | — | — | — | UNRUN | Same as L1. |
| L7 | Relative seek: ← / → (∓5s) | — | — | — | — | UNRUN | Same as L1. |
| L8 | Relative seek: J / L (∓10s) | — | — | — | — | UNRUN | Same as L1. |
| L9 | Relative seek: ↑ / ↓ (±60s) | — | — | — | — | UNRUN | Same as L1. |
| L10 | Home / End (seek to start / end) | — | — | — | — | UNRUN | Same as L1. |
| L11 | Volume ±5% (9 / 0 keys) | — | — | — | — | UNRUN | Same as L1. |
| L12 | Mute (M) | — | — | — | — | UNRUN | Same as L1. |
| L13 | Fullscreen toggle (F) | — | — | — | — | NOT IMPLEMENTED | No platform fullscreen hook exists on Linux (final review C4). `PlaybackController`'s `FullscreenRequester` always reports failure, the on-screen control is disabled with a "not yet implemented" tooltip, and `F` is therefore a no-op. Not a runtime-validation gap — there is nothing here to validate against real hardware until a real implementation ships. |
| L14 | Escape exits fullscreen (no-op outside fullscreen) | — | — | — | — | NOT IMPLEMENTED | Same root cause as L13: fullscreen can never be entered, so Escape is always the no-op branch. Re-mark UNRUN once a real fullscreen implementation lands. |
| L15 | Mid-scene resume: reopening a partially-watched scene resumes near the last position | — | — | — | — | UNRUN | Same as L1. |
| L16 | Completed-scene restart: reopening a scene played to the end starts over from zero | — | — | — | — | UNRUN | Same as L1. |
| L17 | Periodic resume/play-duration writeback fires after ~10 active seconds | — | — | — | — | UNRUN | Same as L1; verify server-side via Stash's own scene activity, not the mock's `/__test__/activity` (mock is video-less and out of scope for this checklist). |
| L18 | Activity flush on pause | — | — | — | — | UNRUN | Same as L1. |
| L19 | Activity flush on seek | — | — | — | — | UNRUN | Same as L1. |
| L20 | Activity flush on scene replacement (prev/next navigation) | — | — | — | — | UNRUN | Same as L1. |
| L21 | Activity flush on close/dispose (leaving the scene screen) | — | — | — | — | UNRUN | Same as L1. |
| L22 | Network failure shows a warning without interrupting current playback | — | — | — | — | UNRUN | Requires interrupting connectivity to a real Stash mid-scene (e.g. block the port, stop the container) — needs the real-Stash setup from L1. |
| L23 | Playback/activity recovers once the network returns | — | — | — | — | UNRUN | Same as L22. |

## macOS

| # | Item | Date | Commit SHA | OS / Hardware | Media codec | Result | Notes |
| - | --- | --- | --- | --- | --- | --- | --- |
| M1 | H.264 video renders correctly | — | — | — | H.264 | UNRUN | No macOS host was available in this environment. |
| M2 | H.265 (HEVC) video renders correctly | — | — | — | H.265 | UNRUN | Same as M1. |
| M3 | VideoToolbox hardware decode shown active by host player diagnostics (where supported) | — | — | — | — | UNRUN | Same as M1; also needs Activity Monitor GPU history / `powermetrics --samplers gpu` / an Instruments hardware-decode trace run alongside playback. |
| M4 | Audio plays, in sync, at the file's native level | — | — | — | — | UNRUN | Same as M1. |
| M5 | Play / pause (Space, K, and the on-screen button) | — | — | — | — | UNRUN | Same as M1. |
| M6 | Scrub / absolute seek by dragging the seek bar | — | — | — | — | UNRUN | Same as M1. |
| M7 | Relative seek: ← / → (∓5s) | — | — | — | — | UNRUN | Same as M1. |
| M8 | Relative seek: J / L (∓10s) | — | — | — | — | UNRUN | Same as M1. |
| M9 | Relative seek: ↑ / ↓ (±60s) | — | — | — | — | UNRUN | Same as M1. |
| M10 | Home / End (seek to start / end) | — | — | — | — | UNRUN | Same as M1. |
| M11 | Volume ±5% (9 / 0 keys) | — | — | — | — | UNRUN | Same as M1. |
| M12 | Mute (M) | — | — | — | — | UNRUN | Same as M1. |
| M13 | Fullscreen toggle (F) | — | — | — | — | NOT IMPLEMENTED | No platform fullscreen hook exists on macOS either (final review C4) — see L13. `NSWindow.toggleFullScreen(_:)` (as the SwiftUI app already uses) is the follow-up, not part of this fix. |
| M14 | Escape exits fullscreen (no-op outside fullscreen) | — | — | — | — | NOT IMPLEMENTED | Same root cause as M13 — see L14. |
| M15 | Mid-scene resume: reopening a partially-watched scene resumes near the last position | — | — | — | — | UNRUN | Same as M1. |
| M16 | Completed-scene restart: reopening a scene played to the end starts over from zero | — | — | — | — | UNRUN | Same as M1. |
| M17 | Periodic resume/play-duration writeback fires after ~10 active seconds | — | — | — | — | UNRUN | Same as M1. |
| M18 | Activity flush on pause | — | — | — | — | UNRUN | Same as M1. |
| M19 | Activity flush on seek | — | — | — | — | UNRUN | Same as M1. |
| M20 | Activity flush on scene replacement (prev/next navigation) | — | — | — | — | UNRUN | Same as M1. |
| M21 | Activity flush on close/dispose (leaving the scene screen) | — | — | — | — | UNRUN | Same as M1. |
| M22 | Network failure shows a warning without interrupting current playback | — | — | — | — | UNRUN | Requires interrupting connectivity to a real Stash mid-scene — needs the real-Stash setup from M1, plus a macOS host. |
| M23 | Playback/activity recovers once the network returns | — | — | — | — | UNRUN | Same as M22. |

## Sign-off

Milestone acceptance requires every row above to be `PASS` (or the
documented software-decode exception for a hardware-decoder row) on
**both** platforms. As of this document's introduction (commit
`1435d5a` plus this task's changes), that has not happened on either
platform — acceptance is **pending** real-hardware validation.

| Platform | Signed off by | Date | All rows PASS? |
| --- | --- | --- | --- |
| Linux | — | — | No — not yet run |
| macOS | — | — | No — not yet run |
