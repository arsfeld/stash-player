# Linux Player Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four defects in the Linux GTK frontend — stalled library pagination, duplicated metadata rows, seeks that re-land in the same place, and a video area that shrinks on every scene change — by restructuring the scene page around the video and replacing time-based seek position tracking with a value-based tracker.

**Architecture:** Playback position tracking moves out of the UI crate into a pure, unit-tested `SeekTracker` in `stash-player-core`. The scene page drops its `ScrolledWindow` so the player is sized by the window rather than by content, with metadata relegated to an always-overlaying `adw::OverlaySplitView` drawer and hot actions moved into the player OSD. Library pagination gains a viewport-fill check that runs after every page lands, so loading no longer depends on a scroll event that may never fire.

**Tech Stack:** Rust 2024, relm4 0.11, GTK4 0.11 (`v4_14`), libadwaita 0.9.1 (`v1_5`), GStreamer `playbin3` + `gtk4paintablesink`.

**Spec:** `docs/superpowers/specs/2026-08-26-linux-player-fixes-design.md`

**Branch:** `linux-player-fixes` (already checked out)

## Global Constraints

- Workspace lints are `-D warnings` in CI. **No `#[allow(...)]` exceptions** — when a lint fires, fix the structure.
- Ceilings from `clippy.toml`: `too_many_lines` 100/fn, `too_many_arguments` 7, `cognitive_complexity` 25, `excessive_nesting` 5, `type_complexity` 250, `fn_params_excessive_bools` / `struct_excessive_bools` 3, `large_enum_variant` 200 B.
- `unsafe_code = forbid`. Never use `glib::ObjectExt::set_data`; keep per-widget state on the model side keyed by index.
- `unreachable_pub = warn`. In `stash-player-ui` (a binary crate) prefer `pub(crate)`. In `stash-player-core` (a library) public API is `pub`.
- **libadwaita first.** Reach for `adw::*` widgets before raw GTK4.
- **Network code stays in `stash-api`.** No task here adds a query; none is needed.
- `stash-player-ui` has no automated tests by design. Automated tests in this plan live in `stash-player-core` only.
- The gate CI runs, and every task's final check:
  ```sh
  cargo clippy --workspace --all-targets -- -D warnings
  cargo test -p stash-api -p stash-player-core
  ```
- macOS (`apps/macos/`, `stash-player-ffi`) is **out of scope**. Do not modify it.

---

### Task 1: `SeekTracker` in `stash-player-core`

Pure position tracking that survives asynchronous seeks. No GStreamer types, no GTK — just `i64` microseconds and `Instant`. Lives in core because CI runs tests there and the UI crate has none.

**Files:**
- Create: `crates/stash-player-core/src/playback.rs`
- Modify: `crates/stash-player-core/src/lib.rs`

**Interfaces:**
- Consumes: nothing.
- Produces: `stash_player_core::playback::SeekTracker` with
  `new() -> Self`,
  `position_us(&self) -> i64`,
  `duration_us(&self) -> i64`,
  `has_pending_seek(&self) -> bool`,
  `set_duration_us(&mut self, duration_us: i64)`,
  `seek_relative(&mut self, delta_us: i64, now: Instant) -> i64`,
  `seek_absolute(&mut self, target_us: i64, now: Instant) -> i64`,
  `seek_fraction(&mut self, fraction: f64, now: Instant) -> i64`,
  `on_poll(&mut self, polled_us: i64, now: Instant)`,
  `on_async_done(&mut self, landed_us: i64)`,
  `on_stream_reset(&mut self)`.
  Also `pub const SEEK_TOLERANCE_US: i64` and `pub const SEEK_PENDING_TIMEOUT: Duration`.
  The three `seek_*` methods return the clamped target to hand to GStreamer.

**Background for the implementer.** Today the player decides whether to trust a polled playback position using two 400 ms wall-clock windows. A seek with the `ACCURATE` flag on 4K/H.265 over HTTP routinely takes longer than that, so the window expires while the seek is still in flight; the next 4 Hz poll reports the *pre-seek* position, the model snaps backward, and the following "+10s" computes its target from that stale value — landing in the same place forever. The replacement rule is value-based: a pending seek is confirmed only by a reported position *consistent with the target we asked for*, in either direction.

- [ ] **Step 1: Write the failing tests**

Create `crates/stash-player-core/src/playback.rs` containing **only** the test module for now:

```rust
//! Playback position tracking that survives asynchronous seeks.

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// One minute in microseconds — keeps the test arithmetic readable.
    const MIN: i64 = 60_000_000;
    const SEC: i64 = 1_000_000;

    /// A tracker on a 45-minute stream, playhead at `position_us`, with
    /// no seek outstanding.
    fn at(position_us: i64, now: Instant) -> SeekTracker {
        let mut t = SeekTracker::new();
        t.set_duration_us(45 * MIN);
        t.on_poll(position_us, now);
        t
    }

    #[test]
    fn relative_seeks_compose_while_a_seek_is_pending() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);

        assert_eq!(t.seek_relative(10 * SEC, now), 12 * MIN + 10 * SEC);
        assert_eq!(t.seek_relative(10 * SEC, now), 12 * MIN + 20 * SEC);
        assert_eq!(t.seek_relative(10 * SEC, now), 12 * MIN + 30 * SEC);
        assert_eq!(t.position_us(), 12 * MIN + 30 * SEC);
    }

    #[test]
    fn stale_poll_during_pending_seek_is_ignored() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        t.seek_relative(10 * SEC, now);

        // GStreamer still reports the pre-seek position.
        t.on_poll(12 * MIN, now);

        assert_eq!(t.position_us(), 12 * MIN + 10 * SEC);
        assert!(t.has_pending_seek());
    }

    #[test]
    fn poll_consistent_with_target_confirms_the_seek() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        let target = t.seek_relative(10 * SEC, now);

        t.on_poll(target, now);

        assert_eq!(t.position_us(), target);
        assert!(!t.has_pending_seek());
    }

    #[test]
    fn poll_slightly_short_of_target_is_within_tolerance() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        let target = t.seek_relative(10 * SEC, now);

        t.on_poll(target - SEEK_TOLERANCE_US / 2, now);

        assert!(!t.has_pending_seek());
    }

    #[test]
    fn backward_seek_ignores_the_stale_later_position() {
        let now = Instant::now();
        let mut t = at(30 * MIN, now);
        let target = t.seek_relative(-10 * SEC, now);
        assert_eq!(target, 30 * MIN - 10 * SEC);

        // Playback hasn't flushed yet; the poll still reads 30:00, which
        // is *ahead* of the target. Accepting it would undo the seek.
        t.on_poll(30 * MIN, now);

        assert_eq!(t.position_us(), target);
        assert!(t.has_pending_seek());
    }

    #[test]
    fn async_done_consistent_with_target_confirms_and_resyncs() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        let target = t.seek_relative(10 * SEC, now);

        // Landed a hair early — SNAP_BEFORE keyframe.
        t.on_async_done(target - 100_000);

        assert_eq!(t.position_us(), target - 100_000);
        assert!(!t.has_pending_seek());
    }

    #[test]
    fn async_done_from_a_superseded_seek_is_dropped() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        let first = t.seek_relative(10 * SEC, now);
        let second = t.seek_relative(10 * SEC, now);

        // The first seek completes after the second was issued.
        t.on_async_done(first);

        assert_eq!(t.position_us(), second);
        assert!(t.has_pending_seek());
    }

    #[test]
    fn async_done_with_an_unknown_position_is_dropped() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        let target = t.seek_relative(10 * SEC, now);

        // query_position failed; the caller reports -1.
        t.on_async_done(-1);

        assert_eq!(t.position_us(), target);
        assert!(t.has_pending_seek());
    }

    #[test]
    fn pending_seek_older_than_the_timeout_force_adopts_the_poll() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        t.seek_relative(10 * SEC, now);

        let later = now + SEEK_PENDING_TIMEOUT + Duration::from_millis(1);
        t.on_poll(12 * MIN, later);

        assert_eq!(t.position_us(), 12 * MIN);
        assert!(!t.has_pending_seek());
    }

    #[test]
    fn targets_clamp_to_the_stream_bounds() {
        let now = Instant::now();
        // Bare `SEC`, not `1 * SEC` — clippy::identity_op is on by
        // default and `--all-targets` lints tests too.
        let mut t = at(SEC, now);
        assert_eq!(t.seek_relative(-10 * SEC, now), 0);

        let mut t = at(44 * MIN, now);
        assert_eq!(t.seek_relative(10 * MIN, now), 45 * MIN);
    }

    #[test]
    fn unknown_duration_clamps_only_at_zero() {
        let now = Instant::now();
        let mut t = SeekTracker::new();
        // No duration reported yet.
        assert_eq!(t.seek_absolute(90 * MIN, now), 90 * MIN);
        assert_eq!(t.seek_absolute(-5 * SEC, now), 0);
    }

    #[test]
    fn seek_fraction_maps_onto_the_duration() {
        let now = Instant::now();
        let mut t = at(0, now);
        assert_eq!(t.seek_fraction(0.5, now), 22 * MIN + 30 * SEC);
        assert_eq!(t.seek_fraction(1.5, now), 45 * MIN);
        assert_eq!(t.seek_fraction(-1.0, now), 0);
    }

    #[test]
    fn set_duration_ignores_transient_zero_queries() {
        let now = Instant::now();
        let mut t = at(0, now);
        t.set_duration_us(0);
        assert_eq!(t.duration_us(), 45 * MIN);
    }

    #[test]
    fn stream_reset_clears_everything() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        t.seek_relative(10 * SEC, now);

        t.on_stream_reset();

        assert_eq!(t.position_us(), 0);
        assert_eq!(t.duration_us(), 0);
        assert!(!t.has_pending_seek());
    }

    #[test]
    fn poll_with_no_pending_seek_is_always_accepted() {
        let now = Instant::now();
        let mut t = at(12 * MIN, now);
        t.on_poll(12 * MIN + 250_000, now);
        assert_eq!(t.position_us(), 12 * MIN + 250_000);
    }
}
```

