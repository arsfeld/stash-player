# Linux player fixes: video-first scene page, seek correctness, pagination

Design spec — 2026-08-26

## Scope

Four defects in the Linux (GTK/relm4) frontend, plus the video-first
restructuring of the scene page that two of them motivate.

macOS is out of scope. Its player is AVKit and its metadata pane is
declarative SwiftUI, so none of these bugs reproduce there.

| # | Symptom | Root cause | Fix lands in |
|---|---|---|---|
| 1 | Grid stops at 24 scenes; scrolling loads nothing | `LoadMore` fires only from `connect_edge_reached`, which never fires when content doesn't overflow the viewport | `pages/library.rs` |
| 2 | Metadata shows duplicated rows during playback | `populate_file_group` calls `group.add()` without clearing; every prev/next appends 3 more rows | `pages/scene/metadata.rs` |
| 3 | Seek re-lands in the same place instead of skipping | A stale 4 Hz poll clobbers `position_us` once the 400 ms hold expires; the next relative seek anchors on that stale value | `stash-player-core::playback` + `widgets/video_player/` |
| 4 | Video area shrinks with each scene change | The player sits inside a `ScrolledWindow`, so its height comes from content natural size rather than the window | `pages/scene/mod.rs` |

Defect 1's report was confirmed as pagination only — the scenes shown are
correct for the active filter, the grid simply stops growing. No filter
work is in scope.

## Scene page architecture

The video becomes a direct child of the content area, with no scrolling
ancestor anywhere above it.

```
adw::NavigationPage
└── adw::ToolbarView              extend_content_to_top_edge, flat
    ├── adw::HeaderBar            .scene-headerbar (fades with the OSD)
    │     title:  adw::WindowTitle { title, subtitle }
    │     end:    [ⓘ ToggleButton]  [⋯ MenuButton → Autoplay ▸ / Open in Stash]
    └── adw::OverlaySplitView
          collapsed: true (always)   sidebar_position: End
          show_sidebar: ⇄ ⓘ toggle   max_sidebar_width: 360
          ├── content: gtk::Stack [loading | missing | error | loaded]
          │              loaded → the VideoPlayer root widget, directly
          └── sidebar: gtk::ScrolledWindow → gtk::Box
                         Performers · About · File
```

`adw::OverlaySplitView` requires libadwaita 1.4; the crate is pinned at
`libadwaita 0.9.1` with the `v1_5` feature, so it is available.

Three properties do the work:

**`OverlaySplitView` pinned to `collapsed: true`.** The drawer overlays
the content rather than resizing it, so opening or closing it never
reallocates the player. This is a deliberate constant, not a responsive
breakpoint — `collapsed` is never bound to width.

**No `ScrolledWindow` above the player.** `gtk::Picture` keeps `vexpand`
and `ContentFit::Contain`. `set_height_request: 540` drops to a floor of
200; it existed only to give the scroller something to measure. The
`gtk::Overlay` that carried the rating badge is removed — rating moves to
the OSD.

**Navigation no longer swaps the Stack.** Today `start_navigate` sets
`state = State::Loading`, which crossfades the player out and back on
every prev/next, remapping a `GraphicsOffload`-wrapped paintable widget
each time. A `navigating: bool` field replaces that. This is smoother and
removes the second candidate mechanism for defect 4.

Precisely:

- `start_navigate` sets `self.navigating = true` and leaves `self.state`
  untouched. It only does this when `self.state` is already
  `State::Loaded`; from any other state it falls back to today's
  behaviour and sets `State::Loading`, since there is no player to keep
  on screen.
- `stack_name()` returns `"loaded"` while `self.navigating` is true,
  regardless of `self.state`.
- The arriving `SceneCmd::Neighbor` clears the flag before applying its
  result, so a failed navigation still lands on the `error` or `missing`
  page.
- `can_go_prev()` and `can_go_next()` return `false` while `navigating`
  is true, so the OSD's prev/next controls disable for the duration
  rather than queueing a second navigation.

The header title continues to show the outgoing scene until the new one
lands — the title is derived from `self.state`, which navigation no
longer disturbs.

`start_navigate` already emits `VideoPlayerMsg::SetUrl { url: None }` to
stop audio before the swap. Today that path sets the paintable to `NONE`
and returns early, leaving no visible feedback. It gains a
`show_loading: bool` field so the player raises its existing status plate
("Loading video…") for the duration of the navigation instead of showing
an empty surface.

### Interaction rules

- Entering fullscreen closes the drawer. The player reparents into a
  transient borderless window, so an open drawer would hover over an
  empty Stack.
- The header stays revealed while the drawer is open, so the ⓘ toggle
  remains reachable. `SetHeaderRevealed(false)` is ignored while
  `show_sidebar` is true.

### On defect 4

The class of cause is confirmed: the player's height derives from content
natural size, not from the window. The exact accumulation step — which of
the two candidate mechanisms compounds per navigation — is not yet
isolated.

