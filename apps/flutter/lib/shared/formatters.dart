// Pure formatting helpers shared across the UI. No widgets, no I/O — see
// `lib/shared/`'s own scope note in `CLAUDE.md`.

/// Formats [totalSeconds] as a clock-style duration label: `m:ss` under an
/// hour, `h:mm:ss` at or above one hour (hours themselves are never
/// zero-padded, matching how a video player's own transport typically
/// reads). Fractional seconds are rounded to the nearest whole second
/// before formatting, so e.g. `59.6` reads as `1:00` rather than `0:59`
/// (or `0:59.6`, which this label format has no room for).
String formatDuration(double totalSeconds) {
  final rounded = totalSeconds.round().clamp(0, 1 << 31);
  final hours = rounded ~/ 3600;
  final minutes = (rounded % 3600) ~/ 60;
  final seconds = rounded % 60;
  final secondsLabel = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final minutesLabel = minutes.toString().padLeft(2, '0');
    return '$hours:$minutesLabel:$secondsLabel';
  }
  return '$minutes:$secondsLabel';
}

/// Formats a Stash `rating100` value (0-100, 20 points per "star" — see
/// the GTK client's own `pages/library.rs`) as a 0.0-5.0 star rating with
/// one decimal place.
String formatRating(int rating100) => (rating100 / 20).toStringAsFixed(1);