Register the module in `crates/stash-player-core/src/lib.rs`:

```rust
pub mod cache;
pub mod config;
pub mod playback;
pub mod secrets;

pub use config::Config;
```

- [ ] **Step 2: Run the tests to verify they fail**

```sh
cargo test -p stash-player-core playback
```

Expected: FAIL to compile — `cannot find type SeekTracker in this scope`, plus unresolved `SEEK_TOLERANCE_US` and `SEEK_PENDING_TIMEOUT`.

- [ ] **Step 3: Write the implementation**

Insert above the `#[cfg(test)] mod tests` block in `crates/stash-player-core/src/playback.rs`:

```rust
//! Playback position tracking that survives asynchronous seeks.
//!
//! A flushing seek takes time to land, and while it's in flight the
//! pipeline keeps reporting the *old* position. Trusting those reports
//! makes a relative seek compute its next target from a stale base, so
//! repeated "+10s" presses land in the same place over and over.
//!
//! [`SeekTracker`] fixes that by treating a seek as pending until it sees
//! a reported position *consistent with the target it asked for*. The
//! rule is value-based rather than time-based, so it doesn't care how
//! long the pipeline takes to honour the seek.

use std::time::{Duration, Instant};

/// How far a reported position may differ from the requested target and
/// still count as "the seek landed", in microseconds.
///
/// Positions are polled at 4 Hz, so the first report after a landing can
/// legitimately be up to one tick past the target. 750 ms leaves three
/// polls' worth of margin before playback carries the position out of
/// the window.
pub const SEEK_TOLERANCE_US: i64 = 750_000;

/// A pending seek this old is presumed missed, and the next reported
/// position is adopted regardless. Without this a seek that never
/// reports completion would freeze the displayed playhead permanently.
pub const SEEK_PENDING_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy)]
struct PendingSeek {
    target_us: i64,
    issued_at: Instant,
}

/// Tracks where the playhead is, accounting for seeks that haven't
/// landed yet.
///
/// While a seek is pending, [`SeekTracker::position_us`] reports the
/// requested target rather than what the pipeline currently says. That
/// is what makes consecutive relative seeks compose: each one anchors on
/// the previous target instead of on a stale reading.
#[derive(Debug, Default)]
pub struct SeekTracker {
    position_us: i64,
    duration_us: i64,
    pending: Option<PendingSeek>,
}

impl SeekTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Where to draw the playhead: the pending seek's target if one is
    /// outstanding, otherwise the last accepted report.
    pub fn position_us(&self) -> i64 {
        self.position_us
    }

    pub fn duration_us(&self) -> i64 {
        self.duration_us
    }

    pub fn has_pending_seek(&self) -> bool {
        self.pending.is_some()
    }

    /// Record the stream duration. Zero and negative values are ignored:
    /// duration queries transiently return 0 while a flushing seek is in
    /// flight, and we don't want that to wipe a length we already know.
    pub fn set_duration_us(&mut self, duration_us: i64) {
        if duration_us > 0 {
            self.duration_us = duration_us;
        }
    }

    /// Seek by `delta_us` from the current position. Returns the clamped
    /// absolute target to hand to the pipeline.
    pub fn seek_relative(&mut self, delta_us: i64, now: Instant) -> i64 {
        let target = self.position_us.saturating_add(delta_us);
        self.seek_absolute(target, now)
    }

    /// Seek to an absolute position. Returns the clamped target.
    pub fn seek_absolute(&mut self, target_us: i64, now: Instant) -> i64 {
        let target = if self.duration_us > 0 {
            target_us.clamp(0, self.duration_us)
        } else {
            // Duration not known yet — only the lower bound is meaningful.
            target_us.max(0)
        };
        self.position_us = target;
        self.pending = Some(PendingSeek {
            target_us: target,
            issued_at: now,
        });
        target
    }

    /// Seek to a fraction of the duration, for slider-driven jumps.
    pub fn seek_fraction(&mut self, fraction: f64, now: Instant) -> i64 {
        let target = (self.duration_us.max(0) as f64 * fraction.clamp(0.0, 1.0)) as i64;
        self.seek_absolute(target, now)
    }

    /// Feed a polled position from the pipeline.
    ///
    /// Accepted outright when nothing is pending. With a seek pending it
    /// is accepted only if it is consistent with that seek's target —
    /// anything else is a pre-seek reading or a superseded seek's
    /// leftovers, and gets dropped.
    pub fn on_poll(&mut self, polled_us: i64, now: Instant) {
        let polled = polled_us.max(0);
        let Some(pending) = self.pending else {
            self.position_us = polled;
            return;
        };
        if is_consistent(polled, pending.target_us)
            || now.duration_since(pending.issued_at) >= SEEK_PENDING_TIMEOUT
        {
            self.pending = None;
            self.position_us = polled;
        }
    }

    /// Feed the position observed when the pipeline reported a seek
    /// completed. `landed_us` may be negative if the position query
    /// failed, in which case it is ignored.
    ///
    /// The pipeline doesn't say *which* seek finished, so the same
    /// consistency test decides: a landing near the current target
    /// confirms it, anything else belongs to a seek we've since
    /// superseded and we keep waiting.
    pub fn on_async_done(&mut self, landed_us: i64) {
        let Some(pending) = self.pending else {
            return;
        };
        if landed_us >= 0 && is_consistent(landed_us, pending.target_us) {
            self.pending = None;
            self.position_us = landed_us;
        }
    }

    /// Forget everything — a new stream is loading.
    pub fn on_stream_reset(&mut self) {
        self.position_us = 0;
        self.duration_us = 0;
        self.pending = None;
    }
}

/// True when `reported` is close enough to `target`, in either
/// direction, to mean the seek was honoured. The window is symmetric:
/// a report *ahead* of a backward seek's target is just as stale as one
/// behind a forward seek's.
fn is_consistent(reported: i64, target: i64) -> bool {
    (reported - target).abs() <= SEEK_TOLERANCE_US
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
cargo test -p stash-player-core playback
```

Expected: PASS, 14 tests.

- [ ] **Step 5: Run the full gate**

```sh
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p stash-api -p stash-player-core
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add crates/stash-player-core/src/playback.rs crates/stash-player-core/src/lib.rs
git commit -m "feat(core): add SeekTracker for async-seek position tracking

Value-based rather than time-based: a pending seek is confirmed only by
a reported position consistent with the target, so relative seeks
compose correctly no matter how long the pipeline takes to land."
```

---

### Task 2: Extract `PlaybackPipeline` into its own module

Pure refactor, no behaviour change. `widgets/video_player.rs` is 1673 lines and the next three tasks add to it. Splitting the GStreamer half out first keeps the remaining edits reliable.

**Files:**
- Create: `crates/stash-player-ui/src/widgets/video_player/mod.rs` (from the existing `video_player.rs`)
- Create: `crates/stash-player-ui/src/widgets/video_player/pipeline.rs`
- Delete: `crates/stash-player-ui/src/widgets/video_player.rs`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `crate::widgets::video_player::pipeline::PlaybackPipeline` with the same method set it has today — `new(url: &str, autoplay: bool, sender: &ComponentSender<VideoPlayer>) -> Option<Self>`, `paintable(&self) -> &gtk::gdk::Paintable`, `play(&self)`, `pause(&self)`, `is_playing(&self) -> bool`, `is_prepared(&self) -> bool`, `is_seeking(&self) -> bool`, `error_message(&self) -> Option<String>`, `duration_us(&self) -> i64`, `position_us(&self) -> i64`, `set_volume(&self, v: f64)`, `volume(&self) -> f64`, `set_muted(&self, m: bool)`, `is_muted(&self) -> bool`, `seek(&self, target_us: i64)`.

- [ ] **Step 1: Move the file into a directory module**

```sh
mkdir -p crates/stash-player-ui/src/widgets/video_player
git mv crates/stash-player-ui/src/widgets/video_player.rs \
       crates/stash-player-ui/src/widgets/video_player/mod.rs
```

- [ ] **Step 2: Create `pipeline.rs`**

Move these items **verbatim** out of `mod.rs` into a new `crates/stash-player-ui/src/widgets/video_player/pipeline.rs`:

- `struct PlaybackPipeline` and its entire `impl` block
- `impl Drop for PlaybackPipeline`
- `fn make_element`
- `struct BusFlags`
- `fn install_bus_watch`
- `fn handle_bus_message`
- `fn apply_state_change`

Head the new file with:

```rust
//! GStreamer `playbin3` pipeline backing the video player.
//!
//! Behaves like `gtk::MediaFile` did: build with a URL, drive state with
//! `play`/`pause`, query timing in microseconds. Bus messages drive the
//! shared event flags and post a `Tick` to the widget so it refreshes.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gst::prelude::*;
use gtk::glib;
use gtk::prelude::*;
use relm4::gtk;
use relm4::prelude::*;

use super::{VideoPlayer, VideoPlayerMsg};
```

Mark the items the component needs as `pub(super)`: `PlaybackPipeline`, every method in its `impl`, and nothing else. `BusFlags`, `install_bus_watch`, `handle_bus_message`, `apply_state_change`, and `make_element` stay private to `pipeline.rs`.

- [ ] **Step 3: Wire the module up in `mod.rs`**

At the top of `crates/stash-player-ui/src/widgets/video_player/mod.rs`, below the doc comment:

```rust
mod pipeline;

use pipeline::PlaybackPipeline;
```

Remove the now-unused imports from `mod.rs` — `gst::prelude::*` and `gtk::prelude::*` are still needed, but check what the compiler reports and delete only what it flags.

- [ ] **Step 4: Verify the build is unchanged**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: clean, no warnings. If `unreachable_pub` fires, the visibility should be `pub(super)`, not `pub`.

- [ ] **Step 5: Confirm the app still runs**

```sh
cargo run -p stash-player-ui
```