This layout removes both candidates structurally. The implementation plan
includes a repro run that logs the player widget's allocated height across
five navigations at three window sizes, to confirm the shrink is gone
rather than merely masked.

## OSD scene actions

Hot actions move into the player OSD; cold ones into the header menu.

```
┌──────────────────────────────────────────────────────┐
│ ▬▬▬▬▬▬▬▬▬●──────────────────  12:34 / 45:00          │
│ ⏮ ⏵ ⏭   ⏪ ⏩      ⊙3 ↺   ★4.5      🔊▬▬▬    ⛶    │
└──────────────────────────────────────────────────────┘
```

Header `⋯` menu: Autoplay (toggle), Open in Stash.

The risk is turning `VideoPlayer` into a god-widget that knows what an
O-counter is. One narrow message each way prevents it:

```rust
// ScenePage → VideoPlayer
VideoPlayerMsg::SetSceneActions(SceneActionState)

pub(crate) struct SceneActionState {
    pub can_prev: bool,
    pub can_next: bool,
    pub o_count: i32,
    pub rating100: Option<i32>,
}

// VideoPlayer → ScenePage
VideoPlayerOutput::SceneAction(SceneAction)

pub(crate) enum SceneAction { Prev, Next, IncrementO, ResetO }
```

`VideoPlayer` renders four labelled controls and forwards clicks. It never
learns what they mean and never touches `stash_api`. `ScenePage` keeps
sole ownership of the mutations it already performs. Rating stays
display-only, as today.

`SceneActionState` groups the four fields into one record rather than
adding four separate messages, keeping `VideoPlayerMsg` from growing a
cluster of near-identical variants.

## Seek correctness

### Why it fails today

Position tracking is time-based. Two 400 ms `Instant` windows —
`update_position_from_poll` and `refresh_widgets` — decide whether to
trust a polled position. When a seek takes longer than 400 ms, which
`ACCURATE` on 4K/H.265 over HTTP routinely does, the window expires
mid-seek. The 4 Hz poll then reports the pre-seek keyframe, `position_us`
snaps backward, and the next relative seek computes its target from that
stale base — landing in the same place again, indefinitely.

The `ACCURATE` flag and the 400 ms window are both prior attempts to
paper over this.

### The replacement

Trust a polled position only when it is *consistent with what was
requested*. Value-based, not time-based.

New unit: `stash-player-core::playback::SeekTracker`. Pure arithmetic
over `i64` microseconds, no GStreamer types. It lives in core rather than
the UI crate because CI already runs `cargo test -p stash-player-core`,
and the UI crate has no tests by design.

```rust
pub fn position_us(&self) -> i64;
pub fn duration_us(&self) -> i64;
pub fn set_duration_us(&mut self, duration_us: i64);
pub fn seek_relative(&mut self, delta_us: i64) -> i64;   // → target for GStreamer
pub fn seek_absolute(&mut self, target_us: i64) -> i64;
pub fn on_poll(&mut self, polled_us: i64);
pub fn on_async_done(&mut self, landed_us: i64);
pub fn on_stream_reset(&mut self);
```

Acceptance rule, with a pending seek to `target`:

| Condition | Action |
|---|---|
| No pending seek | Accept the polled value |
| `polled >= target - TOLERANCE` | Accept — landed, or playing forward from the landing |
| `polled < target - TOLERANCE` | Ignore — stale pre-seek value, or a superseded seek's leftovers |
| Pending older than `PENDING_TIMEOUT` | Force-adopt the polled value |

`TOLERANCE` is 500 ms; `PENDING_TIMEOUT` is 5 s. The timeout exists so a
seek that never reports `ASYNC_DONE` cannot freeze the playhead
permanently.

Time enters only through the timeout. `SeekTracker` takes the current
instant as a parameter on the methods that need it rather than reading
the clock itself, so tests drive it deterministically.

Relative seeks anchor on `position_us()`, which equals the last requested
target while a seek is pending. Rapid `+10s` presses therefore compose
correctly by construction, with no special case — the composition is a
consequence of the acceptance rule, not separate logic.

### Superseded seeks

`ASYNC_DONE` carries no seek identity from GStreamer. `on_async_done`
applies the same tolerance test: a landing consistent with the current
pending target confirms and clears it; anything else is attributed to a
superseded seek, dropped, and the tracker keeps waiting. This gives
supersede handling without needing GStreamer to say which seek finished.

### Flags and issue policy

Seek flags stay `FLUSH | KEY_UNIT | SNAP_BEFORE | ACCURATE`. Exact
positioning was chosen over keyframe-snapping speed.

Seeks continue to be issued immediately rather than queued behind the one
in flight. `FLUSH` cancels the in-flight seek, so exactness is preserved
with no added latency. Serializing them would have made rapid presses wait
out each 200–1500 ms decode chase.

### Widget-side changes

Both 400 ms `Instant` windows are deleted. `VideoPlayer` holds a
`SeekTracker` and renders `tracker.position_us()` unconditionally, since
that value never regresses spuriously.

