enum SceneSort {
  date,
  title,
  rating,
  playCount,
  duration,
  createdAt,
  updatedAt,
  random,
}

enum SortDirection { ascending, descending }

class SceneFilter {
  const SceneFilter({
    this.query = '',
    this.sort = SceneSort.createdAt,
    this.direction = SortDirection.descending,
    this.minimumRating,
    this.organized,
    this.hideTracked = true,
    this.randomSeed,
  });

  final String query;
  final SceneSort sort;
  final SortDirection direction;
  final int? minimumRating;
  final bool? organized;
  final bool hideTracked;
  final int? randomSeed;

  SceneFilter copyWith({
    String? query,
    SceneSort? sort,
    SortDirection? direction,
    int? minimumRating,
    bool clearMinimumRating = false,
    bool? organized,
    bool clearOrganized = false,
    bool? hideTracked,
    int? randomSeed,
    bool clearRandomSeed = false,
  }) => SceneFilter(
    query: query ?? this.query,
    sort: sort ?? this.sort,
    direction: direction ?? this.direction,
    minimumRating: clearMinimumRating
        ? null
        : minimumRating ?? this.minimumRating,
    organized: clearOrganized ? null : organized ?? this.organized,
    hideTracked: hideTracked ?? this.hideTracked,
    randomSeed: clearRandomSeed ? null : randomSeed ?? this.randomSeed,
  );
}
