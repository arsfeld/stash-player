import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/scene_filter.dart';
import '../../ui/icons/app_icons.dart';
import '../../ui/menu/app_menu.dart';
import '../../ui/menu/native_menus.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/theme/platform_dialect.dart';
import '../../ui/widgets/filter_controls.dart';
import '../../ui/widgets/window_chrome.dart';

/// Width, in logical pixels, at and above which every control renders
/// directly in the strip. Below it only search, the filters trigger,
/// "Play random", Scan, Tasks and the main menu stay there; sort, direction,
/// minimum rating, organized and hide-tracked move into a collapsible
/// second row underneath, toggled by a "Filters" button. See
/// [LibraryToolbar]'s own doc for why that row is an ordinary descendant
/// rather than a popup.
const double libraryToolbarWideBreakpoint = 760;

/// Advances the tristate "organized" filter one step: any, yes, no, any.
///
/// The filter is tristate because Stash's own `organized` field is, and
/// the icon shows which of the three is active. Exposed as a top-level
/// function so the cycle can be tested without pumping a widget.
bool? cycleOrganized(bool? current) => switch (current) {
  null => true,
  true => false,
  false => null,
};

/// The library's filter/sort/paging controls, plus the Scan button and
/// Tasks popover trigger.
///
/// Purely presentational: it receives the active [filter] and forwards
/// every change through a typed callback — no business logic beyond the
/// 250 ms search debounce (cancelled on [dispose], so a timer can never
/// fire against a disposed widget's callbacks) lives here. Most callback
/// signatures intentionally match a [LibraryController] intent 1:1 so the
/// owning screen can pass the controller's methods straight through as
/// tear-offs; [tasksActive], [onScan] and [onOpenTasks] are the exception —
/// they belong to the tasks controller and the Tasks popover instead.
///
/// The secondary controls at a narrow width are an **in-tree collapsible
/// row**, not a [MenuAnchor] popup. An earlier version used `MenuAnchor`
/// for this — it looked keyboard-accessible (`Enter` on the trigger did
/// open it, and the opened items were findable), but a dedicated probe
/// showed `Tab` from the trigger jumps straight past the *entire open
/// overlay* to "Play random": `MenuAnchor`'s overlay is not part of the
/// same focus-traversal chain as the surrounding page, so nothing inside
/// it is reachable by sequential `Tab` at all. Keeping every control as a
/// normal descendant — just conditionally visible — keeps it in the
/// page's own [FocusTraversalGroup], where explicit [FocusTraversalOrder]
/// values below pin the required Tab sequence regardless of which
/// visual row a control currently renders in.
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
    required this.tasksActive,
    required this.onScan,
    required this.onOpenTasks,
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

  /// Whether Stash has work in flight: lights the Tasks dot and disables
  /// Scan.
  final bool tasksActive;

  /// Starts a scan. Null while one cannot start, which disables the button.
  final VoidCallback? onScan;

  /// Opens the Tasks popover, anchored to the context it is handed (the
  /// Tasks button's own).
  final void Function(BuildContext anchor) onOpenTasks;

  /// Opens connection settings. Offered as Preferences in GNOME's main
  /// menu at the end of the strip.
  final VoidCallback onOpenSettings;

  @override
  State<LibraryToolbar> createState() => _LibraryToolbarState();
}

class _LibraryToolbarState extends State<LibraryToolbar> {
  late final TextEditingController _searchController;
  Timer? _debounce;

  /// Whether the narrow-width secondary-controls row is expanded. Unused
  /// at/above [libraryToolbarWideBreakpoint], where every control always
  /// shows.
  bool _filtersOpen = false;

  final _searchFocusNode = FocusNode(debugLabel: 'library-search');
  final _sortFocusNode = FocusNode(debugLabel: 'library-sort');
  final _directionFocusNode = FocusNode(debugLabel: 'library-direction');
  final _minimumRatingFocusNode = FocusNode(
    debugLabel: 'library-minimum-rating',
  );
  final _organizedFocusNode = FocusNode(debugLabel: 'library-organized');
  final _hideTrackedFocusNode = FocusNode(debugLabel: 'library-hide-tracked');
  final _randomFocusNode = FocusNode(debugLabel: 'library-random');
  final _scanFocusNode = FocusNode(debugLabel: 'library-scan');
  final _tasksFocusNode = FocusNode(debugLabel: 'library-tasks');
  final _mainMenuFocusNode = FocusNode(debugLabel: 'library-main-menu');
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
    // Scan disables itself while work runs, including when its own Enter
    // just started a scan, and a disabled control gives up focus. Flutter
    // would hand it back to whatever held it last, which can be Play
    // random, where a second Enter navigates away. Tasks is where the new
    // dot lit up. Requested here, before the button's rebuild drops its
    // focusability, so the scope already has Tasks as its latest child.
    if (oldWidget.onScan != null &&
        widget.onScan == null &&
        _scanFocusNode.hasFocus) {
      _tasksFocusNode.requestFocus();
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
    _scanFocusNode.dispose();
    _tasksFocusNode.dispose();
    _mainMenuFocusNode.dispose();
    _filtersFocusNode.dispose();
    super.dispose();
  }

