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