The seek slider gets an explicit `dragging` flag driven by a
`gtk::GestureClick` (`connect_pressed` / `connect_released`) on the scale.
Programmatic value pushes are skipped only while a pointer is actually
down. The existing `suppress_scale` flag stays for its original purpose —
preventing our own `set_value` from re-entering as a `UserSeek`.

### Tests

Unit tests in `stash-player-core`:

- Rapid relative seeks compose (three `+10s` from 12:34 target 13:04)
- Stale poll during a pending seek is ignored
- Poll consistent with the pending target is accepted and clears it
- Poll ahead of the target (forward playback) is accepted
- `ASYNC_DONE` inconsistent with the current target is dropped, pending survives
- `ASYNC_DONE` consistent with the target confirms and resyncs
- Pending older than `PENDING_TIMEOUT` force-adopts the next poll
- Targets clamp to `[0, duration_us]` at both ends
- `on_stream_reset` clears pending, position, and duration

## Library pagination

Two triggers replace the single edge trigger.

```
after each page lands, via glib::idle_add_local_once so layout has run:
    upper <= page_size + 1.0                       → content doesn't overflow → fetch next

on vadjustment value-changed:
    upper - value - page_size < page_size * 1.5    → within the prefetch zone → fetch next
```

Both read `scroller.vadjustment()`, where `page_size` is the viewport
height and `upper` is the content height. The `idle_add_local_once` hop
is required: immediately after appending cells the adjustment still holds
pre-layout values.

`connect_edge_reached` is removed, superseded by the value-changed
threshold.

### Loop safety

The fill loop is self-limiting — each pass is driven by a *completed*
fetch, and `LoadMore` already guards on `!self.loading`. Two additional
stops guard against a server reporting an inflated `count`:

- `exhausted` is set when a page returns fewer than `PAGE_SIZE` scenes.
- `exhausted` is set when a page returns zero scenes.

`LoadMore` returns early when `exhausted` is set. `reset()` clears it.

### Constants

`PAGE_SIZE` 24 → 48. `MAX_PARALLEL_THUMBS` stays at 12; larger pages
deepen the queue behind the same semaphore rather than widening it.

The threshold arithmetic lives as a private pure function in
`library.rs`. It is three lines and is verified by the manual pass —
consistent with the UI crate having no tests by design.

## Metadata population

All three `populate_*` helpers adopt one convention: **clear, then
build**.

`populate_performers` already does this. `populate_file_group` changes to
match: it takes the containing `gtk::Box`, empties it with the same
`while let Some(child) = container.first_child()` loop, then appends a
freshly constructed `adw::PreferencesGroup`.

No row tracking and no leak. More importantly, the three helpers now have
the same shape, which is what keeps the bug from recurring in the next
one added.

The view declares `#[name = "file_section"] gtk::Box` where it previously
declared the `PreferencesGroup` directly.

## File structure

Both touched files are past the size where the workspace lints bite and
edits get unreliable, and this work adds to both. Targeted splits only:

```
widgets/video_player.rs  (1673)  →  widgets/video_player/mod.rs
                                    widgets/video_player/pipeline.rs

pages/scene.rs           (907)   →  pages/scene/mod.rs
                                    pages/scene/metadata.rs

crates/stash-player-core/src/playback.rs   (new)
```

`pipeline.rs` takes `PlaybackPipeline`, its bus watch, `PipelineFlags`,
and `make_element` — a clean lift with no view macro involved.
`metadata.rs` takes the `populate_*` and formatting helpers.

The relm4 `view!` macro stays in `mod.rs` in both cases. If the enlarged
OSD trips `too_many_lines` (100/fn), the fix is
`#[relm4::widget_template]` for the control row, not an `#[allow]` — the
workspace forbids allow-exceptions.

`pages/library.rs` (1359) is left structurally alone. The pagination
change is roughly 40 lines and splitting the file is not in service of
this work.

## Verification

```sh
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p stash-api -p stash-player-core     # covers SeekTracker
```

Manual pass against a dev Stash (`tools/mock-stash/` has no working
`/stream`, so playback checks need the Docker or devenv backend). The UI
crate has no automated tests, so these are the real gate:

1. Large monitor: library opens, loads past 48, and keeps loading on
   scroll through to the end of the result set.
2. Navigate 5 scenes via ⏭: the File section shows exactly 3 rows, not 15.
3. Player allocated height logged across 5 navigations × 3 window sizes:
   constant.
4. Rapid ⏩ ×5 on a 4K H.265 scene: playhead advances monotonically, the
   slider never snaps backward.
5. Drawer opens and closes without the video moving; OSD actions
   (prev/next, O-counter increment and reset) work; fullscreen closes the
   drawer and restores cleanly on exit.

## Documentation

`CLAUDE.md` and `README.md` both describe the current scene page layout
and the metadata-below-player arrangement. Both need updating in lockstep
with this change, along with `PLAN.md` if it records the same structure.
