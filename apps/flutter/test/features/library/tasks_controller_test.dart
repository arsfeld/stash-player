import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/job.dart';
import 'package:stash_player_flutter/features/library/tasks_controller.dart';

import '../../support/fakes.dart';

Job _job(
  String id,
  JobStatus status, {
  String description = 'Scanning...',
  double? progress,
  String? error,
}) => Job(
  id: id,
  status: status,
  description: description,
  progress: progress,
  error: error,
);

const _startingRow = Job(
  id: localScanRowId,
  status: JobStatus.running,
  description: 'Starting scan…',
);

void main() {
  late FakeStashApi api;
  late List<ScanOutcome> outcomes;

  setUp(() {
    api = FakeStashApi();
    outcomes = [];
  });

  TasksController build() =>
      TasksController(api: api, onScanEnded: outcomes.add);

  group('fetching', () {
    test('a load with nothing running fetches once, then goes quiet', () {
      fakeAsync((async) {
        final tasks = build();

        tasks.refresh();
        async.flushMicrotasks();

        expect(api.jobQueueCalls, hasLength(1));
        expect(tasks.rows, isEmpty);
        expect(tasks.hasActiveWork, isFalse);

        async.elapse(const Duration(minutes: 1));
        expect(api.jobQueueCalls, hasLength(1));
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('an active job keeps it polling, and polling stops once the job '
        'ends', () {
      // The SwiftUI client's dot once stuck on for good because nothing
      // polled after the last snapshot showed work running.
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.addAll([
          [_job('7', JobStatus.running, progress: 0.2)],
          [_job('7', JobStatus.running, progress: 0.6)],
        ]);

        tasks.refresh();
        async.flushMicrotasks();
        expect(tasks.hasActiveWork, isTrue);
        expect(tasks.rows.single.progress, 0.2);

        async.elapse(tasksPollInterval);
        expect(api.jobQueueCalls, hasLength(2));
        expect(tasks.rows.single.progress, 0.6);

        async.elapse(tasksPollInterval);
        expect(api.jobQueueCalls, hasLength(3));
        expect(tasks.rows, isEmpty);
        expect(tasks.hasActiveWork, isFalse);

        async.elapse(const Duration(minutes: 1));
        expect(api.jobQueueCalls, hasLength(3));
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('an open popover polls with nothing running, and closing it '
        'stops', () {
      fakeAsync((async) {
        final tasks = build();

        tasks.popoverOpened();
        async.flushMicrotasks();
        expect(api.jobQueueCalls, hasLength(1));

        async.elapse(tasksPollInterval * 2);
        expect(api.jobQueueCalls, hasLength(3));

        tasks.popoverClosed();
        async.elapse(tasksPollInterval * 3);
        expect(api.jobQueueCalls, hasLength(3));
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('closing the popover keeps polling while a job is still active', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.add([_job('7', JobStatus.running)]);

        tasks.popoverOpened();
        async.flushMicrotasks();
        tasks.popoverClosed();

        async.elapse(tasksPollInterval);
        expect(api.jobQueueCalls, hasLength(2));
        expect(tasks.hasActiveWork, isFalse);

        async.elapse(tasksPollInterval * 3);
        expect(api.jobQueueCalls, hasLength(2));
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('opening the popover fetches at once instead of waiting out a '
        'pending poll', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.addAll([
          [_job('7', JobStatus.running)],
          [_job('7', JobStatus.running)],
        ]);

        tasks.refresh();
        async.flushMicrotasks();
        async.elapse(tasksPollInterval ~/ 2);

        tasks.popoverOpened();
        async.flushMicrotasks();
        expect(api.jobQueueCalls, hasLength(2));

        // The poll armed by the first fetch was replaced, not kept.
        async.elapse(tasksPollInterval ~/ 2);
        expect(api.jobQueueCalls, hasLength(2));
        async.elapse(tasksPollInterval ~/ 2);
        expect(api.jobQueueCalls, hasLength(3));

        tasks.popoverClosed();
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a slow response holds back the next poll, and a fetch asked for '
        'meanwhile runs once it returns', () {
      fakeAsync((async) {
        final tasks = build();
        api.holdJobQueue = true;

        tasks.popoverOpened();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(api.jobQueueCalls, hasLength(1));

        tasks.refresh();
        async.flushMicrotasks();
        expect(api.jobQueueCalls, hasLength(1));

        api.jobQueueCalls[0].completer.complete(const []);
        async.flushMicrotasks();
        expect(api.jobQueueCalls, hasLength(2));

        api.jobQueueCalls[1].completer.complete(const []);
        async.flushMicrotasks();
        tasks.popoverClosed();
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });
  });

  group('failed fetches', () {
    test('a failed fetch keeps the jobs last seen, and a good one clears the '
        'failure', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.add([_job('7', JobStatus.running)]);

        tasks.refresh();
        async.flushMicrotasks();
        api.jobQueueFailures.add(const TransportFailure());
        async.elapse(tasksPollInterval);

        expect(tasks.lastFetchFailed, isTrue);
        expect(tasks.rows, [_job('7', JobStatus.running)]);
        expect(tasks.hasActiveWork, isTrue);

        async.elapse(tasksPollInterval);
        expect(tasks.lastFetchFailed, isFalse);
        expect(tasks.hasActiveWork, isFalse);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('three failed fetches in a row forget what was last seen, so a '
        'dead server cannot keep it polling', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.add([_job('7', JobStatus.running)]);

        tasks.refresh();
        async.flushMicrotasks();
        api.jobQueueFailures.addAll(
          List.filled(maxConsecutiveFetchFailures, const TransportFailure()),
        );
        async.elapse(tasksPollInterval * 2);
        expect(tasks.rows, [_job('7', JobStatus.running)]);

        async.elapse(tasksPollInterval);
        expect(tasks.rows, isEmpty);
        expect(tasks.hasActiveWork, isFalse);
        expect(tasks.lastFetchFailed, isTrue);

        final calls = api.jobQueueCalls.length;
        async.elapse(const Duration(minutes: 1));
        expect(api.jobQueueCalls, hasLength(calls));
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('an open popover keeps retrying a dead server', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueFailures.addAll(List.filled(5, const TransportFailure()));

        tasks.popoverOpened();
        async.flushMicrotasks();
        async.elapse(tasksPollInterval * 4);

        expect(api.jobQueueCalls, hasLength(5));
        expect(tasks.lastFetchFailed, isTrue);
        tasks.popoverClosed();
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a bare (non-Failure) error counts as a failed fetch', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueFailures.add(StateError('keyring locked'));

        tasks.refresh();
        async.flushMicrotasks();

        expect(tasks.lastFetchFailed, isTrue);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });
  });

  group('disposal', () {
    test('disposing mid-fetch drops the late response and leaves no timer', () {
      fakeAsync((async) {
        final tasks = build();
        api.holdJobQueue = true;
        var notified = 0;
        tasks.addListener(() => notified++);

        tasks.popoverOpened();
        async.flushMicrotasks();
        tasks.dispose();
        api.jobQueueCalls.single.completer.complete([
          _job('7', JobStatus.running),
        ]);
        async.flushMicrotasks();

        expect(notified, 0);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('scan', () {
    test('shows "Starting scan…" while the mutation is in flight, hands over '
        "to Stash's own row, and reports the end exactly once", () {
      fakeAsync((async) {
        final tasks = build();
        api.holdMetadataScan = true;

        tasks.startScan();
        async.flushMicrotasks();
        expect(tasks.hasActiveWork, isTrue);
        expect(tasks.rows, [_startingRow]);

        api.jobQueueResults.add([_job('42', JobStatus.running, progress: 0.1)]);
        api.metadataScanCalls.single.complete('42');
        async.flushMicrotasks();
        expect(tasks.rows, [_job('42', JobStatus.running, progress: 0.1)]);
        expect(outcomes, isEmpty);

        // The fake's default idle queue: job 42 has left it.
        async.elapse(tasksPollInterval);
        expect(outcomes, [ScanOutcome.completed]);
        expect(tasks.hasActiveWork, isFalse);
        expect(tasks.rows, [
          const Job(
            id: localScanRowId,
            status: JobStatus.finished,
            description: 'Scan complete',
          ),
        ]);

        async.elapse(scanEndedRowDuration);
        expect(tasks.rows, isEmpty);
        expect(outcomes, [ScanOutcome.completed]);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a job Stash reports FAILED ends as failed, carries its error, and '
        'is not listed twice', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.jobQueueResults.addAll([
          [_job('42', JobStatus.running)],
          [_job('42', JobStatus.failed, error: 'disk gone')],
        ]);

        tasks.startScan();
        async.flushMicrotasks();
        async.elapse(tasksPollInterval);

        expect(outcomes, [ScanOutcome.failed]);
        expect(tasks.rows, [
          const Job(
            id: localScanRowId,
            status: JobStatus.failed,
            description: 'Scan failed',
            error: 'disk gone',
          ),
        ]);
        async.elapse(scanEndedRowDuration);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a job Stash reports CANCELLED ends as cancelled', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.jobQueueResults.add([_job('42', JobStatus.cancelled)]);

        tasks.startScan();
        async.flushMicrotasks();

        expect(outcomes, [ScanOutcome.cancelled]);
        expect(tasks.rows.single.description, 'Scan cancelled');
        async.elapse(scanEndedRowDuration);
        tasks.dispose();
      });
    });

    test('a job already gone at the first fetch after the mutation has '
        'finished', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');

        tasks.startScan();
        async.flushMicrotasks();

        expect(outcomes, [ScanOutcome.completed]);
        expect(tasks.rows.single.description, 'Scan complete');
        async.elapse(scanEndedRowDuration);
        tasks.dispose();
      });
    });

    test("a scan queued behind someone else's job ends when its own job "
        'does, not when the queue drains', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.jobQueueResults.addAll([
          [_job('7', JobStatus.running), _job('42', JobStatus.ready)],
          [_job('42', JobStatus.running)],
          [_job('8', JobStatus.running)],
        ]);

        tasks.startScan();
        async.flushMicrotasks();
        expect(tasks.rows, [
          _job('7', JobStatus.running),
          _job('42', JobStatus.ready),
        ]);

        async.elapse(tasksPollInterval);
        expect(outcomes, isEmpty);

        async.elapse(tasksPollInterval);
        expect(outcomes, [ScanOutcome.completed]);
        // Job 8 still runs, so the dot stays on for it.
        expect(tasks.hasActiveWork, isTrue);

        async.elapse(tasksPollInterval);
        async.elapse(scanEndedRowDuration);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('an unrecognised status on the followed job ends the scan instead '
        'of following it forever', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.jobQueueResults.add([_job('42', JobStatus.unknown)]);

        tasks.startScan();
        async.flushMicrotasks();

        expect(outcomes, [ScanOutcome.completed]);
        async.elapse(scanEndedRowDuration);
        tasks.dispose();
      });
    });

    test('a fetch already in flight when the mutation returns cannot end the '
        'scan early', () {
      // That fetch asked for the queue before Stash had queued the job, so
      // the job's absence from it means nothing.
      fakeAsync((async) {
        final tasks = build();
        api.holdJobQueue = true;
        api.holdMetadataScan = true;

        tasks.popoverOpened();
        async.flushMicrotasks();
        tasks.startScan();
        async.flushMicrotasks();
        api.metadataScanCalls.single.complete('42');
        async.flushMicrotasks();

        api.jobQueueCalls[0].completer.complete(const []);
        async.flushMicrotasks();
        expect(outcomes, isEmpty);
        expect(tasks.hasActiveWork, isTrue);
        expect(api.jobQueueCalls, hasLength(2));

        api.jobQueueCalls[1].completer.complete([
          _job('42', JobStatus.running),
        ]);
        async.flushMicrotasks();
        expect(outcomes, isEmpty);
        expect(tasks.rows, [_job('42', JobStatus.running)]);

        api.holdJobQueue = false;
        tasks.popoverClosed();
        async.elapse(tasksPollInterval);
        expect(outcomes, [ScanOutcome.completed]);
        async.elapse(scanEndedRowDuration);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a failed mutation rethrows and leaves nothing behind', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanFailures.add(const TransportFailure());
        Object? thrown;

        tasks.startScan().catchError((Object error) {
          thrown = error;
        });
        async.flushMicrotasks();

        expect(thrown, isA<TransportFailure>());
        expect(tasks.rows, isEmpty);
        expect(tasks.hasActiveWork, isFalse);
        expect(outcomes, isEmpty);
        expect(api.jobQueueCalls, isEmpty);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('Scan does nothing while work is already active', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.add([_job('7', JobStatus.running)]);

        tasks.refresh();
        async.flushMicrotasks();
        tasks.startScan();
        async.flushMicrotasks();

        expect(api.metadataScanCalls, isEmpty);
        async.elapse(tasksPollInterval);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('starting a new scan replaces the ended row', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');

        tasks.startScan();
        async.flushMicrotasks();
        expect(tasks.rows.single.description, 'Scan complete');

        api.holdMetadataScan = true;
        tasks.startScan();
        async.flushMicrotasks();
        expect(tasks.rows, [_startingRow]);

        api.metadataScanCalls.last.complete('43');
        async.flushMicrotasks();
        expect(outcomes, [ScanOutcome.completed, ScanOutcome.completed]);
        async.elapse(scanEndedRowDuration);
        expect(tasks.rows, isEmpty);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('three failed fetches stop following a scan without reporting an '
        'end', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.jobQueueResults.add([_job('42', JobStatus.running)]);

        tasks.startScan();
        async.flushMicrotasks();
        api.jobQueueFailures.addAll(
          List.filled(maxConsecutiveFetchFailures, const TransportFailure()),
        );
        async.elapse(tasksPollInterval * maxConsecutiveFetchFailures);

        expect(tasks.hasActiveWork, isFalse);
        expect(tasks.rows, isEmpty);
        expect(outcomes, isEmpty);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('disposing during a scan never reports its end', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.holdJobQueue = true;

        tasks.startScan();
        async.flushMicrotasks();
        tasks.dispose();
        api.jobQueueCalls.single.completer.complete(const []);
        async.flushMicrotasks();

        expect(outcomes, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a job that leaves the queue is looked up to learn it failed, since '
        'Stash only lists jobs that have not ended', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.jobQueueResults.add([_job('42', JobStatus.running)]);
        api.findJobResults.add(
          _job('42', JobStatus.failed, error: 'disk gone'),
        );

        tasks.startScan();
        async.flushMicrotasks();
        async.elapse(tasksPollInterval);

        expect(api.findJobCalls, ['42']);
        expect(outcomes, [ScanOutcome.failed]);
        expect(tasks.rows, [
          const Job(
            id: localScanRowId,
            status: JobStatus.failed,
            description: 'Scan failed',
            error: 'disk gone',
          ),
        ]);
        async.elapse(scanEndedRowDuration);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a job looked up as cancelled ends the scan as cancelled', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.add('42');
        api.findJobResults.add(_job('42', JobStatus.cancelled));

        tasks.startScan();
        async.flushMicrotasks();

        expect(outcomes, [ScanOutcome.cancelled]);
        expect(tasks.rows.single.description, 'Scan cancelled');
        async.elapse(scanEndedRowDuration);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('a lookup that finds nothing, or fails, ends the scan as '
        'completed', () {
      fakeAsync((async) {
        final tasks = build();
        api.metadataScanResults.addAll(['42', '43']);
        api.findJobFailures.add(const TransportFailure());

        tasks.startScan();
        async.flushMicrotasks();
        expect(outcomes, [ScanOutcome.completed]);

        async.elapse(scanEndedRowDuration);
        tasks.startScan();
        async.flushMicrotasks();
        expect(outcomes, [ScanOutcome.completed, ScanOutcome.completed]);
        expect(api.findJobCalls, ['42', '43']);

        async.elapse(scanEndedRowDuration);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('only the followed job is ever looked up, and only once it has '
        'left the queue', () {
      fakeAsync((async) {
        final tasks = build();
        api.jobQueueResults.add([_job('7', JobStatus.running)]);

        tasks.refresh();
        async.flushMicrotasks();
        async.elapse(tasksPollInterval);

        expect(api.findJobCalls, isEmpty);
        expect(async.pendingTimers, isEmpty);
        tasks.dispose();
      });
    });

    test('listeners already see the ended scan when onScanEnded runs', () {
      fakeAsync((async) {
        final events = <String>[];
        late final TasksController tasks;
        tasks = TasksController(
          api: api,
          onScanEnded: (outcome) => events.add(
            'ended, rows: ${tasks.rows.map((row) => row.description).join()}',
          ),
        );
        tasks.addListener(() => events.add('notified'));
        api.metadataScanResults.add('42');

        tasks.startScan();
        async.flushMicrotasks();

        expect(events.last, 'ended, rows: Scan complete');
        expect(events[events.length - 2], 'notified');
        async.elapse(scanEndedRowDuration);
        tasks.dispose();
      });
    });
  });
}
