import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/job.dart';

void main() {
  test('only queued, running and stopping jobs count as active', () {
    final active = {
      for (final status in JobStatus.values)
        status: Job(id: '1', status: status, description: '').isActive,
    };

    expect(active, {
      JobStatus.ready: true,
      JobStatus.running: true,
      JobStatus.stopping: true,
      JobStatus.finished: false,
      JobStatus.cancelled: false,
      JobStatus.failed: false,
      JobStatus.unknown: false,
    });
  });

  test(
    'jobs with the same fields are equal, and any field tells them apart',
    () {
      const job = Job(
        id: '42',
        status: JobStatus.failed,
        description: 'Scanning...',
        progress: 0.5,
        error: 'disk gone',
      );

      expect(
        job,
        const Job(
          id: '42',
          status: JobStatus.failed,
          description: 'Scanning...',
          progress: 0.5,
          error: 'disk gone',
        ),
      );
      expect(
        job.hashCode,
        const Job(
          id: '42',
          status: JobStatus.failed,
          description: 'Scanning...',
          progress: 0.5,
          error: 'disk gone',
        ).hashCode,
      );
      expect(
        job ==
            const Job(
              id: '42',
              status: JobStatus.failed,
              description: 'Scanning...',
              progress: 0.5,
            ),
        isFalse,
      );
    },
  );
}
