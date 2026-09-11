import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/job.dart';
import '../../services/stash_api.dart';

/// How long [TasksController] waits between job queue fetches while it has
/// a reason to keep watching.
const Duration tasksPollInterval = Duration(seconds: 2);

/// How long the row saying how this app's scan ended stays listed.
const Duration scanEndedRowDuration = Duration(seconds: 3);

/// Failed fetches in a row after which [TasksController] stops trusting
/// what it last saw.
const int maxConsecutiveFetchFailures = 3;

/// Id of the one row [TasksController] lists itself: this app's scan
/// before Stash has listed it, and after it has ended. Stash's own job ids
/// are numeric, so this cannot collide with one.
const String localScanRowId = 'local-scan';

/// How a scan this app started came to an end.
enum ScanOutcome { completed, failed, cancelled }

/// Watches Stash's job queue for the library's Tasks button and popover,
/// and follows the one scan this app may have started.
///
/// **When it fetches.** Once per [refresh] (the library calls it on load),
/// once per [popoverOpened], and then every [tasksPollInterval] for as
/// long as the popover is open, this app's scan has not ended, or the last
/// fetch listed an active job. Nothing else keeps it polling, so an idle
/// library costs one request per load. The next poll is armed only after
/// the previous fetch returns, and a fetch asked for while one is in
/// flight runs once that one returns, so a slow server never sees
/// overlapping requests.
///
/// **Following a scan.** [startScan] follows the job id `metadataScan`
/// hands back rather than inferring the end from an empty queue. That is
/// what lets a scan queued behind someone else's job end when its own job
/// ends, not when the whole queue drains. Only a fetch started after the
/// id is known may judge it: a snapshot asked for before the job existed
/// would otherwise read as the job having already finished. The scan has
/// ended once its id is gone from the queue or reaches a status that is
/// not active; the `onScanEnded` callback then fires once, and a row
/// saying how it ended is listed for [scanEndedRowDuration].
///
/// **Failed fetches.** A failed fetch keeps the last known jobs. After
/// [maxConsecutiveFetchFailures] in a row they are too old to act on: the
/// controller forgets them and stops following its scan, which is what
/// stops a dead server from holding it in a polling loop. An open popover
/// still polls, because someone is looking at it.
class TasksController extends ChangeNotifier {
  TasksController({
    required StashApi api,
    required void Function(ScanOutcome outcome) onScanEnded,
  }) : _api = api,
       _onScanEnded = onScanEnded;

  final StashApi _api;
  final void Function(ScanOutcome outcome) _onScanEnded;

  List<Job> _jobs = const [];
  _Scan _scan = const _ScanIdle();
  bool _popoverOpen = false;
  bool _lastFetchFailed = false;
  int _consecutiveFailures = 0;

  bool _fetching = false;
  bool _fetchAgain = false;

  /// Bumped as each fetch starts. See [_ScanFollowing.judgeAfter].
  int _fetchSerial = 0;

  Timer? _pollTimer;
  Timer? _endedRowTimer;

  /// Set by [dispose] and checked after every await: a response can land
  /// after a reconnect has disposed this controller, and
  /// `notifyListeners()` on a disposed notifier throws.
  bool _disposed = false;

  static const Job _startingRow = Job(
    id: localScanRowId,
    status: JobStatus.running,
    description: 'Starting scan…',
  );

  /// What the popover lists: this app's own scan row, if any, then the
  /// fetched jobs.
  List<Job> get rows {
    final scan = _scan;
    final local = switch (scan) {
      _ScanRequesting() || _ScanFollowing(seen: false) => _startingRow,
      _ScanEnded(:final row) => row,
      _ScanIdle() || _ScanFollowing() => null,
    };
    // Stash can go on listing the job it has just ended; the ended row
    // already stands for it.
    final endedJobId = scan is _ScanEnded ? scan.jobId : null;
    return List.unmodifiable([
      ?local,
      for (final job in _jobs)
        if (job.id != endedJobId) job,
    ]);
  }

  /// Drives both the Tasks dot and the Scan button's disabled state.
  bool get hasActiveWork => _scanInProgress || _jobs.any((job) => job.isActive);

  /// Whether the most recent fetch failed.
  bool get lastFetchFailed => _lastFetchFailed;

  bool get _scanInProgress =>
      _scan is _ScanRequesting || _scan is _ScanFollowing;

  bool get _shouldPoll => _popoverOpen || hasActiveWork;

  /// Fetches the queue once, then keeps polling if anything warrants it.
  Future<void> refresh() => _fetch();

  void popoverOpened() {
    _popoverOpen = true;
    unawaited(_fetch());
  }

  void popoverClosed() {
    _popoverOpen = false;
    if (!_shouldPoll) _cancelPoll();
  }

