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

  /// 0-based position of the current scene within [filter]'s ordering.
  final int index;

  /// How many scenes [filter] matches.
  final int total;

  bool get canGoPrevious => index > 0;

  bool get canGoNext => index + 1 < total;

  BrowseContext at(int newIndex) =>
      BrowseContext(filter: filter, index: newIndex, total: total);

  @override
  bool operator ==(Object other) =>
      other is BrowseContext &&
      other.filter == filter &&
      other.index == index &&
      other.total == total;

  @override
  int get hashCode => Object.hash(filter, index, total);
}
