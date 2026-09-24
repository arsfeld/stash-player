/// Where a Stash job is in its life. Mirrors Stash's `JobStatus` enum,
/// plus [unknown] for a value this client does not recognise.
enum JobStatus {
  /// Queued behind other work and not started yet. Stash calls this READY.
  ready,
  running,

  /// Asked to stop and still winding down: work Stash has not finished.
  stopping,
  finished,
  cancelled,
  failed,

  /// A status Stash added after this client was written. It decodes as an
  /// inactive job rather than failing the whole queue, so one new value
  /// cannot blank the Tasks popover.
  unknown,
}

/// One entry in Stash's job queue: a scan, a generate, an auto-tag.
class Job {
  const Job({
    required this.id,
    required this.status,
    required this.description,
    this.progress,
    this.error,
  });

  final String id;
  final JobStatus status;

  /// Stash's own one-line summary of the job. Can be empty.
  final String description;

  /// Fraction done, 0 to 1. Null when the job cannot estimate it.
  final double? progress;

  /// Why the job failed, as Stash reported it.
  final String? error;

  /// Queued, running, or winding down: work Stash has not finished with.
  bool get isActive => switch (status) {
    JobStatus.ready || JobStatus.running || JobStatus.stopping => true,
    JobStatus.finished ||
    JobStatus.cancelled ||
    JobStatus.failed ||
    JobStatus.unknown => false,
  };

  @override
  bool operator ==(Object other) =>
      other is Job &&
      other.id == id &&
      other.status == status &&
      other.description == description &&
      other.progress == progress &&
      other.error == error;

  @override
  int get hashCode => Object.hash(id, status, description, progress, error);

  @override
  String toString() =>
      'Job($id, ${status.name}, "$description", progress: $progress, '
      'error: $error)';
}
