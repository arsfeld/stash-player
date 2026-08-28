/// A [DateTime] source a test advances explicitly, standing in for the
/// `DateTime Function()` `ActivitySync` (and anything else timing-sensitive)
/// accepts. Never reads the real wall clock, so a test can simulate any
/// span of elapsed time instantly — 10 seconds of "active playback" costs
/// nothing in real test run time.
class FakeClock {
  FakeClock([DateTime? initial]) : _now = initial ?? DateTime(2024);

  DateTime _now;

  DateTime now() => _now;

  /// Advances the clock by [duration]. [duration] must not be negative —
  /// a real clock never runs backwards, and nothing in `ActivitySync`'s
  /// accounting is meant to tolerate it.
  void advance(Duration duration) {
    assert(
      !duration.isNegative,
      'FakeClock cannot advance by a negative duration',
    );
    _now = _now.add(duration);
  }
}

/// Stands in for `ActivitySync`'s injected `Future<void> Function(Duration)`
/// retry delay: records every duration it was asked to wait, in order, and
/// completes immediately rather than actually waiting — so a test can
/// assert the exact retry schedule (`[1s, 2s, 4s]`) without real time
/// passing.
class RecordingDelay {
  final List<Duration> requested = [];

  Future<void> call(Duration duration) async {
    requested.add(duration);
  }
}
