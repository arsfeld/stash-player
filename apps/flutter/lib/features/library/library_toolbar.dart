import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/scene_filter.dart';

/// Width, in logical pixels, at and above which every control renders
/// directly in one [Wrap]. Below it, only search and "Play random" stay
/// in the primary row; the rest move into a [MenuAnchor].
const double libraryToolbarWideBreakpoint = 760;

/// The library's filter/sort/paging controls.
///
/// Purely presentational: it receives the active [filter] and forwards
/// every change through a typed callback — no business logic beyond the
/// 250 ms search debounce (cancelled on [dispose], so a timer can never
/// fire against a disposed widget's callbacks) lives here. Every callback
/// signature intentionally matches a [LibraryController] intent 1:1 so
/// the owning screen can pass the controller's methods straight through
/// as tear-offs.
class LibraryToolbar extends StatefulWidget {
  const LibraryToolbar({
    required this.filter,
    required this.onQueryChanged,
    required this.onSortChanged,
    required this.onDirectionChanged,
    required this.onMinimumRatingChanged,
    required this.onOrganizedChanged,
    required this.onHideTrackedChanged,
    required this.onPlayRandom,
    required this.onOpenSettings,
    super.key,
  });

  final SceneFilter filter;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<SceneSort> onSortChanged;
  final ValueChanged<SortDirection> onDirectionChanged;
  final ValueChanged<int?> onMinimumRatingChanged;
  final ValueChanged<bool?> onOrganizedChanged;
  final ValueChanged<bool> onHideTrackedChanged;
  final VoidCallback onPlayRandom;
  final VoidCallback onOpenSettings;

  @override
  State<LibraryToolbar> createState() => _LibraryToolbarState();
}

class _LibraryToolbarState extends State<LibraryToolbar> {
  late final TextEditingController _searchController;
  Timer? _debounce;