  /// GNOME apps keep Preferences in a primary menu in the header bar.
  /// macOS apps have no such button: Settings… lives in the app menu, which
  /// `AppMenuBar` provides.
  bool get _showsMainMenu =>
      PlatformDialect.of(context) == PlatformDialect.adwaita;

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      // The widget itself may have been unmounted between scheduling
      // this timer and it firing — `dispose()` above already cancels
      // the timer in that case, but this guard is cheap defense in
      // depth against ever reaching into a stale `widget.onQueryChanged`
      // once this State is no longer part of the tree.
      if (!mounted) return;
      widget.onQueryChanged(value);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= libraryToolbarWideBreakpoint;
      return FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppWindowChrome(
              children: wide ? _wideControls() : _narrowControls(),
            ),
            if (!wide && _filtersOpen) _secondaryRow(),
          ],
        ),
      );
    },
  );

  /// The strip at [libraryToolbarWideBreakpoint] and above.
  ///
  /// Tab order follows the visual order: the filter group, then Play
  /// random, then the search field, then Scan, Tasks and the main menu.
  /// That is what WCAG 2.4.3 asks for, and the two layouts read in
  /// different orders, so the order values belong to a layout rather than
  /// to a control. See [_narrowControls] for the other one.
  List<Widget> _wideControls() => [
    _ordered(1, _sortMenu()),
    const SizedBox(width: AppTokens.space2),
    _ordered(2, _directionToggle()),
    const SizedBox(width: AppTokens.space2),
    _ordered(3, _minimumRatingMenu()),
    const _StripSeparator(),
    _ordered(4, _organizedToggle()),
    const SizedBox(width: AppTokens.space2),
    _ordered(5, _hideTrackedToggle()),
    const SizedBox(width: AppTokens.space2),
    _ordered(6, _playRandomButton()),
    const SizedBox(width: AppTokens.space3),
    Expanded(child: _ordered(7, _searchField())),
    const SizedBox(width: AppTokens.space3),
    _ordered(8, _scanButton()),
    const SizedBox(width: AppTokens.space2),
    _ordered(9, _tasksButton()),
    if (_showsMainMenu) ...[
      const SizedBox(width: AppTokens.space2),
      _ordered(10, _mainMenuButton()),
    ],
  ];

  /// The strip below [libraryToolbarWideBreakpoint].
  ///
  /// Search leads here, because it is what renders first. The filters
  /// trigger is followed immediately by the controls it reveals
  /// ([_secondaryRow]'s 3 to 7) rather than by the rest of this row: Tab
  /// should walk into the row it has just opened, not step over it.
  List<Widget> _narrowControls() => [
    Expanded(child: _ordered(1, _searchField())),
    const SizedBox(width: AppTokens.space2),
    _ordered(2, _filtersToggleButton()),
    const SizedBox(width: AppTokens.space2),
    _ordered(8, _playRandomButton()),
    const SizedBox(width: AppTokens.space2),
    _ordered(9, _scanButton()),
    const SizedBox(width: AppTokens.space2),
    _ordered(10, _tasksButton()),
    if (_showsMainMenu) ...[
      const SizedBox(width: AppTokens.space2),
      _ordered(11, _mainMenuButton()),
    ],
  ];

  Widget _secondaryRow() => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTokens.space5,
      AppTokens.space3,
      AppTokens.space5,
      0,
    ),
    child: Wrap(
      spacing: AppTokens.space2,
      runSpacing: AppTokens.space2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _ordered(3, _sortMenu()),
        _ordered(4, _directionToggle()),
        _ordered(5, _minimumRatingMenu()),
        _ordered(6, _organizedToggle()),
        _ordered(7, _hideTrackedToggle()),
      ],
    ),
  );

  Widget _ordered(double order, Widget child) =>
      FocusTraversalOrder(order: NumericFocusOrder(order), child: child);

  Widget _searchField() => AppSearchField(
    fieldKey: const Key('library-search'),
    focusNode: _searchFocusNode,
    controller: _searchController,
    onChanged: _onSearchChanged,
  );

  Widget _sortMenu() => AppMenuButton<SceneSort>(
    focusNode: _sortFocusNode,
    tooltip: 'Sort by',
    value: widget.filter.sort,
    onChanged: widget.onSortChanged,
    items: [
      for (final sort in SceneSort.values)
        AppMenuItem(value: sort, label: _sortLabel(sort)),
    ],
  );

  Widget _directionToggle() {
    final ascending = widget.filter.direction == SortDirection.ascending;
    return AppIconToggle(
      focusNode: _directionFocusNode,
      icon: ascending ? AppIcon.sortAscending : AppIcon.sortDescending,
      tooltip: ascending ? 'Sort ascending' : 'Sort descending',
      semanticLabel: ascending ? 'Sort ascending' : 'Sort descending',
      selected: false,
      onPressed: () => widget.onDirectionChanged(
        ascending ? SortDirection.descending : SortDirection.ascending,
      ),
    );
  }

  // `SceneFilter.minimumRating` is a raw `rating100` threshold (20 points
  // per "star"), not a 1-5 star count. `http_stash_api.dart`'s
  // `_findScenesVariables` sends it straight through as
  // `rating100 > (minimumRating - 1)`. These values mirror the GTK
  // client's own rating filter for the same reason.
  //
  // 0 is the sentinel for "any": `AppMenuButton`'s type parameter is
  // non-nullable because a menu reports a null selection as a dismissal,
  // so a nullable "Any rating" entry could never be picked. It is mapped
  // back to `null` on the way out.
  Widget _minimumRatingMenu() => AppMenuButton<int>(
    focusNode: _minimumRatingFocusNode,
    tooltip: 'Minimum rating',
    value: widget.filter.minimumRating ?? 0,
    onChanged: (value) =>
        widget.onMinimumRatingChanged(value == 0 ? null : value),
    items: const [
      AppMenuItem(value: 0, label: 'Any rating'),
      AppMenuItem(value: 20, label: '1+ stars'),
      AppMenuItem(value: 40, label: '2+ stars'),
      AppMenuItem(value: 60, label: '3+ stars'),
      AppMenuItem(value: 80, label: '4+ stars'),
      AppMenuItem(value: 100, label: '5 stars'),
    ],
  );

  Widget _organizedToggle() {
    final organized = widget.filter.organized;
    return AppIconToggle(
      focusNode: _organizedFocusNode,
      icon: switch (organized) {
        null => AppIcon.organizedAny,
        true => AppIcon.organizedYes,
        false => AppIcon.organizedNo,
      },
      tooltip: switch (organized) {
        null => 'Organized: any',
        true => 'Organized: yes',
        false => 'Organized: no',
      },
      semanticLabel: switch (organized) {
        null => 'Organized filter: any',
        true => 'Organized filter: organized only',
        false => 'Organized filter: unorganized only',
      },
      selected: organized != null,
      onPressed: () => widget.onOrganizedChanged(cycleOrganized(organized)),
    );
  }

  Widget _hideTrackedToggle() => AppIconToggle(
    focusNode: _hideTrackedFocusNode,
    icon: AppIcon.eyeOff,
    tooltip: 'Hide scenes that have already been played',
    semanticLabel: 'Hide tracked scenes',
    selected: widget.filter.hideTracked,
    onPressed: () => widget.onHideTrackedChanged(!widget.filter.hideTracked),
  );

  Widget _playRandomButton() => AppIconAction(
    focusNode: _randomFocusNode,
    icon: AppIcon.shuffle,
    tooltip: 'Play random',
    semanticLabel: 'Play a random scene',
    onPressed: widget.onPlayRandom,
  );

  Widget _scanButton() => AppIconAction(
    focusNode: _scanFocusNode,
    icon: AppIcon.scan,
    tooltip: widget.onScan == null
        ? 'A task is already running'
        : 'Scan library for new files',
    semanticLabel: 'Scan library',
    onPressed: widget.onScan,
  );

  /// A [Builder], so the popover can be anchored to this button's own
  /// context rather than the whole strip's.
  Widget _tasksButton() {
    final label = widget.tasksActive
        ? 'Background tasks, running'
        : 'Background tasks';
    return Builder(
      builder: (anchor) => AppIconAction(
        focusNode: _tasksFocusNode,
        icon: AppIcon.tasks,
        tooltip: label,
        semanticLabel: label,
        badge: widget.tasksActive,
        onPressed: () => widget.onOpenTasks(anchor),
      ),
    );
  }

  /// GNOME's primary menu. It holds only Preferences for now. An About
  /// item would join it once the app has an About dialog on Linux.
  Widget _mainMenuButton() => Builder(
    builder: (anchor) => AppIconAction(
      focusNode: _mainMenuFocusNode,
      icon: AppIcon.mainMenu,
      tooltip: 'Main Menu',
      semanticLabel: 'Main menu',
      onPressed: () => unawaited(
        NativeMenusScope.of(anchor).show(
          anchor,
          AppMenu([
            AppMenuAction(
              label: 'Preferences',
              onSelected: widget.onOpenSettings,
            ),
          ]),
          globalRectOf(anchor),
        ),
      ),
    ),
  );

  Widget _filtersToggleButton() => AppIconToggle(
    focusNode: _filtersFocusNode,
    icon: AppIcon.filters,
    tooltip: 'Filters',
    semanticLabel: 'Show filters',
    selected: _filtersOpen,
    onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
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

/// A hairline between two groups of strip controls.
class _StripSeparator extends StatelessWidget {
  const _StripSeparator();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppTokens.space3),
    child: SizedBox(
      height: 18,
      child: VerticalDivider(
        width: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
  );
}