  /// Asks Stash to scan and follows the job it queues. Does nothing while
  /// work is already active, which is also when the Scan button is
  /// disabled. Rethrows whatever the mutation threw, for the caller to
  /// surface; no row is left behind.
  Future<void> startScan() async {
    if (_disposed || hasActiveWork) return;
    _endedRowTimer?.cancel();
    _endedRowTimer = null;
    _scan = const _ScanRequesting();
    notifyListeners();

    final String jobId;
    try {
      jobId = await _api.metadataScan();
    } catch (_) {
      if (!_disposed && _scan is _ScanRequesting) {
        _scan = const _ScanIdle();
        notifyListeners();
      }
      rethrow;
    }
    // Three failed polls while the mutation was in flight can already have
    // dropped the scan.
    if (_disposed || _scan is! _ScanRequesting) return;
    _scan = _ScanFollowing(jobId, judgeAfter: _fetchSerial);
    notifyListeners();
    await _fetch();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPoll();
    _endedRowTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_disposed) return;
    if (_fetching) {
      _fetchAgain = true;
      return;
    }
    _cancelPoll();
    _fetching = true;
    final serial = ++_fetchSerial;
    List<Job>? jobs;
    try {
      jobs = await _api.jobQueue();
    } catch (_) {
      // A `Failure` from `HttpStashApi`, or a bare platform error from
      // resolving the connection behind `DeferredStashApi`: either way
      // this fetch told us nothing, and `jobs` stays null.
    }
    _fetching = false;
    if (_disposed) return;
    if (jobs == null) {
      _fetchFailed();
    } else {
      _fetched(jobs, serial);
    }
    if (_fetchAgain) {
      _fetchAgain = false;
      await _fetch();
    } else {
      _schedulePoll();
    }
  }

  void _fetched(List<Job> jobs, int serial) {
    _jobs = List.unmodifiable(jobs);
    _lastFetchFailed = false;
    _consecutiveFailures = 0;
    final scan = _scan;
    if (scan is _ScanFollowing && serial > scan.judgeAfter) _judge(scan);
    notifyListeners();
  }

  void _judge(_ScanFollowing scan) {
    final job = _jobs.where((job) => job.id == scan.jobId).firstOrNull;
    if (job != null && job.isActive) {
      if (!scan.seen) _scan = scan.markSeen();
      return;
    }
    // Absent counts as finished: Stash queues the job before
    // `metadataScan` returns, so an id missing from a fetch started
    // afterwards is one it has already dropped. An unrecognised status
    // ends it too, so this client can never follow a job forever.
    final outcome = switch (job?.status) {
      JobStatus.failed => ScanOutcome.failed,
      JobStatus.cancelled => ScanOutcome.cancelled,
      _ => ScanOutcome.completed,
    };
    _endScan(scan.jobId, outcome, error: job?.error);
  }

  void _endScan(String jobId, ScanOutcome outcome, {String? error}) {
    _scan = _ScanEnded(
      jobId,
      Job(
        id: localScanRowId,
        status: switch (outcome) {
          ScanOutcome.completed => JobStatus.finished,
          ScanOutcome.failed => JobStatus.failed,
          ScanOutcome.cancelled => JobStatus.cancelled,
        },
        description: switch (outcome) {
          ScanOutcome.completed => 'Scan complete',
          ScanOutcome.failed => 'Scan failed',
          ScanOutcome.cancelled => 'Scan cancelled',
        },
        error: error,
      ),
    );
    _endedRowTimer?.cancel();
    _endedRowTimer = Timer(scanEndedRowDuration, () {
      _endedRowTimer = null;
      if (_disposed || _scan is! _ScanEnded) return;
      _scan = const _ScanIdle();
      notifyListeners();
    });
    _onScanEnded(outcome);
  }

  void _fetchFailed() {
    _lastFetchFailed = true;
    _consecutiveFailures++;
    if (_consecutiveFailures >= maxConsecutiveFetchFailures) {
      _jobs = const [];
      if (_scanInProgress) _scan = const _ScanIdle();
    }
    notifyListeners();
  }

  void _schedulePoll() {
    _cancelPoll();
    if (!_shouldPoll) return;
    _pollTimer = Timer(tasksPollInterval, () {
      _pollTimer = null;
      unawaited(_fetch());
    });
  }

  void _cancelPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}

/// Where this app's own scan stands. See [TasksController].
sealed class _Scan {
  const _Scan();
}

final class _ScanIdle extends _Scan {
  const _ScanIdle();
}

/// `metadataScan` is in flight.
final class _ScanRequesting extends _Scan {
  const _ScanRequesting();
}

final class _ScanFollowing extends _Scan {
  const _ScanFollowing(
    this.jobId, {
    required this.judgeAfter,
    this.seen = false,
  });

  final String jobId;

  /// The fetch serial current when the id became known. Only a fetch with
  /// a higher serial was asked for after Stash had queued the job.
  final int judgeAfter;

  /// Whether a fetch has listed the job yet. Until one has, the popover
  /// keeps showing "Starting scan…".
  final bool seen;

  _ScanFollowing markSeen() =>
      _ScanFollowing(jobId, judgeAfter: judgeAfter, seen: true);
}

final class _ScanEnded extends _Scan {
  const _ScanEnded(this.jobId, this.row);

  /// The ended job's Stash id, hidden from [TasksController.rows] while
  /// [row] stands in for it.
  final String jobId;
  final Job row;
}