  final _searchFocusNode = FocusNode(debugLabel: 'library-search');
  final _sortFocusNode = FocusNode(debugLabel: 'library-sort');
  final _directionFocusNode = FocusNode(debugLabel: 'library-direction');
  final _minimumRatingFocusNode = FocusNode(
    debugLabel: 'library-minimum-rating',
  );
  final _organizedFocusNode = FocusNode(debugLabel: 'library-organized');
  final _hideTrackedFocusNode = FocusNode(debugLabel: 'library-hide-tracked');
  final _randomFocusNode = FocusNode(debugLabel: 'library-random');
  final _settingsFocusNode = FocusNode(debugLabel: 'library-settings');
  final _filtersFocusNode = FocusNode(debugLabel: 'library-filters');

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.filter.query);
  }

  @override
  void didUpdateWidget(covariant LibraryToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only push an external query change (e.g. "Clear filters", or any
    // other future caller of `setQuery`) into the field when the
    // incoming filter's query itself changed since the last build. This
    // widget rebuilds on every unrelated `LibraryState` change too (a
    // page landing, a phase flip) — comparing against `oldWidget` rather
    // than unconditionally syncing on every rebuild is what keeps those
    // from clobbering text the user is mid-typing under the debounce,
    // which updates `_searchController.text` immediately but doesn't
    // reach `widget.filter.query` until the debounce fires.
    if (widget.filter.query != oldWidget.filter.query &&
        widget.filter.query != _searchController.text) {
      _searchController.text = widget.filter.query;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _sortFocusNode.dispose();
    _directionFocusNode.dispose();
    _minimumRatingFocusNode.dispose();
    _organizedFocusNode.dispose();
    _hideTrackedFocusNode.dispose();
    _randomFocusNode.dispose();
    _settingsFocusNode.dispose();
    _filtersFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      widget.onQueryChanged(value);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= libraryToolbarWideBreakpoint;
      if (wide) {
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(width: 260, child: _searchField()),
            _sortDropdown(),
            _directionToggle(),
            _minimumRatingDropdown(),
            _organizedControl(),
            _hideTrackedControl(),
            _playRandomButton(),
            _settingsButton(),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: _searchField()),
          const SizedBox(width: 8),
          _filtersMenu(),
          const SizedBox(width: 8),
          _playRandomButton(),
          const SizedBox(width: 8),
          _settingsButton(),
        ],
      );
    },
  );

  Widget _searchField() => TextField(
    key: const Key('library-search'),
    focusNode: _searchFocusNode,
    controller: _searchController,
    onChanged: _onSearchChanged,
    decoration: const InputDecoration(
      isDense: true,
      prefixIcon: Icon(Icons.search),
      hintText: 'Search scenes',
      labelText: 'Search',
    ),
  );

  Widget _sortDropdown() => DropdownButton<SceneSort>(
    focusNode: _sortFocusNode,
    value: widget.filter.sort,
    onChanged: (value) {
      if (value != null) widget.onSortChanged(value);
    },
    items: SceneSort.values
        .map(
          (sort) =>
              DropdownMenuItem(value: sort, child: Text(_sortLabel(sort))),
        )
        .toList(growable: false),
  );

  Widget _directionToggle() {
    final ascending = widget.filter.direction == SortDirection.ascending;
    return Tooltip(
      message: ascending ? 'Sort ascending' : 'Sort descending',
      child: IconButton(
        focusNode: _directionFocusNode,
        icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
        onPressed: () => widget.onDirectionChanged(
          ascending ? SortDirection.descending : SortDirection.ascending,
        ),
      ),
    );
  }

  // `SceneFilter.minimumRating` is a raw `rating100` threshold (20 points
  // per "star"), not a 1-5 star count — see `http_stash_api.dart`'s
  // `_findScenesVariables`, which sends it straight through as
  // `rating100 > (minimumRating - 1)`. These option values mirror the
  // GTK client's own `pages/library.rs` rating filter for the same
  // reason.
  Widget _minimumRatingDropdown() => Tooltip(
    message: 'Minimum rating',
    child: DropdownButton<int?>(
      focusNode: _minimumRatingFocusNode,
      value: widget.filter.minimumRating,
      onChanged: widget.onMinimumRatingChanged,
      items: const [
        DropdownMenuItem(child: Text('Any rating')),
        DropdownMenuItem(value: 20, child: Text('1+ stars')),
        DropdownMenuItem(value: 40, child: Text('2+ stars')),
        DropdownMenuItem(value: 60, child: Text('3+ stars')),
        DropdownMenuItem(value: 80, child: Text('4+ stars')),
        DropdownMenuItem(value: 100, child: Text('5 stars')),
      ],
    ),
  );

  Widget _organizedControl() => Tooltip(
    message: switch (widget.filter.organized) {
      null => 'Organized: any',
      true => 'Organized: yes',
      false => 'Organized: no',
    },
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          focusNode: _organizedFocusNode,
          tristate: true,
          value: widget.filter.organized,
          onChanged: widget.onOrganizedChanged,
        ),
        const Text('Organized'),
      ],
    ),
  );

  Widget _hideTrackedControl() => Tooltip(
    message: 'Hide scenes that have already been played',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Hide tracked'),
        Switch(
          focusNode: _hideTrackedFocusNode,
          value: widget.filter.hideTracked,
          onChanged: widget.onHideTrackedChanged,
        ),
      ],
    ),
  );

  Widget _playRandomButton() => FilledButton.tonalIcon(
    focusNode: _randomFocusNode,
    onPressed: widget.onPlayRandom,
    icon: const Icon(Icons.shuffle),
    label: const Text('Play random'),
  );

  Widget _settingsButton() => Tooltip(
    message: 'Connection settings',
    child: IconButton(
      focusNode: _settingsFocusNode,
      icon: const Icon(Icons.settings_outlined),
      onPressed: widget.onOpenSettings,
    ),
  );

  Widget _filtersMenu() => MenuAnchor(
    builder: (context, controller, child) => Tooltip(
      message: 'Filters',
      child: IconButton(
        focusNode: _filtersFocusNode,
        icon: const Icon(Icons.tune),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    ),
    menuChildren: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sortDropdown(),
            const SizedBox(height: 8),
            _directionToggle(),
            const SizedBox(height: 8),
            _minimumRatingDropdown(),
            const SizedBox(height: 8),
            _organizedControl(),
            const SizedBox(height: 8),
            _hideTrackedControl(),
          ],
        ),
      ),
    ],
  );

  String _sortLabel(SceneSort sort) => switch (sort) {
    SceneSort.date => 'Date',
    SceneSort.title => 'Title',
    SceneSort.rating => 'Rating',
    SceneSort.playCount => 'Play count',
    SceneSort.duration => 'Duration',
    SceneSort.createdAt => 'Date added',
    SceneSort.updatedAt => 'Last updated',
    SceneSort.random => 'Random',
  };
}