Open a scene, confirm playback and seeking behave exactly as before (the seek bug is still present — that's Task 3). Close.

- [ ] **Step 6: Commit**

```bash
git add crates/stash-player-ui/src/widgets/video_player/
git commit -m "refactor(ui): extract PlaybackPipeline into its own module

Pure move, no behaviour change. video_player.rs was 1673 lines and the
seek and OSD work that follows adds to it."
```

---

### Task 3: Wire `SeekTracker` into the player — fixes defect 3

Replaces the player's `position_us` / `duration_us` / `last_user_seek` triple with the tracker, deletes both 400 ms wall-clock windows, and routes GStreamer's `AsyncDone` into `on_async_done`.

**Files:**
- Modify: `crates/stash-player-ui/src/widgets/video_player/mod.rs`
- Modify: `crates/stash-player-ui/src/widgets/video_player/pipeline.rs`
- Modify: `crates/stash-player-ui/Cargo.toml`

**Interfaces:**
- Consumes: `stash_player_core::playback::SeekTracker` (Task 1).
- Produces: `VideoPlayerMsg::SeekLanded(i64)` — a new input variant posted by the bus watch when the pipeline reports a seek completed, carrying the position observed at that moment (or a negative value if the query failed).

- [ ] **Step 1: Add the core dependency**

`crates/stash-player-ui/Cargo.toml` already depends on `stash-player-core`; confirm with:

```sh
grep -n "stash-player-core" crates/stash-player-ui/Cargo.toml
```

If absent, add under `[dependencies]`:

```toml
stash-player-core = { path = "../stash-player-core" }
```

- [ ] **Step 2: Post `SeekLanded` from the bus watch**

In `pipeline.rs`, change `handle_bus_message` to return the landing position, and drop the `seeking` flag entirely — nothing reads it once the tracker owns seek state.

Change the `BusFlags` struct to:

```rust
/// State flags shared between the bus watch and the owning `PlaybackPipeline`.
struct BusFlags {
    prepared: Rc<Cell<bool>>,
    playing: Rc<Cell<bool>>,
    error: Rc<RefCell<Option<String>>>,
}
```

Change `install_bus_watch`'s closure to forward the landing:

```rust
    bus.add_watch_local(move |_, msg| {
        if let Some(landed_us) = handle_bus_message(msg, &flags, &pipeline_weak) {
            sender.input(VideoPlayerMsg::SeekLanded(landed_us));
        }
        sender.input(VideoPlayerMsg::Tick);
        glib::ControlFlow::Continue
    })
    .ok()
```

Change `handle_bus_message`'s signature and its `AsyncDone` / `AsyncStart` / `Error` arms:

```rust
/// Returns the position observed at a seek landing, if this message was
/// one. A negative value means the position query failed.
fn handle_bus_message(
    msg: &gst::Message,
    flags: &BusFlags,
    pipeline_weak: &glib::WeakRef<gst::Pipeline>,
) -> Option<i64> {
    use gst::MessageView;
    match msg.view() {
        MessageView::Error(err) => {
            let glib_err = err.error();
            tracing::warn!(
                "gstreamer error from {:?}: {} ({:?})",
                err.src().map(|s| s.path_string()),
                glib_err,
                err.debug()
            );
            *flags.error.borrow_mut() = Some(glib_err.to_string());
            None
        }
        MessageView::AsyncDone(_) => {
            let landed_us = pipeline_weak
                .upgrade()
                .and_then(|p| p.query_position::<gst::ClockTime>())
                .map(|t| t.useconds() as i64)
                .unwrap_or(-1);
            tracing::debug!(landed_us, "bus: AsyncDone — seek complete, prepared");
            flags.prepared.set(true);
            Some(landed_us)
        }
        MessageView::StateChanged(sc) => {
            apply_state_change(sc, flags, pipeline_weak);
            None
        }
        MessageView::DurationChanged(_) | MessageView::Eos(_) => None,
        _ => None,
    }
}
```

The `AsyncStart` arm is deleted along with the flag it set.

In `PlaybackPipeline`, delete the `seeking: Rc<Cell<bool>>` field, its initialiser in `new`, its entry in the `BusFlags` literal, and the `is_seeking` method.

- [ ] **Step 3: Swap the model fields**

In `mod.rs`, add the import:

```rust
use stash_player_core::playback::SeekTracker;
```

In `struct VideoPlayer`, replace these three fields:

```rust
    duration_us: i64,
    position_us: i64,
    /// Timestamp of the most recent user-driven seek slider change. [...]
    last_user_seek: Rc<Cell<Option<Instant>>>,
```

with:

```rust
    /// Playhead position and duration, including seeks that haven't
    /// landed yet. See `stash_player_core::playback` for why this can't
    /// just be the polled position.
    seek: SeekTracker,
    /// True while a pointer button is held on the seek slider, so
    /// `refresh_widgets` doesn't fight the user's drag.
    dragging: Rc<Cell<bool>>,
```

In `new_model`, replace the `last_user_seek` parameter with `dragging: Rc<Cell<bool>>`, and the three field initialisers with:

```rust
            seek: SeekTracker::new(),
            dragging,
```

In `init`, replace the `last_user_seek` local:

```rust
        let dragging = Rc::new(Cell::new(false));

        let mut model = VideoPlayer::new_model(
            &init,
            suppress_scale.clone(),
            suppress_volume.clone(),
            dragging.clone(),
        );

        let widgets = view_output!();

        wire_slider_handlers(
            &widgets,
            &sender,
            &suppress_scale,
            &suppress_volume,
            &dragging,
        );
```

- [ ] **Step 4: Add the `SeekLanded` message and drop the seek-window helper**

In `enum VideoPlayerMsg`, add:

```rust
    /// The pipeline reported a seek completed, at this position in
    /// microseconds. Negative means the position query failed.
    SeekLanded(i64),
```

In `update_with_view`'s match, next to the other seek arms:

```rust
            VideoPlayerMsg::SeekLanded(landed_us) => self.seek.on_async_done(landed_us),
```

Delete the whole `fn update_position_from_poll` method — the tracker replaces it.

- [ ] **Step 5: Rewrite the seek handlers**

Replace the three handlers. Note the borrow order: the tracker needs `&mut self`, so compute the target *before* taking `self.media.as_ref()`.

```rust
    fn handle_seek_relative(&mut self, sender: &ComponentSender<Self>, secs: i64) {
        if !self.is_prepared() {
            return;
        }
        let target = self
            .seek
            .seek_relative(secs.saturating_mul(1_000_000), Instant::now());
        tracing::debug!(secs, target_us = target, "SeekRelative");
        self.issue_seek(target);
        self.emit_checkpoint(sender);
        sender.input(VideoPlayerMsg::PointerActive);
    }

    fn handle_seek_fraction(&mut self, sender: &ComponentSender<Self>, fraction: f64) {
        if !self.is_prepared() {
            return;
        }
        let target = self.seek.seek_fraction(fraction, Instant::now());
        tracing::debug!(fraction, target_us = target, "SeekFraction");
        self.issue_seek(target);
        self.emit_checkpoint(sender);
        sender.input(VideoPlayerMsg::PointerActive);
    }

    fn handle_user_seek(&mut self, sender: &ComponentSender<Self>, us: i64) {
        if !self.is_prepared() {
            return;
        }
        let target = self.seek.seek_absolute(us, Instant::now());
        tracing::debug!(slider_us = us, target_us = target, "UserSeek");
        self.issue_seek(target);
        self.emit_checkpoint(sender);
    }

    /// True when there's a stream loaded and prepared enough to seek.
    fn is_prepared(&self) -> bool {
        self.media.as_ref().is_some_and(|m| m.is_prepared())
    }

    /// Hand a target the tracker has already clamped to the pipeline.
    fn issue_seek(&self, target_us: i64) {
        if let Some(media) = self.media.as_ref() {
            media.seek(target_us);
        }
    }
```

- [ ] **Step 6: Route the tick and resume through the tracker**

In `handle_tick`, replace the duration and position block:

```rust
        // Duration queries can transiently return 0 while a flushing
        // seek is in flight; SeekTracker::set_duration_us ignores those.
        self.seek.set_duration_us(snapshot.duration_us);
        self.playback.playing = status.now_playing;
        self.volume = snapshot.volume;
        self.muted = snapshot.muted;

        self.seek.on_poll(snapshot.position_us, Instant::now());
        self.apply_pending_resume(status.is_prepared);
```

Delete `media_seeking` from `struct PipelineStatus` and from the `TickSnapshot` literal in `handle_tick` — nothing reads it now.

Rewrite `apply_pending_resume`:

```rust
    /// Apply the pending resume seek once the stream is ready enough
    /// that a clamp against duration is meaningful.
    fn apply_pending_resume(&mut self, is_prepared: bool) {
        if !is_prepared || self.seek.duration_us() <= 0 {
            return;
        }
        let Some(resume) = self.resume_pending.take() else {
            return;
        };
        let target = self
            .seek
            .seek_absolute((resume * 1_000_000.0) as i64, Instant::now());
        self.issue_seek(target);
    }
```

In `handle_set_url`, replace:

```rust
        self.duration_us = 0;
        self.position_us = 0;
```

with:

```rust
        self.seek.on_stream_reset();
```

In `emit_checkpoint`, replace `self.position_us` with `self.seek.position_us()`.

- [ ] **Step 7: Rewrite the slider refresh**

In `refresh_widgets`, replace the seek-slider block:

```rust
        // The tracker's position never regresses spuriously, so we push
        // it unconditionally — except while the user has the thumb held,
        // where our writes would fight the drag.
        let duration_us = self.seek.duration_us();
        let max = duration_us.max(1) as f64;
        widgets.seek_scale.set_range(0.0, max);
        if !self.dragging.get() {
            let pos = self.seek.position_us().clamp(0, duration_us.max(0)) as f64;
            self.suppress_scale.set(true);
            widgets.seek_scale.set_value(pos);
            self.suppress_scale.set(false);
        }
        widgets.seek_scale.set_sensitive(duration_us > 0);

        widgets
            .position_label
            .set_label(&format_us(self.seek.position_us()));
        let duration_text = if duration_us > 0 {
            format_us(duration_us)
        } else {
            "--:--".into()
        };
        widgets.duration_label.set_label(&duration_text);
```

- [ ] **Step 8: Track the drag with a gesture**

Replace `wire_slider_handlers`:

```rust
/// Hook the seek + volume scales: anything that isn't our own programmatic
/// write becomes a UserSeek/SetVolume. A capture-phase click gesture on the
/// seek scale tracks whether a pointer button is currently held, so
/// `refresh_widgets` can leave the thumb alone mid-drag.
fn wire_slider_handlers(
    widgets: &VideoPlayerWidgets,
    sender: &ComponentSender<VideoPlayer>,
    suppress_scale: &Rc<Cell<bool>>,
    suppress_volume: &Rc<Cell<bool>>,
    dragging: &Rc<Cell<bool>>,
) {
    {
        let sender = sender.clone();
        let suppress = suppress_scale.clone();
        widgets.seek_scale.connect_value_changed(move |s| {
            if suppress.get() {
                return;
            }
            sender.input(VideoPlayerMsg::UserSeek(s.value() as i64));
        });
    }
    {
        // Capture phase: GtkScale's own gestures would otherwise claim
        // the sequence before we see the press.
        let drag = gtk::GestureClick::new();
        drag.set_propagation_phase(gtk::PropagationPhase::Capture);
        let on_press = dragging.clone();
        drag.connect_pressed(move |_, _, _, _| on_press.set(true));
        let on_release = dragging.clone();
        drag.connect_released(move |_, _, _, _| on_release.set(false));
        // A cancelled gesture (grab stolen, pointer left the surface)
        // never delivers `released`; without this the thumb would stay
        // frozen for the rest of the session.
        let on_cancel = dragging.clone();
        drag.connect_cancel(move |_, _| on_cancel.set(false));
        widgets.seek_scale.add_controller(drag);
    }
    let sender = sender.clone();
    let suppress = suppress_volume.clone();
    widgets.volume_scale.connect_value_changed(move |s| {
        if suppress.get() {
            return;
        }
        sender.input(VideoPlayerMsg::SetVolume(s.value()));
    });
}
```

- [ ] **Step 9: Fix remaining references and build**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

The compiler will point at any leftover `self.position_us` / `self.duration_us` / `last_user_seek` references. Replace reads with `self.seek.position_us()` / `self.seek.duration_us()`. If `Instant` or `Duration` imports become unused, remove them.

Also update the module doc comment at the top of `mod.rs` — the paragraph beginning "Position polling runs at 4 Hz" describes the deleted suppression scheme. Replace its last sentence with:

```
//! Position polling runs at 4 Hz via `glib::timeout_add_local`, feeding a
//! `SeekTracker` that ignores readings inconsistent with an outstanding
//! seek — see `stash_player_core::playback`.
```

Expected: clean.

- [ ] **Step 10: Verify the fix by hand**

```sh
RUST_LOG=info,stash_player_ui=debug cargo run -p stash-player-ui
```

On a long, high-bitrate scene:
1. Press `l` (forward 10s) five times rapidly. The position label must advance by ~10s each press and never jump backward. The `SeekRelative` debug lines must show a strictly increasing `target_us`.
2. Press `j` (back 10s) five times rapidly. Same, decreasing.
3. Drag the seek slider across the bar and release. The thumb must stay under the pointer during the drag and stay put on release.
4. Let it play for 30s untouched. The label must track playback normally.

- [ ] **Step 11: Commit**

```bash
git add crates/stash-player-ui/src/widgets/video_player/ crates/stash-player-ui/Cargo.toml
git commit -m "fix(ui): stop seeks re-landing in the same place

Position tracking was time-based: two 400ms windows decided whether to
trust a polled position. ACCURATE seeks on high-bitrate streams outlast
that window, so the poll snapped the model back to the pre-seek keyframe
and the next relative seek anchored on the stale value.

Replaced with SeekTracker, which accepts a reading only when it is
consistent with the outstanding seek's target, and routes GStreamer's
AsyncDone in as the authoritative landing."
```

---

### Task 4: Library viewport-fill pagination — fixes defect 1

**Files:**
- Modify: `crates/stash-player-ui/src/pages/library.rs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks depend on.

**Background for the implementer.** `LoadMore` fires only from `connect_edge_reached`, which GTK emits when a *scroll* reaches the edge. On a large monitor the first 24 cards fit inside the viewport, so there is nothing to scroll, no edge is ever reached, and the grid stops at 24 forever. The fix is to check the scroll adjustment after every page lands instead of waiting for a scroll event.

- [ ] **Step 1: Add the constants and the threshold function**

At the top of `library.rs`, change `PAGE_SIZE` and add `PREFETCH_VIEWPORTS`:

```rust
const PAGE_SIZE: u32 = 48;
/// How many viewport-heights of not-yet-scrolled content to keep loaded
/// ahead of the user.
const PREFETCH_VIEWPORTS: f64 = 1.5;
```

Add this free function near `format_duration` at the bottom of the file:

```rust
/// True when the grid should pull another page.
///
/// One condition covers both cases we care about. If the content doesn't
/// fill the viewport at all, `upper == page_size` and `value == 0`, so
/// `remaining` is 0 and we load more — this is the case `edge-reached`
/// could never catch, because nothing is scrollable. Otherwise it's a
/// plain prefetch check against how much unseen content is left below.
fn should_load_more(adj: &gtk::Adjustment) -> bool {
    let page = adj.page_size();
    if page <= 0.0 {
        return false;
    }
    let remaining = adj.upper() - adj.value() - page;
    remaining < page * PREFETCH_VIEWPORTS
}
```

- [ ] **Step 2: Add the `exhausted` flag and the `MaybeLoadMore` message**

In `struct LibraryPage`, after `loading: bool`:

```rust
    /// Set once the server returns a short page — there is nothing left
    /// to fetch for the current filter, whatever `total` claims.
    exhausted: bool,
```

In `init`'s model literal, after `loading: false,`:

```rust
            exhausted: false,
```

In `fn reset`, after `self.loaded = 0;`:

```rust
        self.exhausted = false;
```

In `enum LibraryMsg`, after `LoadMore`:

```rust
    /// Re-evaluate whether another page is needed, based on how much
    /// unscrolled content is left. Cheap and idempotent.
    MaybeLoadMore,
```

- [ ] **Step 3: Name the scroller and drop `edge-reached`**

In the `view!` block, replace:

```rust
                    add_named[Some("grid")] = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,
                        connect_edge_reached[sender] => move |_, edge| {
                            if edge == gtk::PositionType::Bottom {
                                sender.input(LibraryMsg::LoadMore);
                            }
                        },
```

with:

```rust
                    #[name = "scroller"]
                    add_named[Some("grid")] = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,
```

- [ ] **Step 4: Drive `MaybeLoadMore` from the adjustment**

In `init`, after `widgets.tasks_popover.set_parent(&widgets.tasks_btn);`:

```rust
        // Scroll-driven prefetch. This replaces `edge-reached`, which
        // never fires when the content already fits the viewport.
        {
            let sender = sender.clone();
            widgets
                .scroller
                .vadjustment()
                .connect_value_changed(move |_| {
                    sender.input(LibraryMsg::MaybeLoadMore);
                });
        }
```

- [ ] **Step 5: Handle the message and guard `LoadMore`**

In `update_with_view`'s match, replace the `LoadMore` arm and add the new one:

```rust
            LibraryMsg::LoadMore => {
                if !self.loading
                    && !self.exhausted
                    && self.client.is_some()
                    && (self.total == 0 || self.loaded < self.total as u32)
                {
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::MaybeLoadMore => {
                if should_load_more(&widgets.scroller.vadjustment()) {
                    sender.input(LibraryMsg::LoadMore);
                }
            }
```

- [ ] **Step 6: Re-check after every page lands**

In `update_cmd_with_view`, replace the `LibraryCmd::Page(Ok(page))` arm:

```rust
            LibraryCmd::Page(Ok(page)) => {
                self.loading = false;
                self.error = None;
                self.total = page.count;
                let start_index = self.loaded;
                let count = page.scenes.len() as u32;
                for (i, scene) in page.scenes.into_iter().enumerate() {
                    self.append_cell(widgets, scene, start_index + i as u32, &sender);
                }
                self.loaded = start_index + count;
                // A short page means the result set is done, whatever
                // `count` claims — this is what stops the fill loop if
                // the server over-reports its total.
                if count < PAGE_SIZE {
                    self.exhausted = true;
                }
                // The adjustment still holds pre-layout values right
                // after appending children, so defer the check by one
                // main-loop iteration.
                let tx = sender.input_sender().clone();
                glib::idle_add_local_once(move || {
                    let _ = tx.send(LibraryMsg::MaybeLoadMore);
                });
            }
```

- [ ] **Step 7: Build**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: clean.

- [ ] **Step 8: Verify by hand**

```sh
RUST_LOG=info,stash_player_ui=debug cargo run -p stash-player-ui
```

Maximise the window on the largest available monitor, then:
1. On launch the log must show `fetching scenes page 1`, then `page 2`, and keep going until the grid overflows the viewport. It must not stop at one page.
2. Scroll down. Pages must keep arriving *before* you hit the bottom, not after.
3. Scroll to the very end of a filter with a known small result set (set a min rating high enough to return under 48 scenes). Loading must stop; the log must not loop.
4. Change the sort key. The grid must reset and refill from page 1.

- [ ] **Step 9: Commit**

```bash
git add crates/stash-player-ui/src/pages/library.rs
git commit -m "fix(ui): keep loading scenes when the grid fits the viewport

LoadMore fired only from edge-reached, which needs a scroll event. On a
large monitor the first page fits on screen, nothing scrolls, and the
grid stopped at 24 scenes permanently.

Check the scroll adjustment after every page instead, which covers both
the viewport-fill and prefetch cases, and stop on a short page."
```

---

### Task 5: Split `scene.rs` and fix duplicated file rows — fixes defect 2

**Files:**
- Create: `crates/stash-player-ui/src/pages/scene/mod.rs` (from the existing `scene.rs`)
- Create: `crates/stash-player-ui/src/pages/scene/metadata.rs`
- Delete: `crates/stash-player-ui/src/pages/scene.rs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `crate::pages::scene::metadata` with `pub(super) fn populate_scene(widgets: &ScenePageWidgets, scene: &Scene)`, `pub(super) fn update_o_widgets(widgets: &ScenePageWidgets, count: i32)`, `pub(super) fn build_stream_url(client: &stash_api::Client, scene: &Scene) -> Option<String>`, `pub(super) fn page_title(state: &State) -> String`, `pub(super) fn stash_scene_url(client: &stash_api::Client, scene_id: &str) -> String`. `enum State` in `mod.rs` becomes `pub(super)` so `metadata.rs` can match on it.

**Background for the implementer.** `populate_file_group` calls `group.add(...)` and never removes what's already there. `populate_scene` runs on every prev/next, so each navigation appends three more rows to the same `AdwPreferencesGroup` — five scenes in, the File section shows fifteen rows. The neighbouring `populate_performers` already does the right thing; the fix is to make all the populate helpers share its clear-then-build shape.

- [ ] **Step 1: Move the file into a directory module**

```sh
mkdir -p crates/stash-player-ui/src/pages/scene
git mv crates/stash-player-ui/src/pages/scene.rs \
       crates/stash-player-ui/src/pages/scene/mod.rs
```

- [ ] **Step 2: Create `metadata.rs`**

Move these free functions **verbatim** out of `mod.rs` into a new `crates/stash-player-ui/src/pages/scene/metadata.rs`: `populate_scene`, `build_stream_url`, `update_o_widgets`, `populate_performers`, `populate_file_group`, `info_row`, `page_title`, `subtitle_text`, `format_duration`, `format_resolution`, `stash_scene_url`.

Head the new file with:

```rust
//! Widget population for the scene page.
//!
//! Every `populate_*` helper here follows one convention: **clear, then
//! build**. Adding to a container without emptying it first is what made
//! the File section grow three rows per prev/next navigation.

use relm4::{adw, gtk};

use adw::prelude::*;

use stash_api::{PerformerRef, Scene, SceneFile};

use super::{ScenePageWidgets, State};
```

Mark the five functions listed in **Interfaces** as `pub(super)`; leave `populate_performers`, `populate_file_group`, `info_row`, `subtitle_text`, `format_duration`, and `format_resolution` private to `metadata.rs`.

In `mod.rs`, add below the doc comment:

```rust
mod metadata;

use metadata::{build_stream_url, page_title, populate_scene, stash_scene_url, update_o_widgets};
```

and change `enum State` to `pub(super) enum State`.

- [ ] **Step 3: Verify the move builds before changing behaviour**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: clean. Fix any import fallout in `mod.rs` (the compiler will name the now-unused ones).

- [ ] **Step 4: Commit the move on its own**

```bash
git add crates/stash-player-ui/src/pages/scene/
git commit -m "refactor(ui): split scene page metadata helpers into a module"
```

- [ ] **Step 5: Swap the preferences group for a rebuildable container**

In `mod.rs`'s `view!` block, replace:

```rust
                                    #[name = "file_group"]
                                    adw::PreferencesGroup {
                                        set_title: "File",
                                        set_visible: false,
                                    },
```

with:

```rust
                                    // Rebuilt wholesale by
                                    // `populate_file_group` so navigating
                                    // between scenes replaces the rows
                                    // instead of appending to them.
                                    #[name = "file_section"]
                                    gtk::Box {
                                        set_orientation: gtk::Orientation::Vertical,
                                        set_visible: false,
                                    },
```

- [ ] **Step 6: Rewrite `populate_file_group`**

In `metadata.rs`, replace the function and its call site in `populate_scene`:

```rust
    populate_file_group(&widgets.file_section, scene.files.first());
```

```rust
/// Rebuild the File section from scratch. Clearing first is the whole
/// point: this runs on every prev/next, and the previous implementation
/// appended to a persistent group, so the rows accumulated.
fn populate_file_group(container: &gtk::Box, file: Option<&SceneFile>) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }

    let Some(file) = file else {
        container.set_visible(false);
        return;
    };

    let group = adw::PreferencesGroup::builder().title("File").build();
    let mut shown = false;

    if let (Some(w), Some(h)) = (file.width, file.height) {
        group.add(&info_row("Resolution", &format!("{w} × {h}")));
        shown = true;
    }
    if let Some(codec) = file.video_codec.as_deref()
        && !codec.is_empty()
    {
        group.add(&info_row("Codec", codec));
        shown = true;
    }
    if let Some(fps) = file.frame_rate {
        group.add(&info_row("Frame rate", &format!("{fps:.2} fps")));
        shown = true;
    }

    if shown {
        container.append(&group);
    }
    container.set_visible(shown);
}
```

- [ ] **Step 7: Build**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: clean.

- [ ] **Step 8: Verify by hand**

```sh
cargo run -p stash-player-ui
```

Open a scene, then press the next-scene button five times. Scroll to the File section. It must show at most three rows (Resolution, Codec, Frame rate) — not fifteen. Navigate to a scene with no file info and confirm the section disappears rather than showing an empty group.

- [ ] **Step 9: Commit**

```bash
git add crates/stash-player-ui/src/pages/scene/
git commit -m "fix(ui): stop File metadata rows accumulating across scenes

populate_file_group added rows to a persistent AdwPreferencesGroup
without clearing, so every prev/next appended three more. Rebuild the
section into a container that gets emptied first, matching the
clear-then-build shape the other populate helpers already use."
```

---

### Task 6: Scene actions in the player OSD

Adds prev/next, the O-counter, and the rating to the player OSD. The old action cluster in the metadata pane stays for now — Task 7 removes it. Both work in the meantime.

**Files:**
- Modify: `crates/stash-player-ui/src/widgets/video_player/mod.rs`
- Modify: `crates/stash-player-ui/src/pages/scene/mod.rs`
- Modify: `crates/stash-player-ui/src/styles.css`

**Interfaces:**
- Consumes: `VideoPlayerMsg`, `VideoPlayerOutput` (Task 3).
- Produces, in `crate::widgets::video_player`:
  ```rust
  pub(crate) struct SceneActionState {
      pub(crate) can_prev: bool,
      pub(crate) can_next: bool,
      pub(crate) o_count: i32,
      pub(crate) rating100: Option<i32>,
  }   // derives Debug, Clone, Copy, Default

  pub(crate) enum SceneAction { Prev, Next, IncrementO, ResetO }  // derives Debug, Clone, Copy

  VideoPlayerMsg::SetSceneActions(SceneActionState)
  VideoPlayerOutput::SceneAction(SceneAction)
  ```
  And in `crate::pages::scene`: `ScenePage::push_scene_actions(&self)`.

**Design constraint.** `VideoPlayer` renders four labelled controls and forwards clicks. It must not learn what an O-counter *means*, must not touch `stash_api`, and must not gain any scene-specific state beyond the one `SceneActionState` record. All mutations stay in `ScenePage`, which already owns them.

- [ ] **Step 1: Define the two types**

In `mod.rs` of `video_player`, above `enum VideoPlayerMsg`:

```rust
/// Everything the OSD needs to render the scene-level controls. Grouped
/// into one record so `VideoPlayerMsg` doesn't grow a cluster of
/// near-identical variants — the player treats these as opaque display
/// values and never interprets them.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct SceneActionState {
    pub(crate) can_prev: bool,
    pub(crate) can_next: bool,
    pub(crate) o_count: i32,
    pub(crate) rating100: Option<i32>,
}

/// A scene-level control the user activated. The player forwards these
/// verbatim; the scene page decides what they do.
#[derive(Debug, Clone, Copy)]
pub(crate) enum SceneAction {
    Prev,
    Next,
    IncrementO,
    ResetO,
}
```

Add to `enum VideoPlayerMsg`:

```rust
    /// Refresh the OSD's scene-level controls.
    SetSceneActions(SceneActionState),
```

Add to `enum VideoPlayerOutput`:

```rust
    /// A scene-level OSD control was activated. The player has no idea
    /// what these mean — the scene page does.
    SceneAction(SceneAction),
```

Add to `struct VideoPlayer`:

```rust
    /// Display state for the OSD's scene-level controls, pushed in by
    /// the scene page.
    scene_actions: SceneActionState,
```

and to `new_model`'s literal:

```rust
            scene_actions: SceneActionState::default(),
```

Add to `update_with_view`'s match:

```rust
            VideoPlayerMsg::SetSceneActions(state) => self.scene_actions = state,
```

- [ ] **Step 2: Add the controls to the transport row**

In the `view!` transport row, insert **before** the existing `play_button`:

```rust
                                #[name = "prev_scene_button"]
                                gtk::Button {
                                    set_icon_name: "media-skip-backward-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Previous scene"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::SceneActionClicked(
                                            SceneAction::Prev,
                                        ));
                                    },
                                },
```

**after** the existing `play_button`:

```rust
                                #[name = "next_scene_button"]
                                gtk::Button {
                                    set_icon_name: "media-skip-forward-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Next scene"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::SceneActionClicked(
                                            SceneAction::Next,
                                        ));
                                    },
                                },
```

and, replacing the single `gtk::Box { set_hexpand: true }` spacer, this block (two spacers so the O-counter and rating sit centred):

```rust
                                gtk::Box { set_hexpand: true },

                                gtk::Box {
                                    add_css_class: "linked",
                                    set_valign: gtk::Align::Center,

                                    gtk::Button {
                                        add_css_class: "flat",
                                        set_tooltip_text: Some("Bump O-counter"),
                                        connect_clicked[sender] => move |_| {
                                            sender.input(VideoPlayerMsg::SceneActionClicked(
                                                SceneAction::IncrementO,
                                            ));
                                        },

                                        #[wrap(Some)]
                                        set_child = &gtk::Box {
                                            set_orientation: gtk::Orientation::Horizontal,
                                            set_spacing: 6,
                                            set_valign: gtk::Align::Center,

                                            gtk::Image {
                                                set_icon_name: Some("o-counter-symbolic"),
                                                set_pixel_size: 14,
                                            },

                                            #[name = "osd_o_count_label"]
                                            gtk::Label {
                                                add_css_class: "o-counter-pill",
                                            },
                                        },
                                    },

                                    #[name = "osd_o_reset_button"]
                                    gtk::Button {
                                        set_icon_name: "edit-clear-symbolic",
                                        add_css_class: "flat",
                                        set_tooltip_text: Some("Reset O-counter to 0"),
                                        connect_clicked[sender] => move |_| {
                                            sender.input(VideoPlayerMsg::SceneActionClicked(
                                                SceneAction::ResetO,
                                            ));
                                        },
                                    },
                                },

                                #[name = "osd_rating_label"]
                                gtk::Label {
                                    add_css_class: "rating-badge",
                                    set_valign: gtk::Align::Center,
                                    set_margin_start: 8,
                                    set_visible: false,
                                },

                                gtk::Box { set_hexpand: true },
```

Add the intermediate message that the buttons above use, to `enum VideoPlayerMsg`:

```rust
    /// An OSD scene-level control was clicked; forwarded to the parent.
    SceneActionClicked(SceneAction),
```

and to `update_with_view`'s match:

```rust
            VideoPlayerMsg::SceneActionClicked(action) => {
                let _ = sender.output(VideoPlayerOutput::SceneAction(action));
                sender.input(VideoPlayerMsg::PointerActive);
            }
```

- [ ] **Step 3: Render the state in `refresh_widgets`**

Append to `refresh_widgets`, next to the fullscreen icon block:

```rust
        // Scene-level OSD controls. Purely a projection of whatever the
        // scene page last pushed in.
        let actions = self.scene_actions;
        widgets.prev_scene_button.set_sensitive(actions.can_prev);
        widgets.next_scene_button.set_sensitive(actions.can_next);
        widgets
            .osd_o_count_label
            .set_label(&actions.o_count.to_string());
        widgets
            .osd_o_reset_button
            .set_visible(actions.o_count > 0);
        match actions.rating100.filter(|r| *r > 0) {
            Some(rating) => {
                let stars = rating as f32 / 10.0;
                widgets.osd_rating_label.set_label(&format!("★ {stars:.1}"));
                widgets.osd_rating_label.set_visible(true);
            }
            None => widgets.osd_rating_label.set_visible(false),
        }
```

If `refresh_widgets` now trips `too_many_lines`, extract this block into a free function `fn refresh_scene_actions(widgets: &VideoPlayerWidgets, actions: SceneActionState)` and call it. Do not add an `#[allow]`.

- [ ] **Step 4: Feed the state from `ScenePage`**

In `pages/scene/mod.rs`, extend the import:

```rust
use crate::widgets::video_player::{
    SceneAction, SceneActionState, VideoPlayer, VideoPlayerInit, VideoPlayerMsg,
    VideoPlayerOutput,
};
```

Add to the `.forward(...)` closure in `init`:

```rust
                VideoPlayerOutput::SceneAction(action) => match action {
                    SceneAction::Prev => SceneMsg::Prev,
                    SceneAction::Next => SceneMsg::Next,
                    SceneAction::IncrementO => SceneMsg::IncrementO,
                    SceneAction::ResetO => SceneMsg::ResetO,
                },
```

Add this method to `impl ScenePage`:

```rust
    /// Push the OSD's scene-level control state to the player. Called
    /// after anything that changes what those controls should show.
    fn push_scene_actions(&self) {
        let o_count = match &self.state {
            State::Loaded(scene) => scene.o_counter.unwrap_or(0),
            _ => 0,
        };
        let rating100 = match &self.state {
            State::Loaded(scene) => scene.rating100,
            _ => None,
        };
        self.player
            .emit(VideoPlayerMsg::SetSceneActions(SceneActionState {
                can_prev: self.can_go_prev(),
                can_next: self.can_go_next(),
                o_count,
                rating100,
            }));
    }
```

Call it at the end of each of the four arms in `update_cmd_with_view` — `SceneCmd::Loaded`, `SceneCmd::Neighbor`, `SceneCmd::ActivitySaved`, `SceneCmd::OUpdated`. The simplest correct placement is one call immediately before the closing `self.update_view(widgets, sender);` of `update_cmd_with_view`:

```rust
        self.push_scene_actions();
        self.update_view(widgets, sender);
```

Also add the same call before `self.update_view(widgets, sender);` at the end of `update_with_view`, so a `Prev`/`Next` that starts a navigation immediately greys the buttons out.

- [ ] **Step 5: Style the OSD additions**

In `crates/stash-player-ui/src/styles.css`, after the existing `.video-osd button.video-osd-primary` rules, add:

```css
/* Scene-level controls in the OSD reuse the pill styling from the
   metadata pane, toned down to sit on the dark scrim. */
.video-osd .o-counter-pill {
  font-weight: bold;
  font-variant-numeric: tabular-nums;
}

.video-osd .rating-badge {
  background: rgba(0, 0, 0, 0.45);
  border-radius: 999px;
  padding: 2px 10px;
  font-weight: bold;
}
```

- [ ] **Step 6: Build**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: clean.

- [ ] **Step 7: Verify by hand**

```sh
cargo run -p stash-player-ui
```

1. Open a scene from the library. The OSD shows ⏮ ⏵ ⏭, the O-counter pill, and (if the scene is rated) a star badge.
2. Click the OSD's `+` O-counter button. The count increments in both the OSD and the metadata pane below.
3. Click the OSD reset button. Both go to 0 and the reset button disappears from both.
4. Click OSD next/prev. Navigation happens exactly as the metadata pane's buttons do.
5. Open a scene directly (not from the library, so there's no nav context). OSD prev/next are insensitive.

- [ ] **Step 8: Commit**

```bash
git add crates/stash-player-ui/src/widgets/video_player/ crates/stash-player-ui/src/pages/scene/ crates/stash-player-ui/src/styles.css
git commit -m "feat(ui): surface scene actions in the player OSD

Prev/next, the O-counter, and the rating move onto the OSD control row,
carried by one SetSceneActions message in and one SceneAction message
out so the player stays ignorant of what they mean."
```

---

### Task 7: Video-first scene page with a metadata drawer — fixes defect 4

**Files:**
- Modify: `crates/stash-player-ui/src/pages/scene/mod.rs`
- Modify: `crates/stash-player-ui/src/pages/scene/metadata.rs`
- Modify: `crates/stash-player-ui/src/styles.css`

**Interfaces:**
- Consumes: `SceneActionState` / `SceneAction` (Task 6).
- Produces: `SceneMsg::ToggleDrawer`, `SceneMsg::SetDrawerShown(bool)`. `metadata::populate_scene` now writes to `widgets.window_title` (an `adw::WindowTitle`) instead of `title_label` / `subtitle_label`, and `update_o_widgets` / the `rating_badge` handling are deleted from `metadata.rs` — the OSD owns both now.

**Background for the implementer.** The player currently lives inside a `ScrolledWindow`, so its height comes from content natural size (the `Picture`'s 540 px floor plus the paintable's intrinsic size) rather than from the window. That is why the video area doesn't track the window. Putting the player directly in the content area, under an `adw::OverlaySplitView` that is *permanently* collapsed, means the drawer overlays rather than resizes and the player is always allocated the full content region.

`collapsed: true` is set unconditionally and never bound to a breakpoint. That is deliberate — it is what guarantees opening the drawer can't reallocate the video.

- [ ] **Step 1: Replace the `loaded` stack page and the toolbar content**

In `mod.rs`'s `view!`, replace the `add_top_bar` block and everything from `set_content = &gtk::Stack {` through the end of the `add_named[Some("loaded")]` block, keeping the `loading` / `missing` / `error` pages and the trailing `#[watch] set_visible_child_name` exactly as they are.

The new `add_top_bar`:

```rust
                add_top_bar = &adw::HeaderBar {
                    add_css_class: "scene-headerbar",

                    #[wrap(Some)]
                    #[name = "window_title"]
                    set_title_widget = &adw::WindowTitle {
                        set_title: "",
                        set_subtitle: "",
                    },

                    #[name = "drawer_button"]
                    pack_end = &gtk::ToggleButton {
                        // dialog-information-symbolic ships in every
                        // Adwaita version we support. If the GNOME 47+
                        // "info-outline-symbolic" is present it reads
                        // better in a header bar — check with
                        // `gtk4-icon-browser` before swapping.
                        set_icon_name: "dialog-information-symbolic",
                        set_tooltip_text: Some("Scene details"),
                        connect_toggled[sender] => move |b| {
                            sender.input(SceneMsg::SetDrawerShown(b.is_active()));
                        },
                    },

                    pack_end = &gtk::MenuButton {
                        set_icon_name: "view-more-symbolic",
                        set_tooltip_text: Some("More"),

                        #[wrap(Some)]
                        set_popover = &gtk::Popover {
                            #[wrap(Some)]
                            set_child = &gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_spacing: 6,
                                set_margin_start: 6,
                                set_margin_end: 6,
                                set_margin_top: 6,
                                set_margin_bottom: 6,

                                gtk::Box {
                                    set_orientation: gtk::Orientation::Horizontal,
                                    set_spacing: 12,

                                    gtk::Label {
                                        set_label: "Autoplay",
                                        set_hexpand: true,
                                        set_xalign: 0.0,
                                    },

                                    gtk::Switch {
                                        set_valign: gtk::Align::Center,
                                        #[watch]
                                        set_active: model.autoplay,
                                        connect_active_notify[sender] => move |s| {
                                            sender.input(SceneMsg::AutoplayToggled(s.is_active()));
                                        },
                                    },
                                },

                                gtk::Button {
                                    add_css_class: "flat",
                                    set_label: "Open in Stash",
                                    #[watch]
                                    set_sensitive: matches!(model.state, State::Loaded(_)),
                                    connect_clicked => SceneMsg::OpenInBrowser,
                                },
                            },
                        },
                    },
                },
```

The new content — an `OverlaySplitView` wrapping the stack, with the metadata drawer as its sidebar:

```rust
                #[wrap(Some)]
                #[name = "split_view"]
                set_content = &adw::OverlaySplitView {
                    // Pinned collapsed on purpose, never bound to a
                    // breakpoint: an overlaying sidebar can't reallocate
                    // the player, which is what kept the video area
                    // shrinking on every scene change.
                    set_collapsed: true,
                    set_sidebar_position: gtk::PackType::End,
                    set_max_sidebar_width: 360.0,
                    set_show_sidebar: false,
                    // gir renames boolean getters, so the accessor for
                    // the `show-sidebar` property is `shows_sidebar()` —
                    // if the compiler disagrees it will be
                    // `is_show_sidebar()`. Take whichever it accepts;
                    // both read the same property.
                    connect_show_sidebar_notify[sender] => move |v| {
                        sender.input(SceneMsg::SetDrawerShown(v.shows_sidebar()));
                    },

                    #[wrap(Some)]
                    set_sidebar = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,

                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                            set_spacing: 24,
                            set_margin_top: 24,
                            set_margin_bottom: 24,
                            set_margin_start: 18,
                            set_margin_end: 18,

                            #[name = "performers_section"]
                            gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_spacing: 10,
                                set_visible: false,

                                gtk::Label {
                                    set_label: "Performers",
                                    set_xalign: 0.0,
                                    add_css_class: "heading",
                                },

                                #[name = "performers_box"]
                                gtk::Box {
                                    set_orientation: gtk::Orientation::Vertical,
                                    set_spacing: 8,
                                },
                            },

                            #[name = "details_section"]
                            gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_spacing: 8,
                                set_visible: false,

                                gtk::Label {
                                    set_label: "About",
                                    set_xalign: 0.0,
                                    add_css_class: "heading",
                                },

                                #[name = "details_label"]
                                gtk::Label {
                                    set_xalign: 0.0,
                                    set_wrap: true,
                                    set_wrap_mode: gtk::pango::WrapMode::WordChar,
                                    set_selectable: true,
                                },
                            },

                            #[name = "file_section"]
                            gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_visible: false,
                            },
                        },
                    },

                    #[wrap(Some)]
                    set_content = &gtk::Stack {
                        set_transition_type: gtk::StackTransitionType::Crossfade,

                        // ... the loading / missing / error pages, unchanged ...

                        // The player goes straight in — no ScrolledWindow,
                        // no Overlay, nothing that would size it from its
                        // content instead of from the window.
                        #[name = "player_slot"]
                        add_named[Some("loaded")] = &gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                        },

                        #[watch]
                        set_visible_child_name: model.stack_name(),
                    },
                },
```

The performers box changes from horizontal to vertical because the drawer is narrow; drop the `ScrolledWindow` that wrapped it.

- [ ] **Step 2: Install the player into the slot**

In `init`, replace:

```rust
        widgets
            .video_overlay
            .set_child(Some(model.player.widget()));
```

with:

```rust
        widgets.player_slot.append(model.player.widget());
```

- [ ] **Step 3: Add the drawer messages**

To `enum SceneMsg`:

```rust
    /// Show or hide the metadata drawer. Kept in sync in both
    /// directions — the split view can close itself on an outside click.
    SetDrawerShown(bool),
```

Add to `struct ScenePage`:

```rust
    /// Whether the metadata drawer is open. Mirrored onto the split view
    /// and the header toggle.
    drawer_shown: bool,
```

with `drawer_shown: false` in the model literal in `init`.

In `update_with_view`'s match:

```rust
            SceneMsg::SetDrawerShown(shown) => {
                // Guard the round trip: the split view and the toggle
                // each notify us when we set the other.
                if self.drawer_shown != shown {
                    self.drawer_shown = shown;
                }
                if widgets.split_view.shows_sidebar() != shown {
                    widgets.split_view.set_show_sidebar(shown);
                }
                if widgets.drawer_button.is_active() != shown {
                    widgets.drawer_button.set_active(shown);
                }
                if shown {
                    // Keep the header up while the drawer is open, or the
                    // toggle that closes it fades away.
                    widgets.toolbar_view.set_reveal_top_bars(true);
                }
            }
```

Change the existing `SetHeaderRevealed` arm so the drawer wins:

```rust
            SceneMsg::SetHeaderRevealed(on) => {
                widgets
                    .toolbar_view
                    .set_reveal_top_bars(on || self.drawer_shown);
            }
```

- [ ] **Step 4: Close the drawer on fullscreen**

The player reparents its root into a transient borderless window in fullscreen, leaving `player_slot` empty, so an open drawer would hover over nothing. Add to `enum VideoPlayerOutput` in `widgets/video_player/mod.rs`:

```rust
    /// Fullscreen was entered (true) or left (false).
    FullscreenChanged(bool),
```

Emit it at the end of both `handle_toggle_fullscreen` and `handle_exit_fullscreen`:

```rust
        let _ = sender.output(VideoPlayerOutput::FullscreenChanged(self.is_fullscreen));
```

`handle_exit_fullscreen` currently takes only `widgets`; give it a `sender: &ComponentSender<Self>` parameter and update its call site in `update_with_view`.

Map it in `pages/scene/mod.rs`'s `.forward(...)`:

```rust
                VideoPlayerOutput::FullscreenChanged(on) => SceneMsg::FullscreenChanged(on),
```

with a new arm:

```rust
            SceneMsg::FullscreenChanged(on) => {
                if on {
                    sender.input(SceneMsg::SetDrawerShown(false));
                }
            }
```

and the matching `SceneMsg` variant:

```rust
    /// The player entered (true) or left (false) fullscreen.
    FullscreenChanged(bool),
```

- [ ] **Step 5: Update the player's own sizing**

In `widgets/video_player/mod.rs`'s `view!`, change the `picture`:

```rust
                    #[name = "picture"]
                    set_child = &gtk::Picture {
                        set_hexpand: true,
                        set_vexpand: true,
                        // Just a floor against degenerate allocations —
                        // the real height comes from the window now that
                        // nothing above us is a ScrolledWindow.
                        set_height_request: 200,
                        set_content_fit: gtk::ContentFit::Contain,
                        add_css_class: "video-surface",
                    },
```

- [ ] **Step 6: Point `populate_scene` at the new widgets**

In `metadata.rs`, replace the title/subtitle/rating block of `populate_scene`:

```rust
pub(super) fn populate_scene(widgets: &ScenePageWidgets, scene: &Scene) {
    widgets.window_title.set_title(&scene.display_title());
    widgets.window_title.set_subtitle(&subtitle_text(scene));

    populate_performers(&widgets.performers_box, &scene.performers);
    widgets
        .performers_section
        .set_visible(!scene.performers.is_empty());

    let details = scene.details.as_deref().unwrap_or("").trim();
    widgets.details_label.set_label(details);
    widgets.details_section.set_visible(!details.is_empty());

    populate_file_group(&widgets.file_section, scene.files.first());
}
```

Delete `pub(super) fn update_o_widgets` — the OSD renders the count now. Remove its import from `mod.rs` and its call site in the `SceneCmd::OUpdated` arm (which already calls `push_scene_actions` via the shared tail added in Task 6).

- [ ] **Step 7: Adjust the header CSS**

The header now floats over a full-bleed video rather than over a video with a metadata page beneath. Check `.scene-headerbar` in `styles.css` still reads correctly against a bright frame; if the title is hard to read, add to the existing rule:

```css
.scene-headerbar windowtitle label {
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.7);
}
```

- [ ] **Step 8: Build**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

The compiler will flag the deleted `title_label`, `subtitle_label`, `rating_badge`, `o_count_label`, `o_reset_btn`, `video_overlay`, and `file_group` widget references. Remove each.

Expected: clean.

- [ ] **Step 9: Verify the shrink is actually gone**

Add a temporary instrumentation line at the end of `refresh_widgets` in `widgets/video_player/mod.rs`:

```rust
        tracing::debug!(height = widgets.picture.height(), "video allocation");
```

```sh
RUST_LOG=info,stash_player_ui=debug cargo run -p stash-player-ui 2>&1 | grep "video allocation"
```

At each of three window sizes (restored ~1280×720, maximised, and one intermediate drag), navigate five scenes with the OSD next button. The logged height must be constant within each window size and must change only when the window is resized. Then:

1. Open and close the drawer five times. The height must not change at all.
2. Enter fullscreen with `f`, exit with `Esc`. The drawer must be closed on entry; the height must return to its pre-fullscreen value.
3. Confirm the drawer's Performers / About / File sections populate and that File still shows at most three rows after five navigations.

Remove the instrumentation line once confirmed.

- [ ] **Step 10: Commit**

```bash
git add crates/stash-player-ui/src/pages/scene/ crates/stash-player-ui/src/widgets/video_player/ crates/stash-player-ui/src/styles.css
git commit -m "fix(ui): size the video by the window, not by its content

The player sat inside a ScrolledWindow, so its height came from content
natural size and drifted smaller with each scene change. It now goes
straight into the content area of an AdwOverlaySplitView pinned to
collapsed, so the metadata drawer overlays the video instead of
reallocating it."
```

---

### Task 8: Navigate without swapping the stack

**Files:**
- Modify: `crates/stash-player-ui/src/pages/scene/mod.rs`
- Modify: `crates/stash-player-ui/src/widgets/video_player/mod.rs`

**Interfaces:**
- Consumes: everything from Task 7.
- Produces: `VideoPlayerMsg::SetUrl` gains a third field, `show_loading: bool`. All three existing call sites must pass it.

**Background for the implementer.** `start_navigate` sets `state = State::Loading`, which crossfades the whole player out of the stack and back in on every prev/next — remapping a `GraphicsOffload`-wrapped paintable each time. Keeping the player mapped is both smoother and one less way for the allocation to drift.

- [ ] **Step 1: Give `SetUrl` a loading flag**

In `widgets/video_player/mod.rs`, change the variant:

```rust
    /// Load a new stream URI. Pass `url: None` to clear. `resume_secs`
    /// is applied once the new stream reports a duration, then dropped.
    /// `show_loading` keeps the status plate up while cleared, so a
    /// scene swap shows a spinner rather than an empty surface.
    SetUrl {
        url: Option<String>,
        resume_secs: Option<f64>,
        show_loading: bool,
    },
```

Add to `struct VideoPlayer`:

```rust
    /// Force the status plate on while no stream is loaded — set during
    /// a scene swap so the player doesn't flash an empty rectangle.
    show_loading: bool,
```

with `show_loading: false` in `new_model`'s literal.

In `handle_set_url`, take and store the flag, and drive the plate when clearing:

```rust
        self.show_loading = show_loading;
```

placed alongside the other field resets, and in both early-return branches (the `let Some(url) = url else` and the `let Some(pipeline) = ... else`) replace the bare `return` with:

```rust
            widgets.picture.set_paintable(gtk::gdk::Paintable::NONE);
            update_status_plate(widgets, None, !self.show_loading);
            return;
```

`update_status_plate`'s second condition is `!is_prepared`, so passing `!self.show_loading` raises the "Loading video…" plate exactly when we want it.

In `handle_tick`'s early return, keep the plate honest while no media exists:

```rust
        let Some(media) = self.media.as_ref() else {
            update_status_plate(widgets, None, !self.show_loading);
            return;
        };
```

Update the `SetUrl` destructuring in `update_with_view` to bind the new field and pass it through.

Update the one internal call site, in `init`:

```rust
            sender.input(VideoPlayerMsg::SetUrl {
                url: Some(url),
                resume_secs: init.resume_secs,
                show_loading: false,
            });
```

- [ ] **Step 2: Add the `navigating` flag**

In `pages/scene/mod.rs`, add to `struct ScenePage`:

```rust
    /// True between starting a prev/next fetch and its result landing.
    /// Keeps the stack on the player instead of crossfading it out.
    navigating: bool,
```

with `navigating: false` in the model literal.

- [ ] **Step 3: Rewrite `start_navigate`**

```rust
    fn start_navigate(
        &mut self,
        _widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        direction: NavDirection,
    ) {
        let Some(ctx) = self.context.as_ref() else {
            return;
        };
        if self.navigating {
            return;
        }
        let target_index = match direction {
            NavDirection::Prev => {
                if ctx.index == 0 {
                    return;
                }
                ctx.index - 1
            }
            NavDirection::Next => {
                if ctx.total >= 0 && (ctx.index as i64) + 1 >= ctx.total {
                    return;
                }
                ctx.index + 1
            }
        };

        // Stop the outgoing stream (this also flushes its activity) but
        // keep the player mapped and show its own spinner. Swapping the
        // whole stack out would remap the paintable widget on every
        // navigation.
        self.player.emit(VideoPlayerMsg::SetUrl {
            url: None,
            resume_secs: None,
            show_loading: true,
        });

        // Only hold the player on screen if there's one to hold. From
        // any other state there's nothing loaded, so fall back to the
        // full-page spinner.
        if matches!(self.state, State::Loaded(_)) {
            self.navigating = true;
        } else {
            self.state = State::Loading;
        }

        let client = self.client.clone();
        let filter = ctx.filter.clone();
        sender.oneshot_command(async move {
            // Stash pages are 1-indexed; per_page=1 means we read exactly the
            // scene at `target_index` from the same filter ordering the user
            // is browsing (including a stable `random_<seed>` for shuffle).
            let page = target_index + 1;
            let result = client
                .find_scenes(&filter, page, 1)
                .await
                .map(|p| p.scenes.into_iter().next())
                .map_err(|e| e.to_string());
            SceneCmd::Neighbor {
                direction,
                target_index,
                result: Box::new(result),
            }
        });
    }
```

- [ ] **Step 4: Clear the flag and honour it**

At the top of the `SceneCmd::Neighbor` arm in `update_cmd_with_view`, before the `match *result`:

```rust
            SceneCmd::Neighbor { direction, target_index, result } => {
                // Cleared before applying, so a failed navigation still
                // reaches the error or missing page.
                self.navigating = false;
                match *result {
```

(close the extra brace at the end of the arm).

Update the two `SetUrl` emissions inside `update_cmd_with_view` to pass `show_loading: false`.

Change `stack_name`:

```rust
    fn stack_name(&self) -> &'static str {
        if self.navigating {
            // Keep the player on screen and let it show its own spinner.
            return "loaded";
        }
        match &self.state {
            State::Loading => "loading",
            State::Loaded(_) => "loaded",
            State::NotFound => "missing",
            State::Failed(_) => "error",
        }
    }
```

Change both navigation guards so a second press can't queue behind the first:

```rust
    fn can_go_prev(&self) -> bool {
        !self.navigating
            && matches!(&self.state, State::Loaded(_) | State::NotFound | State::Failed(_))
            && self.context.as_ref().map(|c| c.index > 0).unwrap_or(false)
    }

    fn can_go_next(&self) -> bool {
        !self.navigating
            && matches!(&self.state, State::Loaded(_) | State::NotFound | State::Failed(_))
            && self
                .context
                .as_ref()
                .map(|c| c.total < 0 || (c.index as i64) + 1 < c.total)
                .unwrap_or(false)
    }
```

- [ ] **Step 5: Build**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: clean. The compiler will flag any `SetUrl` call site still missing `show_loading`.

- [ ] **Step 6: Verify by hand**

```sh
cargo run -p stash-player-ui
```

1. Open a scene from the library and press the OSD next button. The player must stay on screen with a spinner over it — no full-page crossfade, no white flash.
2. The prev/next buttons must grey out for the duration of the fetch and come back when the new scene lands.
3. Navigate to a scene id that doesn't exist (temporarily filter to a set of 3 and press next four times). The "Scene not found" page must still appear.
4. The video area must not change size across ten navigations.

- [ ] **Step 7: Commit**

```bash
git add crates/stash-player-ui/src/pages/scene/ crates/stash-player-ui/src/widgets/video_player/
git commit -m "fix(ui): keep the player mapped while navigating scenes

start_navigate swapped the whole stack to a loading page on every
prev/next, remapping the GraphicsOffload-wrapped paintable each time.
Hold the player on screen and use its own status plate instead."
```

---

### Task 9: Documentation and final verification

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `PLAN.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Find every stale description**

```sh
grep -n "metadata\|performer chips\|O-counter\|action cluster\|MediaFile\|Right-side" CLAUDE.md README.md PLAN.md
```

- [ ] **Step 2: Update `CLAUDE.md`**

In the "UI component layout" section, replace the `pages/scene.rs` bullet:

```markdown
- `pages/scene/` — video-first scene page. `mod.rs` owns the component:
  the player fills the content area of an `adw::OverlaySplitView` pinned
  to `collapsed: true`, so the metadata drawer (performers, about, file
  info) overlays the video rather than reallocating it. Title and
  subtitle live in the header's `adw::WindowTitle`; autoplay and "Open in
  Stash" in its `⋯` menu; prev/next, the O-counter, and the rating are
  rendered by the player OSD and round-trip through a single
  `SetSceneActions` / `SceneAction` message pair so the player stays
  ignorant of what they mean. `metadata.rs` holds the `populate_*`
  helpers — all of which **clear before building**, since appending to a
  persistent container is what made the File rows accumulate across
  navigations. Prev/next set a `navigating` flag rather than swapping the
  stack, so the paintable widget is never remapped mid-browse.
```

Extend the `widgets/video_player.rs` bullet:

```markdown
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
```

Extend the `pages/library.rs` bullet's infinite-scroll clause:

```markdown
  Pagination re-checks the scroll adjustment after every page lands and on
  every scroll, 48 scenes per fetch — an `edge-reached` trigger alone
  stalls on a large monitor, where the first page never overflows the
  viewport and so nothing ever scrolls.
```

Add to the `stash-player-core` bullet:

```markdown
  `playback` holds `SeekTracker`, the pure position model shared by the
  UI's player (and available to the macOS app if its seek handling ever
  needs the same treatment).
```

- [ ] **Step 3: Update `README.md`**

Find any description of the scene page showing metadata below the player and rewrite it for the drawer layout. Add the two new OSD controls to the keyboard/controls table if it enumerates OSD buttons.

- [ ] **Step 4: Update `PLAN.md`**

`PLAN.md` still records `gtk::MediaFile` as the video pipeline in its "Decisions locked in" table and its rationale paragraphs, which has been untrue since the move to `playbin3`. Correct the table row to `hand-built playbin3 + gtk4paintablesink` and replace the `gtk::MediaFile` rationale bullet with one sentence saying the manual pipeline was needed for sink selection and seek control. Update any milestone entry describing the scene page layout.

- [ ] **Step 5: Run the full gate**

```sh
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p stash-api -p stash-player-core
```

Expected: clean, all tests pass.

- [ ] **Step 6: Full manual pass**

```sh
RUST_LOG=info,stash_player_ui=debug cargo run -p stash-player-ui
```

Against a dev Stash with real video (`tools/mock-stash/` 404s on `/stream`, so use the Docker or devenv backend):

1. Large monitor, maximised: the library loads past 48 and keeps loading through to the end of the result set.
2. Navigate five scenes with the OSD next button: the File section shows at most three rows.
3. Video area stays the same size across five navigations at three window sizes.
4. Rapid `l` ×5 on a 4K H.265 scene: the playhead advances monotonically; the slider never snaps back.
5. Drawer opens and closes without the video moving; OSD prev/next and O-counter increment/reset work; `f` enters fullscreen with the drawer closed and `Esc` restores cleanly.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md README.md PLAN.md
git commit -m "docs: describe the video-first scene page and seek tracker"
```

---

## Notes for the reviewer

- Tasks 1–4 each fix or enable something on their own and can be reviewed independently. Tasks 6–8 build on Task 5's module split and on each other.
- Task 6 deliberately leaves the old action cluster in the metadata pane in place; Task 7 removes it. Between those two tasks the app has duplicate controls, both functional. That is expected, not an oversight.
- The one place where correctness is not provable from the diff is defect 4. Task 7 Step 9 is the evidence, and it must actually be run — the layout change is well-motivated but the original accumulation mechanism was never isolated.
