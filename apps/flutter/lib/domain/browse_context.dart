import 'scene_filter.dart';

/// Where a scene sits in an ordering, so the scene screen can step to the
/// one before or after it.
///
/// Deliberately not a list of scenes. Prev/next refetch the same
/// [filter] one scene at a time, which is what lets browsing run past
/// whatever the library happens to have paged in, and what makes this
/// type a small value rather than a snapshot that can go stale. The GTK
/// client's own scene page carries the same three fields for the same
/// reason.
///
/// [total] is never a sentinel. Every path that builds a context has the
/// real count in hand, because `findScenes` returns it alongside the
/// scenes.
class BrowseContext {
  const BrowseContext({
    required this.filter,
    required this.index,
    required this.total,
  });

  /// The ordering itself. Prev/next re-issue this exact filter, so a
  /// random sort must carry its seed for the walk to stay stable.
  final SceneFilter filter;

  /// 0-based position of the current scene within [filter]'s ordering, as
  /// of the moment this context was built or last advanced.
  ///
  /// Not a live invariant: [filter]'s ordering can change out from under
  /// a context that already points into it, and prev/next has no way to
  /// detect that when it happens. Concretely, the app's own default
  /// filter (`hideTracked: true`, which `_findScenesVariables` in
  /// `http_stash_api.dart` maps to `o_counter EQUALS 0`) does this to
  /// itself: incrementing or resetting the O counter of the scene
  /// currently sitting at [index] removes it from (or returns it to)
  /// that very ordering, shifting every later position by one. Stepping
  /// from [index] stays correct exactly as long as nothing has changed
  /// the ordering since it was set.
  final int index;

  /// How many scenes [filter] matches.
  final int total;

  bool get canGoPrevious => index > 0;

  bool get canGoNext => index + 1 < total;

  /// A copy pointing at [newIndex], optionally also replacing [total]
  /// with a fresher count a caller just received alongside it. A step
  /// that just fetched [newIndex]'s scene knows [total] as of that same
  /// response, which can already be stale by the time [at] is called
  /// otherwise (see [index]'s own doc for why it drifts).
  BrowseContext at(int newIndex, {int? total}) => BrowseContext(
    filter: filter,
    index: newIndex,
    total: total ?? this.total,
  );

  @override
  bool operator ==(Object other) =>
      other is BrowseContext &&
      other.filter == filter &&
      other.index == index &&
      other.total == total;

  @override
  int get hashCode => Object.hash(filter, index, total);
}
