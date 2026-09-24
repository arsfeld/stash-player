import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/job.dart';
import '../../ui/theme/app_tokens.dart';
import 'tasks_controller.dart';

const double tasksPopoverWidth = 300;
const double tasksPopoverMaxHeight = 320;

/// Opens the Tasks popover under [anchor], which must be the Tasks
/// button's own context, and tells [tasksControllerProvider] it is open
/// until it closes.
///
/// A route rather than `MenuAnchor` or `OverlayPortal`: those overlays sit
/// outside the page's focus traversal, which is why the library toolbar
/// already avoids `MenuAnchor` for its filters. A `PopupRoute` gets what
/// `showMenu` gives `AppMenuButton`: focus moves into it, Esc or a click
/// outside closes it, and focus goes back to the button.
Future<void> showTasksPopover(BuildContext anchor) async {
  final container = ProviderScope.containerOf(anchor, listen: false);
  final navigator = Navigator.of(anchor);
  final button = anchor.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final anchorRect = Rect.fromPoints(
    button.localToGlobal(Offset.zero, ancestor: overlay),
    button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );

  container.read(tasksControllerProvider).popoverOpened();
  await navigator.push(
    _TasksPopoverRoute(
      anchorRect: anchorRect,
      barrierLabel: MaterialLocalizations.of(anchor).modalBarrierDismissLabel,
    ),
  );
  // Whichever controller is current now. A reconnect while the popover was
  // open swaps it, and telling the new one its popover closed is harmless.
  container.read(tasksControllerProvider).popoverClosed();
}

class _TasksPopoverRoute extends PopupRoute<void> {
  _TasksPopoverRoute({required this.anchorRect, required this.barrierLabel});

  final Rect anchorRect;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  // Also what makes Esc close it: a modal route's own dismiss action is
  // enabled exactly when its barrier is dismissible.
  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => CustomSingleChildLayout(
    delegate: _TasksPopoverLayout(anchorRect),
    child: Consumer(
      builder: (context, ref, _) {
        final tasks = ref.watch(tasksControllerProvider);
        return TasksPopoverPanel(
          rows: tasks.rows,
          lastFetchFailed: tasks.lastFetchFailed,
        );
      },
    ),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}

/// Puts the panel just under the button, right edges aligned, and keeps it
/// inside the window.
class _TasksPopoverLayout extends SingleChildLayoutDelegate {
  const _TasksPopoverLayout(this.anchorRect);

  final Rect anchorRect;

  static const double _gap = 4;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      tasksPopoverWidth,
      math.max(0.0, constraints.maxWidth - 2 * _margin),
    );
    final height = math.min(
      tasksPopoverMaxHeight,
      math.max(0.0, constraints.maxHeight - anchorRect.bottom - _gap - _margin),
    );
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rightmost = size.width - childSize.width - _margin;
    final left = math.max(
      _margin,
      math.min(anchorRect.right - childSize.width, rightmost),
    );
    return Offset(left, anchorRect.bottom + _gap);
  }

  @override
  bool shouldRelayout(_TasksPopoverLayout oldDelegate) =>
      oldDelegate.anchorRect != anchorRect;
}

/// The popover's content: a heading, then one row per job.
class TasksPopoverPanel extends StatelessWidget {
  const TasksPopoverPanel({
    required this.rows,
    required this.lastFetchFailed,
    super.key,
  });

  final List<Job> rows;
  final bool lastFetchFailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTokens.of(context);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(tokens.radiusPanel),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Tasks',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.space3,
                AppTokens.space3,
                AppTokens.space3,
                AppTokens.space2,
              ),
              child: Text('Tasks', style: theme.textTheme.titleSmall),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: AppTokens.space2),
                children: [
                  if (lastFetchFailed)
                    _Line(
                      text: "Couldn't reach Stash",
                      color: theme.colorScheme.error,
                    )
                  else if (rows.isEmpty)
                    _Line(text: 'No active tasks', color: tokens.textFaint),
                  for (final job in rows)
                    TaskRow(key: ValueKey(job.id), job: job),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppTokens.space3,
      vertical: AppTokens.space2,
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
    ),
  );
}

/// One job in the popover.
class TaskRow extends StatelessWidget {
  const TaskRow({required this.job, super.key});

  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = job.progress;
    final error = job.error;
    return Semantics(
      container: true,
      label: taskSemanticsLabel(job),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space3,
          vertical: AppTokens.space2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(dimension: 16, child: _StatusIndicator(job.status)),
            const SizedBox(width: AppTokens.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    job.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (job.isActive && progress != null && progress > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.space1),
                      child: LinearProgressIndicator(value: progress),
                    ),
                  if (job.status == JobStatus.failed && error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.space1),
                      child: Text(
                        error,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator(this.status);

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      JobStatus.ready => Icon(
        Icons.schedule,
        size: 16,
        color: scheme.onSurfaceVariant,
      ),
      JobStatus.running || JobStatus.stopping => const Padding(
        padding: EdgeInsets.all(2),
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      JobStatus.finished => Icon(
        Icons.check_circle,
        size: 16,
        color: scheme.primary,
      ),
      JobStatus.failed || JobStatus.cancelled => Icon(
        Icons.warning_amber_rounded,
        size: 16,
        color: scheme.error,
      ),
      JobStatus.unknown => Center(
        child: Icon(
          Icons.circle,
          size: 8,
          color: AppTokens.of(context).textFaint,
        ),
      ),
    };
  }
}

/// What a screen reader announces for one row, e.g. "Scanning for new
/// files, running, 35 percent".
String taskSemanticsLabel(Job job) {
  final progress = job.progress;
  return [
    if (job.description.isNotEmpty) job.description,
    taskStatusWord(job.status),
    if (job.isActive && progress != null && progress > 0)
      '${(progress * 100).round()} percent',
    if (job.status == JobStatus.failed) ?job.error,
  ].join(', ');
}

String taskStatusWord(JobStatus status) => switch (status) {
  JobStatus.ready => 'queued',
  JobStatus.running => 'running',
  JobStatus.stopping => 'stopping',
  JobStatus.finished => 'finished',
  JobStatus.cancelled => 'cancelled',
  JobStatus.failed => 'failed',
  JobStatus.unknown => 'status unknown',
};
