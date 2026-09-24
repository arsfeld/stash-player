import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/job.dart';
import 'package:stash_player_flutter/features/library/tasks_popover.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_spinner.dart';

import '../../support/app_icons.dart';

Future<void> _pumpPanel(
  WidgetTester tester, {
  List<Job> rows = const [],
  bool lastFetchFailed = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: tasksPopoverWidth,
          child: TasksPopoverPanel(
            rows: rows,
            lastFetchFailed: lastFetchFailed,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('TasksPopoverPanel', () {
    testWidgets('an empty queue says so', (tester) async {
      await _pumpPanel(tester);

      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('No active tasks'), findsOneWidget);
      expect(find.text("Couldn't reach Stash"), findsNothing);
    });

    testWidgets('a failed fetch says so instead of claiming nothing is '
        'running', (tester) async {
      await _pumpPanel(tester, lastFetchFailed: true);

      expect(find.text("Couldn't reach Stash"), findsOneWidget);
      expect(find.text('No active tasks'), findsNothing);
    });

    testWidgets('a failed fetch still lists the jobs last seen', (
      tester,
    ) async {
      await _pumpPanel(
        tester,
        lastFetchFailed: true,
        rows: const [
          Job(id: '7', status: JobStatus.ready, description: 'Generating'),
        ],
      );

      expect(find.text("Couldn't reach Stash"), findsOneWidget);
      expect(find.text('Generating'), findsOneWidget);
    });

    testWidgets('each status gets its own indicator', (tester) async {
      await _pumpPanel(
        tester,
        rows: const [
          Job(id: '1', status: JobStatus.ready, description: 'a'),
          Job(id: '2', status: JobStatus.running, description: 'b'),
          Job(id: '3', status: JobStatus.stopping, description: 'c'),
          Job(id: '4', status: JobStatus.finished, description: 'd'),
          Job(id: '5', status: JobStatus.failed, description: 'e'),
          Job(id: '6', status: JobStatus.cancelled, description: 'f'),
          Job(id: '7', status: JobStatus.unknown, description: 'g'),
        ],
      );

      expect(findAppIcon(AppIcon.clock), findsOneWidget);
      expect(find.byType(AppSpinner), findsNWidgets(2));
      expect(findAppIcon(AppIcon.done), findsOneWidget);
      expect(findAppIcon(AppIcon.warning), findsNWidgets(2));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints ==
                  const BoxConstraints.tightFor(width: 8, height: 8),
        ),
        findsOneWidget,
      );
    });

    testWidgets('only an active job with some progress shows a bar', (
      tester,
    ) async {
      await _pumpPanel(
        tester,
        rows: const [
          Job(
            id: '1',
            status: JobStatus.running,
            description: 'Scanning',
            progress: 0.35,
          ),
          Job(
            id: '2',
            status: JobStatus.running,
            description: 'Starting',
            progress: 0,
          ),
          Job(
            id: '3',
            status: JobStatus.finished,
            description: 'Done',
            progress: 1,
          ),
        ],
      );

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.35);
    });

    testWidgets("a failed job shows Stash's error text", (tester) async {
      await _pumpPanel(
        tester,
        rows: const [
          Job(
            id: '1',
            status: JobStatus.failed,
            description: 'Scanning',
            error: 'disk gone',
          ),
        ],
      );

      expect(find.text('disk gone'), findsOneWidget);
    });

    testWidgets('each row is one semantics node carrying its whole story', (
      tester,
    ) async {
      await _pumpPanel(
        tester,
        rows: const [
          Job(
            id: '1',
            status: JobStatus.running,
            description: 'Scanning for new files',
            progress: 0.35,
          ),
        ],
      );

      expect(
        tester.getSemantics(find.byType(TaskRow)).label,
        'Scanning for new files, running, 35 percent',
      );
    });
  });

  group('taskSemanticsLabel', () {
    test('names each status in words', () {
      expect(
        {for (final status in JobStatus.values) status: taskStatusWord(status)},
        {
          JobStatus.ready: 'queued',
          JobStatus.running: 'running',
          JobStatus.stopping: 'stopping',
          JobStatus.finished: 'finished',
          JobStatus.cancelled: 'cancelled',
          JobStatus.failed: 'failed',
          JobStatus.unknown: 'status unknown',
        },
      );
    });

    test('adds progress only while active, and the error only when failed', () {
      expect(
        taskSemanticsLabel(
          const Job(
            id: '1',
            status: JobStatus.finished,
            description: 'Scanning',
            progress: 1,
          ),
        ),
        'Scanning, finished',
      );
      expect(
        taskSemanticsLabel(
          const Job(
            id: '1',
            status: JobStatus.failed,
            description: 'Scanning',
            error: 'disk gone',
          ),
        ),
        'Scanning, failed, disk gone',
      );
    });

    test('leaves out an empty description', () {
      expect(
        taskSemanticsLabel(
          const Job(id: '1', status: JobStatus.ready, description: ''),
        ),
        'queued',
      );
    });
  });
}
