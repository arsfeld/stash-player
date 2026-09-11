import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/deferred_stash_api.dart';
import '../../app/notices.dart';
import '../../app/providers.dart';
import '../../domain/job.dart';
import '../../services/stash_api.dart';
import 'library_controller.dart';

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
/// would otherwise read as the job having already finished. A listed job
/// with a terminal status ends the scan that way outright; Stash instead
/// usually drops a job from the queue the moment it ends, so once a
/// judging fetch finds the id gone, `findJob` is asked how it ended
/// (`FAILED`, `CANCELLED`, anything else read as completed) before the
/// scan is called over. The `onScanEnded` callback then fires exactly
/// once, after listeners have already been told (so the popover already
/// shows the ended row by the time it runs), and a row saying how the
/// scan ended is listed for [scanEndedRowDuration].
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

    // The followed job just left this fetch's snapshot: Stash drops a job
    // from the queue the moment it ends, so its absence says nothing on
    // its own until `findJob` (which also searches the few most recently
    // ended jobs) has had a chance to say how. Looked up here, still
    // inside `_fetching`, so a fetch asked for meanwhile still folds into
    // `_fetchAgain` instead of racing this lookup.
    Job? lookedUpJob;
    final scan = _scan;
    if (jobs != null &&
        !_disposed &&
        scan is _ScanFollowing &&
        serial > scan.judgeAfter &&
        !jobs.any((job) => job.id == scan.jobId)) {
      lookedUpJob = await _lookUpEndedJob(scan.jobId);
    }

    _fetching = false;
    if (_disposed) return;
    if (jobs == null) {
      _fetchFailed();
    } else {
      _fetched(jobs, serial, lookedUpJob);
    }
    if (_fetchAgain) {
      _fetchAgain = false;
      await _fetch();
    } else {
      _schedulePoll();
    }
  }

  void _fetched(List<Job> jobs, int serial, Job? lookedUpJob) {
    _jobs = List.unmodifiable(jobs);
    _lastFetchFailed = false;
    _consecutiveFailures = 0;
    final scan = _scan;
    final endedOutcome = scan is _ScanFollowing && serial > scan.judgeAfter
        ? _judge(scan, lookedUpJob)
        : null;
    // Listeners (the Tasks dot, the popover) hear about the ended state
    // before the callback runs, so a caller reading `rows` or
    // `hasActiveWork` from inside `onScanEnded` already sees it, and a
    // callback that throws still leaves listeners told.
    notifyListeners();
    if (endedOutcome != null) _onScanEnded(endedOutcome);
  }

  /// Decides whether the followed job is still going, and if not, how it
  /// ended. Returns the outcome exactly when the scan just ended, so the
  /// caller can notify listeners before telling `onScanEnded`.
  ScanOutcome? _judge(_ScanFollowing scan, Job? lookedUpJob) {
    final listed = _jobs.where((job) => job.id == scan.jobId).firstOrNull;
    if (listed != null && listed.isActive) {
      if (!scan.seen) _scan = scan.markSeen();
      return null;
    }
    // A listed job past `isActive` (a terminal status Stash reported
    // before removing it) is trusted outright; otherwise the job is gone
    // from the queue, and only `lookedUpJob` (from `findJob`, or null
    // when Stash no longer knows it either) can say how it ended. An
    // unrecognised status ends it too, so this client can never follow a
    // job forever.
    final job = listed ?? lookedUpJob;
    final outcome = switch (job?.status) {
      JobStatus.failed => ScanOutcome.failed,
      JobStatus.cancelled => ScanOutcome.cancelled,
      _ => ScanOutcome.completed,
    };
    _endScan(scan.jobId, outcome, error: job?.error);
    return outcome;
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
  }

  /// How a job that has left the queue ended. Stash drops a job from
  /// `jobQueue` the moment it ends, final status and all; only `findJob`,
  /// which also searches its ten most recently ended jobs, can still say.
  /// Not knowing is no reason to keep following a job that is gone, so a
  /// failed lookup reads as no answer.
  Future<Job?> _lookUpEndedJob(String id) async {
    try {
      return await _api.findJob(id);
    } catch (_) {
      return null;
    }
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

/// The library's Tasks controller. Rebuilt from scratch whenever
/// [connectionGenerationProvider] changes, like
/// [libraryControllerProvider]: a scan followed on the old connection may
/// belong to a different server.
final tasksControllerProvider = ChangeNotifierProvider<TasksController>((ref) {
  ref.watch(connectionGenerationProvider);
  return TasksController(
    api: DeferredStashApi(ref),
    onScanEnded: (outcome) => _announceScanEnd(ref, outcome),
  );
});

/// Reloads the grid, and speaks up when the scan did not simply finish:
/// the popover is usually closed by the time a scan ends, so a failure
/// would otherwise go unseen.
void _announceScanEnd(Ref ref, ScanOutcome outcome) {
  // Every ending reloads, because a scan that failed or was cancelled part
  // way through can still have added scenes.
  unawaited(ref.read(libraryControllerProvider).reload());
  final notice = switch (outcome) {
    ScanOutcome.completed => null,
    ScanOutcome.failed => AppNotice(
      message: 'Library scan failed.',
      severity: AppNoticeSeverity.error,
    ),
    ScanOutcome.cancelled => AppNotice(
      message: 'Library scan was cancelled.',
      severity: AppNoticeSeverity.warning,
    ),
  };
  if (notice != null) ref.read(globalNoticeProvider.notifier).show(notice);
}
