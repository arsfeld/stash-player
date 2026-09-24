# macOS native toolbar and connection sheet — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS, replace the Flutter-drawn library toolbar with a real `NSToolbar` and the drawn connection dialog with a real AppKit sheet, both driven from Dart over method channels.

**Architecture:** Two new ports follow the `NativeMenus` pattern (`lib/ui/menu/native_menus.dart` + `lib/services/channel_native_menus.dart`).
- `NativeToolbar`: `LibraryToolbar` builds an `AppToolbar` spec, and `ChannelNativeToolbar` sends it to `NativeToolbarChannel.swift`.
- `ConnectionSheet`: `ConnectionSheetPresenter` keeps every rule in Dart, and `ChannelConnectionSheet` drives `ConnectionSheetChannel.swift`.

Linux and tests (which run as Android) get no native implementation and keep today's drawn widgets.

**Tech Stack:** Flutter 3.41, Dart, flutter_riverpod 2.6, Swift/AppKit (macOS 14 deployment target, CI builds with Xcode 16 on `macos-15`).

**Spec:** `docs/superpowers/specs/2026-09-24-macos-native-controls-design.md`

## Global Constraints

- Only macOS changes behaviour. With `defaultTargetPlatform` not macOS, both new providers are null and every existing test keeps passing unchanged.
- `lib/ui/` never imports Riverpod.
- No `Icons.*` anywhere in `lib/` (a test enforces it).
- Deployment target stays macOS 14.0. Any macOS 26 API must be inside both `#if compiler(>=6.2)` and `if #available(macOS 26.0, *)`, because CI compiles with Xcode 16 (Swift 6.1).
- Channel names: `stash_player/toolbar`, `stash_player/connection_sheet`.
- Gate before every commit: `nix develop .#flutter -c just flutter-check` (format, analyze with `--fatal-infos`, all tests), run from the repo root. Swift can't be compiled on Linux; the `Flutter macOS` CI job (`flutter build macos --debug`) is its compile check.
- Match the surrounding code: explanatory doc comments on public types, and the same comment density as `channel_native_menus.dart`.
- Commit messages: `feat(flutter): …` / `test(flutter): …` / `docs: …`, with no attribution trailer.

---

### Task 1: SF Symbol names on `AppIcon`

**Files:**
- Modify: `apps/flutter/lib/ui/icons/app_icons.dart`
- Test: `apps/flutter/test/ui/icons/app_icons_test.dart` (existing; add a test)

**Interfaces:**
- Produces: `String AppIcon.sfSymbol` (for example `AppIcon.tasks.sfSymbol == 'list.bullet.rectangle'`).

- [ ] **Step 1: Write the failing test.** Add to `app_icons_test.dart`:

```dart
test('every icon names an SF Symbol for native macOS surfaces', () {
  final symbolName = RegExp(r'^[a-z0-9]+(\.[a-z0-9]+)*$');
  for (final icon in AppIcon.values) {
    expect(icon.sfSymbol, matches(symbolName), reason: icon.name);
  }
});
```

- [ ] **Step 2: Run it and confirm it fails.** `cd apps/flutter && flutter test test/ui/icons/app_icons_test.dart` fails: `sfSymbol` isn't defined.

- [ ] **Step 3: Implement.** Give the constructor a required named `sf:` argument. Add a field:

```dart
  /// SF Symbol name, for surfaces AppKit draws itself (the native
  /// toolbar). Lucide stays the drawn macOS glyph.
  final String sfSymbol;
```

Change the constructor to `const AppIcon(this.gnome, this.lucide, {required String sf, this.lucideBadge}) : sfSymbol = sf;` and add `sf:` to every value:

| value | sf |
|---|---|
| back | `chevron.left` |
| dropdown | `chevron.down` |
| sortAscending | `arrow.up` |
| sortDescending | `arrow.down` |
| organizedAny | `circle.dashed` |
| organizedYes | `checkmark.circle` |
| organizedNo | `xmark.circle` |
| eye | `eye` |
| eyeOff | `eye.slash` |
| shuffle | `shuffle` |
| scan | `folder.badge.plus` |
| tasks | `list.bullet.rectangle` |
| mainMenu | `line.3.horizontal` |
| filters | `slider.horizontal.3` |
| clock | `clock` |
| warning | `exclamationmark.triangle` |
| done | `checkmark.circle` |
| quality | `tv` |
| info | `info.circle` |
| volumeMuted | `speaker.slash` |
| volumeHigh | `speaker.wave.3` |
| skipPrevious | `backward.end` |
| skipNext | `forward.end` |
| seekBack10 | `gobackward.10` |
| seekForward10 | `goforward.10` |
| play | `play` |
| pause | `pause` |
| playFilled | `play.circle.fill` |
| oCounter | `drop` |
| reset | `arrow.counterclockwise` |
| close | `xmark` |
| video | `film` |
| emptyLibrary | `film.stack` |
| error | `exclamationmark.circle` |
| star | `star` |
| search | `magnifyingglass` |

For example, `tasks('list', 'list-checks', sf: 'list.bullet.rectangle'),`. Also update the enum's doc comment ("each with its GNOME … and Lucide … source") so it mentions the SF Symbol name.

- [ ] **Step 4: Run the test and confirm it passes.** Then run the full gate: `nix develop .#flutter -c just flutter-check`.

- [ ] **Step 5: Commit.** `git commit -am "feat(flutter): name an SF Symbol for every AppIcon"`

---

### Task 2: Toolbar spec, `NativeToolbar` port and `ChannelNativeToolbar`

**Files:**
- Create: `apps/flutter/lib/ui/toolbar/app_toolbar.dart`
- Create: `apps/flutter/lib/ui/toolbar/native_toolbar.dart`
- Create: `apps/flutter/lib/services/channel_native_toolbar.dart`
- Modify: `apps/flutter/lib/app/providers.dart` (add `nativeToolbarProvider`)
- Modify: `apps/flutter/lib/app/app.dart` (provide `NativeToolbarScope`)
- Create: `apps/flutter/test/services/channel_native_toolbar_test.dart`
- Create: `apps/flutter/test/support/recording_toolbar.dart`

**Interfaces:**
- Consumes: `AppIcon.sfSymbol` (Task 1), `logDiagnostic(String channel, String message)` from `lib/shared/diagnostics.dart`.
- Produces:
  - `sealed class AppToolbarItem { String id; String label; String? tooltip; }`
  - `AppToolbarMenu({id, label, tooltip, required List<String> options, required int selected, required ValueChanged<int> onSelected})`
  - `AppToolbarToggle({id, label, tooltip, required AppIcon icon, required bool selected, required VoidCallback onPressed})`
  - `AppToolbarAction({id, label, tooltip, required AppIcon icon, required void Function(Rect? anchor)? onPressed, bool badge = false})`
  - `AppToolbarSearch({id, label, required String text, String placeholder = '', required ValueChanged<String> onChanged})`
  - `AppToolbarGroup({id, label, required List<AppToolbarItem> children})`
  - `AppToolbarSpace({String id = 'flexible-space'})`
  - `class AppToolbar { const AppToolbar(this.items); static const empty; }`
  - `abstract interface class NativeToolbar { Future<bool> set(AppToolbar toolbar); }`
  - `class NativeToolbarScope extends InheritedWidget { static NativeToolbar? maybeOf(BuildContext) }`
  - `class ChannelNativeToolbar implements NativeToolbar { ChannelNativeToolbar({MethodChannel channel}); Future<void> reset(); }`
  - `Provider<NativeToolbar?> nativeToolbarProvider`
  - test support: `class RecordingToolbar implements NativeToolbar { List<AppToolbar> sent; bool available; AppToolbar get last; T item<T extends AppToolbarItem>(String id); }`

- [ ] **Step 1: Write the spec types.** Create `lib/ui/toolbar/app_toolbar.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Rect;

import '../icons/app_icons.dart';

/// One item in an [AppToolbar]: what a window toolbar shows, described
/// once in Dart and built by the platform (an `NSToolbar` on macOS; see
/// `NativeToolbarChannel.swift`).
///
/// [id] must be stable across rebuilds. The native side reconciles by it,
/// so an item whose id and kind are unchanged is updated in place rather
/// than recreated. [label] names the item for accessibility and the
/// overflow menu; [tooltip] defaults to it.
@immutable
sealed class AppToolbarItem {
  const AppToolbarItem({required this.id, required this.label, this.tooltip});

  final String id;
  final String label;
  final String? tooltip;
}

/// A pop-up of [options], the one at [selected] checked and shown as the
/// item's title.
final class AppToolbarMenu extends AppToolbarItem {
  const AppToolbarMenu({
    required super.id,
    required super.label,
    required this.options,
    required this.selected,
    required this.onSelected,
    super.tooltip,
  });

  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelected;
}

/// An icon button that shows an on/off state.
final class AppToolbarToggle extends AppToolbarItem {
  const AppToolbarToggle({
    required super.id,
    required super.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    super.tooltip,
  });

  final AppIcon icon;
  final bool selected;
  final VoidCallback onPressed;
}

/// An icon button that performs an action. A null [onPressed] disables
/// it.
///
/// [onPressed] gets the item's frame in the Flutter view's logical
/// coordinates (top-left origin), for anchoring a drawn popover under
/// it, or null when the item was chosen some other way (from the
/// overflow menu, or with the keyboard). [badge] marks it as having
/// something waiting behind it.
final class AppToolbarAction extends AppToolbarItem {
  const AppToolbarAction({
    required super.id,
    required super.label,
    required this.icon,
    required this.onPressed,
    this.badge = false,
    super.tooltip,
  });

  final AppIcon icon;
  final void Function(Rect? anchor)? onPressed;
  final bool badge;
}

/// A search field. [text] is applied to the native field only while the
/// user isn't editing it, so a republish can't overwrite a newer
/// keystroke.
final class AppToolbarSearch extends AppToolbarItem {
  const AppToolbarSearch({
    required super.id,
    required super.label,
    required this.text,
    required this.onChanged,
    this.placeholder = '',
    super.tooltip,
  });

  final String text;
  final String placeholder;
  final ValueChanged<String> onChanged;
}

/// Menus, toggles and actions drawn as one control group (one capsule on
/// macOS 26 and later).
final class AppToolbarGroup extends AppToolbarItem {
  AppToolbarGroup({
    required super.id,
    required super.label,
    required this.children,
    super.tooltip,
  }) : assert(
         children.every(
           (child) =>
               child is AppToolbarMenu ||
               child is AppToolbarToggle ||
               child is AppToolbarAction,
         ),
         'a group holds only menus, toggles and actions',
       );

  final List<AppToolbarItem> children;
}

/// Space that grows to push the items after it to the trailing edge.
final class AppToolbarSpace extends AppToolbarItem {
  const AppToolbarSpace({super.id = 'flexible-space'}) : super(label: '');
}

/// A window toolbar's items, leading to trailing.
@immutable
class AppToolbar {
  const AppToolbar(this.items);

  /// No items: the titlebar alone.
  static const empty = AppToolbar([]);

  final List<AppToolbarItem> items;
}
```

- [ ] **Step 2: Write the port.** Create `lib/ui/toolbar/native_toolbar.dart`:

```dart
import 'package:flutter/widgets.dart';

import 'app_toolbar.dart';

/// Shows an [AppToolbar] as the window's own toolbar.
abstract interface class NativeToolbar {
  /// Replaces the toolbar's items with [toolbar]. [AppToolbar.empty]
  /// leaves the bare titlebar.
  ///
  /// Completes with false when the native side is unavailable; the caller
  /// then draws its own controls instead.
  Future<bool> set(AppToolbar toolbar);
}

/// Provides the app's [NativeToolbar] to `lib/ui/` and feature widgets
/// without Riverpod. With no scope (Linux, and most widget tests)
/// [maybeOf] is null and the toolbar is drawn in Flutter.
class NativeToolbarScope extends InheritedWidget {
  const NativeToolbarScope({
    required this.toolbar,
    required super.child,
    super.key,
  });

  final NativeToolbar toolbar;

  /// Registers no dependency: the scope is fixed for the app's lifetime.
  static NativeToolbar? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NativeToolbarScope>()?.toolbar;

  @override
  bool updateShouldNotify(NativeToolbarScope oldWidget) =>
      toolbar != oldWidget.toolbar;
}
```

- [ ] **Step 3: Write the failing channel tests.** Create `test/services/channel_native_toolbar_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/channel_native_toolbar.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';
import 'package:stash_player_flutter/ui/toolbar/app_toolbar.dart';

const _channel = MethodChannel('stash_player/toolbar');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> sent;
  late List<String> events;

  setUp(() {
    sent = [];
    events = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  AppToolbar spec({bool badge = false, String text = ''}) => AppToolbar([
    AppToolbarGroup(
      id: 'filters',
      label: 'Filters',
      children: [
        AppToolbarMenu(
          id: 'sort',
          label: 'Sort by',
          options: const ['Date', 'Title'],
          selected: 1,
          onSelected: (index) => events.add('sort $index'),
        ),
        AppToolbarToggle(
          id: 'hide',
          label: 'Hide played',
          icon: AppIcon.eyeOff,
          selected: true,
          onPressed: () => events.add('hide'),
        ),
      ],
    ),
    const AppToolbarSpace(),
    AppToolbarSearch(
      id: 'search',
      label: 'Search',
      text: text,
      placeholder: 'Search scenes',
      onChanged: (value) => events.add('search $value'),
    ),
    AppToolbarAction(
      id: 'tasks',
      label: 'Background tasks',
      icon: AppIcon.tasks,
      badge: badge,
      onPressed: (anchor) => events.add('tasks $anchor'),
    ),
    const AppToolbarAction(
      id: 'scan',
      label: 'Scan',
      icon: AppIcon.scan,
      onPressed: null,
    ),
  ]);

  Future<void> deliver(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('serializes every item kind', () async {
    expect(await ChannelNativeToolbar().set(spec(badge: true)), isTrue);

    expect(sent.single.method, 'setItems');
    final items = (sent.single.arguments as List).cast<Map>();
    expect(items.map((item) => item['type']), [
      'group',
      'space',
      'search',
      'action',
      'action',
    ]);
    final children = (items[0]['children'] as List).cast<Map>();
    expect(children[0], {
      'type': 'menu',
      'id': 'sort',
      'label': 'Sort by',
      'tooltip': 'Sort by',
      'options': ['Date', 'Title'],
      'selected': 1,
    });
    expect(children[1], {
      'type': 'toggle',
      'id': 'hide',
      'label': 'Hide played',
      'tooltip': 'Hide played',
      'symbol': 'eye.slash',
      'selected': true,
    });
    expect(items[2], containsPair('placeholder', 'Search scenes'));
    expect(items[3], containsPair('badge', true));
    expect(items[3], containsPair('symbol', 'list.bullet.rectangle'));
    expect(items[4], containsPair('enabled', false));
  });

  test('drops a spec identical to the last one sent', () async {
    final toolbar = ChannelNativeToolbar();
    await toolbar.set(spec());
    await toolbar.set(spec());
    await toolbar.set(spec(badge: true));

    expect(sent, hasLength(2));
  });

  test('routes native events to the current callbacks', () async {
    await ChannelNativeToolbar().set(spec());

    await deliver('menuSelected', {'id': 'sort', 'index': 0});
    await deliver('activated', {'id': 'hide'});
    await deliver('searchChanged', {'id': 'search', 'text': 'kyoto'});
    await deliver('activated', {
      'id': 'tasks',
      'rect': {'x': 10.0, 'y': 0.0, 'width': 28.0, 'height': 52.0},
    });
    await deliver('activated', {'id': 'tasks'});

    expect(events, [
      'sort 0',
      'hide',
      'search kyoto',
      'tasks ${const Rect.fromLTWH(10, 0, 28, 52)}',
      'tasks null',
    ]);
  });

  test('ignores unknown ids, disabled actions and bad indexes', () async {
    await ChannelNativeToolbar().set(spec());

    await deliver('activated', {'id': 'gone'});
    await deliver('activated', {'id': 'scan'});
    await deliver('menuSelected', {'id': 'sort', 'index': 7});

    expect(events, isEmpty);
  });

  test('reports unavailable and stops sending when the plugin is missing',
      () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final toolbar = ChannelNativeToolbar();

    expect(await toolbar.set(spec()), isFalse);
    expect(await toolbar.set(spec(badge: true)), isFalse);
  });
}
```

- [ ] **Step 4: Run them and confirm they fail.** `flutter test test/services/channel_native_toolbar_test.dart` fails because `ChannelNativeToolbar` doesn't exist yet.

- [ ] **Step 5: Implement the channel.** Create `lib/services/channel_native_toolbar.dart`:

```dart
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

import '../shared/diagnostics.dart';
import '../ui/toolbar/app_toolbar.dart';
import '../ui/toolbar/native_toolbar.dart';

/// Shows [AppToolbar]s as the window's `NSToolbar` over the
/// `stash_player/toolbar` channel (`NativeToolbarChannel.swift`).
///
/// Only ids, labels, symbols and state cross the channel. Callbacks stay
/// here in an id → item table that each [set] replaces, so an event for
/// an item that has since gone runs nothing. A spec identical to the last
/// one sent is dropped, which lets a caller publish after every build.
///
/// If the native side is missing or fails, [set] reports false from then
/// on and logs once, and the caller draws its own controls.
class ChannelNativeToolbar implements NativeToolbar {
  ChannelNativeToolbar({
    MethodChannel channel = const MethodChannel('stash_player/toolbar'),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  Map<String, AppToolbarItem> _items = const {};
  String? _lastSent;
  bool _unavailable = false;

  /// Asks the runner to drop whatever a previous isolate left in the
  /// toolbar (a hot restart). Failures are ignored: [set] reports them.
  Future<void> reset() async {
    try {
      await _channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // No runner support: nothing to reset.
    } on PlatformException {
      // Same.
    }
  }

  @override
  Future<bool> set(AppToolbar toolbar) async {
    if (_unavailable) return false;
    final items = <String, AppToolbarItem>{};
    final encoded = [
      for (final item in toolbar.items) _encode(item, items),
    ];
    _items = items;
    final fingerprint = jsonEncode(encoded);
    if (fingerprint == _lastSent) return true;
    try {
      await _channel.invokeMethod<void>('setItems', encoded);
      _lastSent = fingerprint;
      return true;
    } on Object catch (error) {
      if (error is! MissingPluginException && error is! PlatformException) {
        rethrow;
      }
      _unavailable = true;
      logDiagnostic('toolbar', 'native toolbar unavailable, drawing: $error');
      return false;
    }
  }

  Map<String, Object?> _encode(
    AppToolbarItem item,
    Map<String, AppToolbarItem> index,
  ) {
    index[item.id] = item;
    final base = <String, Object?>{
      'id': item.id,
      'label': item.label,
      'tooltip': item.tooltip ?? item.label,
    };
    return switch (item) {
      AppToolbarMenu() => {
        'type': 'menu',
        ...base,
        'options': item.options,
        'selected': item.selected,
      },
      AppToolbarToggle() => {
        'type': 'toggle',
        ...base,
        'symbol': item.icon.sfSymbol,
        'selected': item.selected,
      },
      AppToolbarAction() => {
        'type': 'action',
        ...base,
        'symbol': item.icon.sfSymbol,
        'enabled': item.onPressed != null,
        'badge': item.badge,
      },
      AppToolbarSearch() => {
        'type': 'search',
        ...base,
        'text': item.text,
        'placeholder': item.placeholder,
      },
      AppToolbarGroup() => {
        'type': 'group',
        ...base,
        'children': [for (final child in item.children) _encode(child, index)],
      },
      AppToolbarSpace() => {'type': 'space', 'id': item.id},
    };
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final item = _items[args['id']];
    switch ((call.method, item)) {
      case ('activated', AppToolbarAction(:final onPressed?)):
        onPressed(_rect(args['rect']));
      case ('activated', AppToolbarToggle(:final onPressed)):
        onPressed();
      case ('menuSelected', AppToolbarMenu(:final options, :final onSelected)):
        final index = args['index'];
        if (index is int && index >= 0 && index < options.length) {
          onSelected(index);
        }
      case ('searchChanged', AppToolbarSearch(:final onChanged)):
        final text = args['text'];
        if (text is String) onChanged(text);
      default:
        break;
    }
    return null;
  }

  static Rect? _rect(Object? value) {
    if (value is! Map) return null;
    double at(String key) => (value[key] as num?)?.toDouble() ?? 0;
    return Rect.fromLTWH(at('x'), at('y'), at('width'), at('height'));
  }
}
```

The menu tuple pattern in the test above expects `'tooltip'` to equal the label when no tooltip is set. `_encode` puts `type` first, and map equality ignores key order.

- [ ] **Step 6: Run the tests and confirm they pass.** `flutter test test/services/channel_native_toolbar_test.dart`

- [ ] **Step 7: Add the recording fake.** Create `test/support/recording_toolbar.dart`:

```dart
import 'package:stash_player_flutter/ui/toolbar/app_toolbar.dart';
import 'package:stash_player_flutter/ui/toolbar/native_toolbar.dart';

/// A [NativeToolbar] that records every spec it is handed. With
/// [available] false it reports the native side missing, as the channel
/// does.
class RecordingToolbar implements NativeToolbar {
  RecordingToolbar({this.available = true});

  bool available;
  final List<AppToolbar> sent = [];

  AppToolbar get last => sent.last;

  /// The item with [id] in the last spec, searching inside groups.
  T item<T extends AppToolbarItem>(String id) {
    Iterable<AppToolbarItem> flatten(List<AppToolbarItem> items) sync* {
      for (final item in items) {
        yield item;
        if (item is AppToolbarGroup) yield* flatten(item.children);
      }
    }

    return flatten(last.items).firstWhere((item) => item.id == id) as T;
  }

  @override
  Future<bool> set(AppToolbar toolbar) async {
    sent.add(toolbar);
    return available;
  }
}
```

- [ ] **Step 8: Wire the provider and the scope.** In `lib/app/providers.dart`, next to `nativeMenusProvider`, add the provider below, along with the imports `../services/channel_native_toolbar.dart`, `../ui/toolbar/native_toolbar.dart` and `dart:async` (for `unawaited`) if they aren't already there:

```dart
/// The window toolbar the library publishes its controls to: the real
/// `NSToolbar` on macOS, none elsewhere (Linux draws its own strip, and
/// tests run as Android).
final nativeToolbarProvider = Provider<NativeToolbar?>((ref) {
  if (defaultTargetPlatform != TargetPlatform.macOS) return null;
  final toolbar = ChannelNativeToolbar();
  unawaited(toolbar.reset());
  return toolbar;
});
```

In `lib/app/app.dart`, watch it in `build` (`final nativeToolbar = ref.watch(nativeToolbarProvider);`) and wrap the builder's child:

```dart
        builder: (context, child) {
          final content = NativeMenusScope(
            menus: nativeMenus,
            child: ToastHost(child: child!),
          );
          return nativeToolbar == null
              ? content
              : NativeToolbarScope(toolbar: nativeToolbar, child: content);
        },
```

- [ ] **Step 9: Run the gate.** `nix develop .#flutter -c just flutter-check` passes.

- [ ] **Step 10: Commit.**

```bash
git add apps/flutter/lib/ui/toolbar apps/flutter/lib/services/channel_native_toolbar.dart apps/flutter/lib/app/providers.dart apps/flutter/lib/app/app.dart apps/flutter/test/services/channel_native_toolbar_test.dart apps/flutter/test/support/recording_toolbar.dart
git commit -m "feat(flutter): toolbar spec and a native-toolbar channel port"
```

---

### Task 3: `LibraryToolbar` publishes to the native toolbar

**Files:**
- Modify: `apps/flutter/lib/features/library/library_toolbar.dart`
- Modify: `apps/flutter/lib/features/library/library_screen.dart`
- Modify: `apps/flutter/lib/features/library/tasks_popover.dart`
- Modify: `apps/flutter/integration_test/connection_library_scene_test.dart`
- Test: `apps/flutter/test/features/library/library_screen_test.dart` (existing; add a group)

**Interfaces:**
- Consumes: everything Task 2 produced, plus `RecordingToolbar`.
- Produces:
  - `LibraryToolbar.publishNative` (a `bool`, default `true`)
  - `LibraryToolbar.onOpenTasks` changes type to `void Function(BuildContext context, Rect anchor)`
  - `Future<void> showTasksPopoverAt(BuildContext context, Rect anchor)` (`anchor` in global logical coordinates)

Toolbar ids are `filters` (the group), `sort`, `direction`, `minimum-rating`, `organized`, `hide-tracked`, `play-random`, `flexible-space`, `search`, `scan` and `tasks`.

- [ ] **Step 1: Write the failing tests.** In `library_screen_test.dart`, give `_pumpLibrary` a `NativeToolbar? toolbar` parameter and wrap `home` in `NativeToolbarScope(toolbar: toolbar, child: …)` when it's non-null (keep the existing `menus` wrapping). Then add:

```dart
group('native toolbar (macOS)', () {
  testWidgets('publishes the controls and draws none of its own', (
    tester,
  ) async {
    final toolbar = RecordingToolbar();
    await _pumpLibrary(tester, api: _api(), toolbar: toolbar);
    await tester.pump();

    expect(
      toolbar.last.items.map((item) => item.id),
      ['filters', 'play-random', 'flexible-space', 'search', 'scan', 'tasks'],
    );
    expect(
      toolbar.item<AppToolbarGroup>('filters').children.map((i) => i.id),
      ['sort', 'direction', 'minimum-rating', 'organized', 'hide-tracked'],
    );
    expect(find.byType(AppMenuButton<SceneSort>), findsNothing);
    expect(find.byKey(const Key('library-search')), findsNothing);
  });

  testWidgets('routes toolbar events to the library controller', (
    tester,
  ) async {
    final toolbar = RecordingToolbar();
    final harness = await _pumpLibrary(tester, api: _api(), toolbar: toolbar);
    await tester.pump();

    final sort = toolbar.item<AppToolbarMenu>('sort');
    sort.onSelected(SceneSort.values.indexOf(SceneSort.title));
    toolbar.item<AppToolbarToggle>('hide-tracked').onPressed();
    await tester.pump();

    expect(harness.controller.state.filter.sort, SceneSort.title);
    expect(harness.controller.state.filter.hideTracked, isTrue);
    expect(
      toolbar.item<AppToolbarMenu>('sort').selected,
      SceneSort.values.indexOf(SceneSort.title),
    );
    expect(toolbar.item<AppToolbarToggle>('hide-tracked').selected, isTrue);
  });

  testWidgets('debounces native search and keeps the typed text', (
    tester,
  ) async {
    final toolbar = RecordingToolbar();
    final harness = await _pumpLibrary(tester, api: _api(), toolbar: toolbar);
    await tester.pump();

    toolbar.item<AppToolbarSearch>('search').onChanged('kyo');
    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.controller.state.filter.query, '');
    await tester.pump(const Duration(milliseconds: 200));
    expect(harness.controller.state.filter.query, 'kyo');
    expect(toolbar.item<AppToolbarSearch>('search').text, 'kyo');
  });

  testWidgets('falls back to the drawn strip when the native side is '
      'missing', (tester) async {
    final toolbar = RecordingToolbar(available: false);
    await _pumpLibrary(tester, api: _api(), toolbar: toolbar);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('library-search')), findsOneWidget);
  });

  testWidgets('clears the toolbar when a scene opens', (tester) async {
    final toolbar = RecordingToolbar();
    final harness = await _pumpLibrary(tester, api: _api(), toolbar: toolbar);
    await tester.pump();

    harness.container
        .read(appControllerProvider.notifier)
        .openScene('1', browse: null);
    await tester.pump();

    expect(toolbar.last.items, isEmpty);
  });
});
```

Use whatever helper the file already has for a `FakeStashApi` with one page of scenes in place of `_api()`. Check `AppController.openScene`'s real signature in `lib/app/app_controller.dart` and match it; `browse` may be required and non-null. If the container has no `appControllerProvider` state that allows `openScene`, set the destination through the notifier's existing public API. Imports: `native_toolbar.dart`, `app_toolbar.dart`, `recording_toolbar.dart`, `domain/scene_filter.dart`, `app/app_controller.dart`.

- [ ] **Step 2: Run them and confirm they fail.** `flutter test test/features/library/library_screen_test.dart` fails: the `toolbar` parameter and the published items don't exist yet.

- [ ] **Step 3: Anchor the tasks popover to a rect.** In `tasks_popover.dart`, split `showTasksPopover`:

```dart
/// Opens the Tasks popover under [anchor], which must be the Tasks
/// button's own context. See [showTasksPopoverAt].
Future<void> showTasksPopover(BuildContext anchor) =>
    showTasksPopoverAt(anchor, globalRectOf(anchor));

/// Opens the Tasks popover under [anchor], a rect in global logical
/// coordinates: the drawn Tasks button's, or the native toolbar item's
/// as `NativeToolbarChannel.swift` reports it. Tells
/// [tasksControllerProvider] it is open until it closes.
///
/// (Keep the existing paragraph about why this is a route.)
Future<void> showTasksPopoverAt(BuildContext context, Rect anchor) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final anchorRect = Rect.fromPoints(
    overlay.globalToLocal(anchor.topLeft),
    overlay.globalToLocal(anchor.bottomRight),
  );
  // …the rest of the existing body unchanged, from popoverOpened() on,
  // using `context` where it used `anchor`.
}
```

Import `globalRectOf` from `../../ui/menu/native_menus.dart`.

- [ ] **Step 4: Publish from `LibraryToolbar`.** In `library_toolbar.dart`:

1. Change `onOpenTasks` to `final void Function(BuildContext context, Rect anchor) onOpenTasks;`. Update its doc comment: "Opens the Tasks popover under [anchor], in global logical coordinates." In `_tasksButton`, call `widget.onOpenTasks(anchor, globalRectOf(anchor))`.
2. Add a constructor parameter `this.publishNative = true` with the doc comment: "Whether this toolbar's controls should be in the native window toolbar right now. False while a scene covers the library, which keeps the library page mounted underneath. Ignored when there's no `NativeToolbarScope`."
3. Hoist the rating options out of `_minimumRatingMenu` into `static const _ratingOptions = [AppMenuItem(value: 0, label: 'Any rating'), …]` (the same six entries), and have `_minimumRatingMenu` use it.
4. Add the state fields and lifecycle:

```dart
  /// The native window toolbar, when the app has one (macOS).
  NativeToolbar? _native;

  /// Set once the native toolbar reports itself unavailable. The strip
  /// is drawn from then on.
  bool _nativeFailed = false;

  bool _publishScheduled = false;

  bool get _usesNative => _native != null && !_nativeFailed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _native = NativeToolbarScope.maybeOf(context);
  }
```

In `dispose`, before `super.dispose()`: `if (_usesNative) unawaited(_native!.set(AppToolbar.empty));`

5. Publish after each build:

```dart
  /// Sends the current spec after this frame. Coalesced to one send per
  /// frame, and the channel itself drops a spec identical to the last.
  void _schedulePublish() {
    if (_publishScheduled) return;
    _publishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _publishScheduled = false;
      if (!mounted || !_usesNative) return;
      final ok = await _native!.set(
        widget.publishNative ? _nativeSpec() : AppToolbar.empty,
      );
      if (!ok && mounted) setState(() => _nativeFailed = true);
    });
  }
```

6. At the top of `build`'s `LayoutBuilder` builder (before `final wide`), add:

```dart
      if (_usesNative) {
        _schedulePublish();
        // The titlebar band stays Flutter's (it also moves the window);
        // the controls in it are AppKit's.
        return const AppWindowChrome(children: []);
      }
```

7. Add the spec builder:

```dart
  /// This toolbar as native items: the filter controls as one group,
  /// then Play random, search pushed to the trailing side, Scan and
  /// Tasks. No main menu: on macOS, Settings… is in the app menu.
  AppToolbar _nativeSpec() {
    final filter = widget.filter;
    final ascending = filter.direction == SortDirection.ascending;
    final organized = filter.organized;
    final ratingIndex = _ratingOptions.indexWhere(
      (option) => option.value == (filter.minimumRating ?? 0),
    );
    return AppToolbar([
      AppToolbarGroup(
        id: 'filters',
        label: 'Filters',
        children: [
          AppToolbarMenu(
            id: 'sort',
            label: 'Sort by',
            options: [for (final sort in SceneSort.values) _sortLabel(sort)],
            selected: SceneSort.values.indexOf(filter.sort),
            onSelected: (index) =>
                widget.onSortChanged(SceneSort.values[index]),
          ),
          AppToolbarAction(
            id: 'direction',
            label: ascending ? 'Sort ascending' : 'Sort descending',
            icon: ascending ? AppIcon.sortAscending : AppIcon.sortDescending,
            onPressed: (_) => widget.onDirectionChanged(
              ascending ? SortDirection.descending : SortDirection.ascending,
            ),
          ),
          AppToolbarMenu(
            id: 'minimum-rating',
            label: 'Minimum rating',
            options: [for (final option in _ratingOptions) option.label],
            selected: ratingIndex < 0 ? 0 : ratingIndex,
            onSelected: (index) {
              final value = _ratingOptions[index].value;
              widget.onMinimumRatingChanged(value == 0 ? null : value);
            },
          ),
          AppToolbarToggle(
            id: 'organized',
            label: switch (organized) {
              null => 'Organized: any',
              true => 'Organized: yes',
              false => 'Organized: no',
            },
            icon: switch (organized) {
              null => AppIcon.organizedAny,
              true => AppIcon.organizedYes,
              false => AppIcon.organizedNo,
            },
            selected: organized != null,
            onPressed: () =>
                widget.onOrganizedChanged(cycleOrganized(organized)),
          ),
          AppToolbarToggle(
            id: 'hide-tracked',
            label: 'Hide played',
            tooltip: 'Hide scenes that have already been played',
            icon: AppIcon.eyeOff,
            selected: filter.hideTracked,
            onPressed: () => widget.onHideTrackedChanged(!filter.hideTracked),
          ),
        ],
      ),
      AppToolbarAction(
        id: 'play-random',
        label: 'Play random',
        icon: AppIcon.shuffle,
        onPressed: (_) => widget.onPlayRandom(),
      ),
      const AppToolbarSpace(),
      AppToolbarSearch(
        id: 'search',
        label: 'Search',
        placeholder: 'Search scenes',
        text: _searchController.text,
        onChanged: (text) {
          // Mirrored here first, so a publish before the debounce fires
          // carries the typed text rather than the stale query.
          _searchController.text = text;
          _onSearchChanged(text);
        },
      ),
      AppToolbarAction(
        id: 'scan',
        label: 'Scan library',
        tooltip: widget.onScan == null
            ? 'A task is already running'
            : 'Scan library for new files',
        icon: AppIcon.scan,
        onPressed: widget.onScan == null ? null : (_) => widget.onScan!(),
      ),
      AppToolbarAction(
        id: 'tasks',
        label: 'Background tasks',
        tooltip: widget.tasksActive
            ? 'Background tasks, running'
            : 'Background tasks',
        icon: AppIcon.tasks,
        badge: widget.tasksActive,
        onPressed: (anchor) =>
            widget.onOpenTasks(context, anchor ?? _trailingAnchor()),
      ),
    ]);
  }

  /// Where the Tasks popover hangs when the item was chosen without a
  /// click to locate it (from the overflow menu, or with the keyboard):
  /// the window's trailing edge, under the titlebar.
  Rect _trailingAnchor() {
    final width = MediaQuery.sizeOf(context).width;
    return Rect.fromLTWH(
      width - AppTokens.stripInset - AppTokens.controlBandHeight,
      0,
      AppTokens.controlBandHeight,
      AppWindowChrome.stripHeightFor(TargetPlatform.macOS),
    );
  }
```

Imports: `../../ui/toolbar/app_toolbar.dart`, `../../ui/toolbar/native_toolbar.dart`, `../../ui/menu/native_menus.dart` (for `globalRectOf`; the file may already import it for the main menu).

8. Update the class doc comment: add a paragraph saying that on macOS (with a `NativeToolbarScope`) the controls are published to the window's `NSToolbar` instead of being drawn, that AppKit's overflow replaces the narrow layout there, and that the drawn strip returns if the native side is unavailable.

- [ ] **Step 5: Wire the screen.** In `library_screen.dart`'s `LibraryToolbar(...)`:

```dart
            publishNative: ref.watch(
              appControllerProvider.select((d) => d is! SceneDestination),
            ),
            onOpenTasks: showTasksPopoverAt,
```

(Replace `onOpenTasks: showTasksPopover`.) Import `SceneDestination` from `../../app/app_controller.dart` if the existing import doesn't cover it.

- [ ] **Step 6: Run the tests and confirm they pass.** `flutter test test/features/library/` and `test/features/library/tasks_popover_test.dart`. Fix any existing test that calls `LibraryToolbar(onOpenTasks: …)` or `showTasksPopover` against the old signature.

- [ ] **Step 7: Keep the integration smoke test working on macOS.** In `integration_test/connection_library_scene_test.dart`, replace the `enterText` on `library-search` with this (`dart:io` for `Platform`, `package:flutter/services.dart` for the codec):

```dart
      // On macOS search is the native toolbar's NSSearchField, which a
      // widget test can't type into, so deliver the event the runner
      // would send.
      if (Platform.isMacOS) {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'stash_player/toolbar',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('searchChanged', {'id': 'search', 'text': 'Kyoto'}),
          ),
          (_) {},
        );
      } else {
        await tester.enterText(
          find.byKey(const Key('library-search')),
          'Kyoto',
        );
      }
```

- [ ] **Step 8: Run the gate.** `nix develop .#flutter -c just flutter-check` passes.

- [ ] **Step 9: Commit.** `git commit -am "feat(flutter): publish the library toolbar to the native macOS toolbar"` (use `git add` first for any new files).

---

### Task 4: `NativeToolbarChannel.swift`

**Files:**
- Create: `apps/flutter/macos/Runner/NativeToolbarChannel.swift`
- Modify: `apps/flutter/macos/Runner/MainFlutterWindow.swift`
- Modify: `apps/flutter/macos/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the wire format from Task 2. `setItems` takes a list of maps with `type` set to `menu`, `toggle`, `action`, `search`, `group` or `space`, plus `id`, `label`, `tooltip`, `symbol`, `selected`, `enabled`, `badge`, `options`, `text`, `placeholder` and `children`. `reset` takes no arguments.
- Produces events to Dart:
  - `activated {id, rect?}`, where `rect` is `{x, y, width, height}` in the Flutter view's top-left logical coordinates
  - `menuSelected {id, index}`
  - `searchChanged {id, text}`

This can't be compiled on Linux. Write it carefully, and the `Flutter macOS` CI job (`flutter build macos --debug`) is the compile check.

- [ ] **Step 1: Create the Swift file** `NativeToolbarChannel.swift`:

```swift
import Cocoa
import FlutterMacOS

/// Fills the window's toolbar from the spec `ChannelNativeToolbar` sends
/// over `stash_player/toolbar`, and reports clicks, menu choices and
/// search edits back.
///
/// Items are keyed by their Dart id. When a new spec has the same ids and
/// kinds in the same order, which is every filter change, each item is
/// updated in place, so the toolbar never flickers. Anything else (the
/// library appearing or leaving) rebuilds the item list.
final class NativeToolbarChannel: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private weak var view: NSView?
  /// Every item's spec by id, group children included.
  private var specs: [String: [String: Any]] = [:]
  /// Top-level ids, leading to trailing.
  private var order: [String] = []
  /// "kind:id" for every item, children included: equal fingerprints
  /// mean an in-place update is enough.
  private var structure: [String] = []
  private var items: [String: NSToolbarItem] = [:]

  init(messenger: FlutterBinaryMessenger, window: NSWindow, view: NSView) {
    self.window = window
    self.view = view
    channel = FlutterMethodChannel(name: "stash_player/toolbar", binaryMessenger: messenger)
    super.init()
    window.toolbar?.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "setItems":
      guard let list = call.arguments as? [[String: Any]] else {
        result(FlutterError(code: "bad-args", message: "setItems needs a list of items", details: nil))
        return
      }
      guard window?.toolbar != nil else {
        result(FlutterError(code: "no-toolbar", message: "the window has no toolbar", details: nil))
        return
      }
      apply(list)
      result(nil)
    case "reset":
      apply([])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ list: [[String: Any]]) {
    guard let toolbar = window?.toolbar else { return }
    var newSpecs: [String: [String: Any]] = [:]
    var newStructure: [String] = []
    func index(_ spec: [String: Any]) {
      guard let id = spec["id"] as? String else { return }
      newSpecs[id] = spec
      newStructure.append("\(spec["type"] as? String ?? ""):\(id)")
      for child in spec["children"] as? [[String: Any]] ?? [] {
        index(child)
      }
    }
    let newOrder = list.compactMap { $0["id"] as? String }
    list.forEach(index)
    specs = newSpecs

    if newStructure == structure {
      for (id, item) in items {
        if let spec = specs[id] { update(item, with: spec) }
      }
      return
    }

    structure = newStructure
    order = newOrder
    while !toolbar.items.isEmpty {
      toolbar.removeItem(at: 0)
    }
    items = [:]
    for (position, id) in newOrder.enumerated() {
      let identifier: NSToolbarItem.Identifier =
        specs[id]?["type"] as? String == "space" ? .flexibleSpace : NSToolbarItem.Identifier(id)
      toolbar.insertItem(withItemIdentifier: identifier, at: position)
    }
  }

  // MARK: NSToolbarDelegate

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    []
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    order.map { NSToolbarItem.Identifier($0) } + [.flexibleSpace]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let spec = specs[itemIdentifier.rawValue] else { return nil }
    return makeItem(spec)
  }

  // MARK: Items

  private func makeItem(_ spec: [String: Any]) -> NSToolbarItem? {
    guard let id = spec["id"] as? String else { return nil }
    let identifier = NSToolbarItem.Identifier(id)
    let item: NSToolbarItem
    switch spec["type"] as? String {
    case "menu":
      let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
      menuItem.showsIndicator = true
      item = menuItem
    case "toggle":
      // A toolbar item has no on/off state of its own, so a toggle is a
      // push-on/push-off button in the toolbar's own bezel.
      item = NSToolbarItem(itemIdentifier: identifier)
      let button = NSButton(frame: .zero)
      button.bezelStyle = .toolbar
      button.setButtonType(.pushOnPushOff)
      button.imagePosition = .imageOnly
      button.identifier = NSUserInterfaceItemIdentifier(id)
      button.target = self
      button.action = #selector(activate(_:))
      item.view = button
    case "action":
      item = NSToolbarItem(itemIdentifier: identifier)
      item.isBordered = true
      item.autovalidates = false
      item.target = self
      item.action = #selector(activate(_:))
    case "search":
      let search = NSSearchToolbarItem(itemIdentifier: identifier)
      search.searchField.identifier = NSUserInterfaceItemIdentifier(id)
      search.searchField.delegate = self
      // The cancel (x) button clears the field through its action rather
      // than a text change.
      search.searchField.target = self
      search.searchField.action = #selector(searchAction(_:))
      item = search
    case "group":
      let group = NSToolbarItemGroup(itemIdentifier: identifier)
      group.subitems = (spec["children"] as? [[String: Any]] ?? []).compactMap(makeItem)
      item = group
    default:
      return nil
    }
    items[id] = item
    update(item, with: spec)
    return item
  }

  private func update(_ item: NSToolbarItem, with spec: [String: Any]) {
    let label = spec["label"] as? String ?? ""
    item.label = label
    item.paletteLabel = label
    item.toolTip = spec["tooltip"] as? String
    let image = (spec["symbol"] as? String).flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: label)
    }
    switch spec["type"] as? String {
    case "menu":
      guard let menuItem = item as? NSMenuToolbarItem else { return }
      let options = spec["options"] as? [String] ?? []
      let selected = spec["selected"] as? Int ?? -1
      let menu = NSMenu()
      for (index, option) in options.enumerated() {
        let entry = NSMenuItem(title: option, action: #selector(selectOption(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = index
        entry.representedObject = spec["id"] as? String
        entry.state = index == selected ? .on : .off
        menu.addItem(entry)
      }
      menuItem.menu = menu
      menuItem.title = options.indices.contains(selected) ? options[selected] : label
    case "toggle":
      guard let button = item.view as? NSButton else { return }
      button.image = image
      button.state = spec["selected"] as? Bool == true ? .on : .off
      button.toolTip = item.toolTip
      button.setAccessibilityLabel(label)
    case "action":
      let badged = spec["badge"] as? Bool == true
      item.image = badgeFallbackImage(spec, badged: badged) ?? image
      item.isEnabled = spec["enabled"] as? Bool ?? true
      applyBadge(item, badged)
    case "search":
      guard let search = item as? NSSearchToolbarItem else { return }
      search.searchField.placeholderString = spec["placeholder"] as? String
      let text = spec["text"] as? String ?? ""
      if !isEditing(search.searchField), search.searchField.stringValue != text {
        search.searchField.stringValue = text
      }
    default:
      break
    }
  }

  /// The system badge dot, on macOS 26 and later.
  private func applyBadge(_ item: NSToolbarItem, _ on: Bool) {
    #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        item.badge = on ? .indicator : nil
      }
    #endif
  }

  /// Before macOS 26 there is no badge, so a badged item shows the filled
  /// variant of its symbol instead. Nil when the item isn't badged, or
  /// when the system badge covers it.
  private func badgeFallbackImage(_ spec: [String: Any], badged: Bool) -> NSImage? {
    guard badged, let symbol = spec["symbol"] as? String else { return nil }
    #if compiler(>=6.2)
      if #available(macOS 26.0, *) { return nil }
    #endif
    return NSImage(
      systemSymbolName: "\(symbol).fill",
      accessibilityDescription: spec["label"] as? String
    )
  }

  private func isEditing(_ field: NSTextField) -> Bool {
    guard let editor = field.currentEditor() else { return false }
    return window?.firstResponder === editor
  }

  // MARK: Events

  @objc private func activate(_ sender: Any) {
    let id: String?
    if let button = sender as? NSButton {
      id = button.identifier?.rawValue
    } else if let item = sender as? NSToolbarItem {
      id = item.itemIdentifier.rawValue
    } else {
      id = nil
    }
    guard let id else { return }
    var args: [String: Any] = ["id": id]
    if let rect = clickAnchor() { args["rect"] = rect }
    channel.invokeMethod("activated", arguments: args)
  }

  /// Where the click that chose an item landed: a titlebar-high strip at
  /// that x, in the Flutter view's top-left coordinates, for anchoring a
  /// drawn popover under the item. Nil when there was no click in this
  /// window (the overflow menu, the keyboard); Dart then picks the
  /// trailing edge.
  private func clickAnchor() -> [String: Double]? {
    guard let view, let window, let event = NSApp.currentEvent,
      event.window === window,
      event.type == .leftMouseUp || event.type == .leftMouseDown
    else { return nil }
    let point = view.convert(event.locationInWindow, from: nil)
    let titlebar = window.frame.height - window.contentLayoutRect.height
    return ["x": Double(point.x) - 14, "y": 0, "width": 28, "height": Double(titlebar)]
  }

  @objc private func selectOption(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel.invokeMethod("menuSelected", arguments: ["id": id, "index": sender.tag])
  }

  @objc private func searchAction(_ sender: NSSearchField) {
    sendSearch(sender)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    sendSearch(field)
  }

  private func sendSearch(_ field: NSSearchField) {
    guard let id = field.identifier?.rawValue else { return }
    channel.invokeMethod("searchChanged", arguments: ["id": id, "text": field.stringValue])
  }
}
```

- [ ] **Step 2: Register it in `MainFlutterWindow.swift`.**
  - Add a stored property `private var nativeToolbar: NativeToolbarChannel?`.
  - After `self.toolbarStyle = .unified`, add `toolbar.displayMode = .iconOnly` and `toolbar.allowsUserCustomization = false`.
  - Next to `nativeMenus = …`, add:

```swift
    nativeToolbar = NativeToolbarChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self,
      view: flutterViewController.view
    )
```

  - Rewrite the toolbar comment ("Nothing is ever added to this toolbar; the Flutter view draws every control.") so it says the library fills this toolbar with native items through `NativeToolbarChannel`, while other screens leave it empty and it only centres the lights.

- [ ] **Step 3: Add the file to the Xcode project.** In `project.pbxproj`, make four edits that mirror `MainFlutterWindow.swift`'s entries (lines found with `grep -n MainFlutterWindow.swift`):
  - In the PBXBuildFile section, after the `MainFlutterWindow.swift in Sources` line:
    `		5A7B0C0100000000000000B1 /* NativeToolbarChannel.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5A7B0C0100000000000000A1 /* NativeToolbarChannel.swift */; };`
  - In the PBXFileReference section, after `MainFlutterWindow.swift`'s file reference:
    `		5A7B0C0100000000000000A1 /* NativeToolbarChannel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeToolbarChannel.swift; sourceTree = "<group>"; };`
  - In the Runner group's `children`, after `33CC11122044BFA00003C045 /* MainFlutterWindow.swift */,`:
    `				5A7B0C0100000000000000A1 /* NativeToolbarChannel.swift */,`
  - In the Sources build phase `files`, after `33CC11132044BFA00003C045 /* MainFlutterWindow.swift in Sources */,`:
    `				5A7B0C0100000000000000B1 /* NativeToolbarChannel.swift in Sources */,`

  Verify: `grep -c NativeToolbarChannel.swift apps/flutter/macos/Runner.xcodeproj/project.pbxproj` prints `4`.

- [ ] **Step 4: Run the gate** (Dart is unchanged, but confirm): `nix develop .#flutter -c just flutter-check`.

- [ ] **Step 5: Commit.**

```bash
git add apps/flutter/macos/Runner/NativeToolbarChannel.swift apps/flutter/macos/Runner/MainFlutterWindow.swift apps/flutter/macos/Runner.xcodeproj/project.pbxproj
git commit -m "feat(flutter): build the macOS NSToolbar from the Dart toolbar spec"
```

---

### Task 5: `ConnectionSheet` port and `ChannelConnectionSheet`

**Files:**
- Create: `apps/flutter/lib/features/connection/connection_sheet.dart`
- Create: `apps/flutter/lib/services/channel_connection_sheet.dart`
- Modify: `apps/flutter/lib/app/providers.dart` (add `connectionSheetProvider`)
- Modify: `apps/flutter/lib/features/connection/connection_form.dart` (hoist the proxy hint)
- Create: `apps/flutter/test/services/channel_connection_sheet_test.dart`
- Create: `apps/flutter/test/support/fake_connection_sheet.dart`

**Interfaces:**
- Consumes: `ConnectionConfig` (`lib/domain/connection.dart`, with fields `serverUrl`, `apiKey`, `socksProxy`).
- Produces:
  - `const String connectionProxyHint` (in `connection_form.dart`)
  - `ConnectionSheetRequest({required String title, required String confirmLabel, required bool cancellable, required ConnectionConfig values, required String proxyHint})`
  - `ConnectionSheetState({required bool canSubmit, required bool busy, String? urlError, String? proxyError, String? failure})` with value `==`
  - `sealed class ConnectionSheetEvent` with subclasses `ConnectionSheetChanged(ConnectionConfig values)`, `ConnectionSheetSubmitted(ConnectionConfig values)` and `ConnectionSheetCancelled()`
  - `abstract interface class ConnectionSheet { Future<void> present(ConnectionSheetRequest, void Function(ConnectionSheetEvent) onEvent); Future<void> update(ConnectionSheetState); Future<void> dismiss(); }`
  - `class ChannelConnectionSheet implements ConnectionSheet { ChannelConnectionSheet({MethodChannel channel}); Future<void> reset(); }`
  - `class ConnectionSheetNotifier extends Notifier<ConnectionSheet?> { void disable(); }` and `NotifierProvider connectionSheetProvider`
  - test support: `class FakeConnectionSheet implements ConnectionSheet { ConnectionSheetRequest? presented; List<ConnectionSheetState> updates; bool dismissed; bool failPresent; void send(ConnectionSheetEvent event); }`

- [ ] **Step 1: Hoist the hint.** In `connection_form.dart`, add this at the top level and use it for the Network group's `description:`:

```dart
/// What the SOCKS5 proxy field is for, shown under it by the drawn form
/// and the native macOS sheet alike.
const connectionProxyHint =
    'Reach Stash through a SOCKS5 proxy, for a server only routable that '
    'way. Tailscale in userspace mode listens on 127.0.0.1:1055.';
```

- [ ] **Step 2: Write the port.** Create `lib/features/connection/connection_sheet.dart`:

```dart
import 'package:flutter/foundation.dart';

import '../../domain/connection.dart';

/// What a [ConnectionSheet] opens with.
@immutable
class ConnectionSheetRequest {
  const ConnectionSheetRequest({
    required this.title,
    required this.confirmLabel,
    required this.cancellable,
    required this.values,
    required this.proxyHint,
  });

  final String title;
  final String confirmLabel;

  /// Whether the sheet has a Cancel button (and Esc). False on first
  /// launch, when there is nothing to go back to.
  final bool cancellable;

  /// The fields' initial text.
  final ConnectionConfig values;
  final String proxyHint;
}

/// Everything about an open sheet that Dart decides: whether it can
/// submit, whether a test is running, and the errors to show.
@immutable
class ConnectionSheetState {
  const ConnectionSheetState({
    required this.canSubmit,
    required this.busy,
    this.urlError,
    this.proxyError,
    this.failure,
  });

  final bool canSubmit;
  final bool busy;
  final String? urlError;
  final String? proxyError;
  final String? failure;

  @override
  bool operator ==(Object other) =>
      other is ConnectionSheetState &&
      other.canSubmit == canSubmit &&
      other.busy == busy &&
      other.urlError == urlError &&
      other.proxyError == proxyError &&
      other.failure == failure;

  @override
  int get hashCode =>
      Object.hash(canSubmit, busy, urlError, proxyError, failure);
}

/// What the user did in the sheet.
sealed class ConnectionSheetEvent {
  const ConnectionSheetEvent();
}

/// A field changed. [values] holds all three fields' current text.
final class ConnectionSheetChanged extends ConnectionSheetEvent {
  const ConnectionSheetChanged(this.values);
  final ConnectionConfig values;
}

/// The confirm button (or Return).
final class ConnectionSheetSubmitted extends ConnectionSheetEvent {
  const ConnectionSheetSubmitted(this.values);
  final ConnectionConfig values;
}

/// Cancel (or Esc).
final class ConnectionSheetCancelled extends ConnectionSheetEvent {
  const ConnectionSheetCancelled();
}

/// The connection form as a platform sheet: an AppKit sheet on macOS
/// (`ConnectionSheetChannel.swift`). It holds no rules of its own;
/// `ConnectionSheetPresenter` decides everything and pushes it through
/// [update].
abstract interface class ConnectionSheet {
  /// Shows the sheet. [onEvent] receives edits, submit and cancel until
  /// [dismiss]. Throws `MissingPluginException` or `PlatformException`
  /// when the native side is unavailable.
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  );

  Future<void> update(ConnectionSheetState state);

  /// Closes the sheet. A no-op when none is open.
  Future<void> dismiss();
}
```

- [ ] **Step 3: Write the failing channel tests.** Create `test/services/channel_connection_sheet_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';
import 'package:stash_player_flutter/services/channel_connection_sheet.dart';

const _channel = MethodChannel('stash_player/connection_sheet');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> sent;

  setUp(() {
    sent = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  const request = ConnectionSheetRequest(
    title: 'Connection',
    confirmLabel: 'Save',
    cancellable: true,
    values: ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'k'),
    proxyHint: 'hint',
  );

  Future<void> deliver(String method, [Object? args]) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('present sends the request', () async {
    await ChannelConnectionSheet().present(request, (_) {});

    expect(sent.single.method, 'present');
    expect(sent.single.arguments, {
      'title': 'Connection',
      'confirmLabel': 'Save',
      'cancellable': true,
      'serverUrl': 'https://stash.test',
      'apiKey': 'k',
      'socksProxy': '',
      'proxyHint': 'hint',
    });
  });

  test('update sends the state', () async {
    await ChannelConnectionSheet().update(
      const ConnectionSheetState(canSubmit: true, busy: false, urlError: 'bad'),
    );

    expect(sent.single.method, 'update');
    expect(sent.single.arguments, {
      'canSubmit': true,
      'busy': false,
      'urlError': 'bad',
      'proxyError': null,
      'failure': null,
    });
  });

  test('decodes events until dismissed', () async {
    final events = <ConnectionSheetEvent>[];
    final sheet = ChannelConnectionSheet();
    await sheet.present(request, events.add);

    const values = {'serverUrl': 'https://x', 'apiKey': '', 'socksProxy': ''};
    await deliver('changed', values);
    await deliver('submitted', values);
    await deliver('cancelled');
    await sheet.dismiss();
    await deliver('cancelled');

    expect(events, hasLength(3));
    expect(
      (events[0] as ConnectionSheetChanged).values.serverUrl,
      'https://x',
    );
    expect(events[1], isA<ConnectionSheetSubmitted>());
    expect(events[2], isA<ConnectionSheetCancelled>());
    expect(sent.last.method, 'dismiss');
  });

  test('present throws when the plugin is missing', () async {
    messenger.setMockMethodCallHandler(_channel, null);

    await expectLater(
      ChannelConnectionSheet().present(request, (_) {}),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
```

- [ ] **Step 4: Run them and confirm they fail.** `flutter test test/services/channel_connection_sheet_test.dart`

- [ ] **Step 5: Implement.** Create `lib/services/channel_connection_sheet.dart`:

```dart
import 'package:flutter/services.dart';

import '../domain/connection.dart';
import '../features/connection/connection_sheet.dart';

/// The connection sheet over `stash_player/connection_sheet`, drawn by
/// `ConnectionSheetChannel.swift` as a real AppKit sheet.
///
/// Events arrive as method calls from the runner and go to the `onEvent`
/// of the sheet that is currently open. Once it is dismissed they are
/// dropped, so a late click can't reach a closed sheet's owner.
class ChannelConnectionSheet implements ConnectionSheet {
  ChannelConnectionSheet({
    MethodChannel channel = const MethodChannel(
      'stash_player/connection_sheet',
    ),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  void Function(ConnectionSheetEvent event)? _onEvent;

  /// Asks the runner to close any sheet a previous isolate left open (a
  /// hot restart). Failures are ignored; [present] reports them.
  Future<void> reset() async {
    try {
      await _channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // No runner support: nothing to reset.
    } on PlatformException {
      // Same.
    }
  }

  @override
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  ) async {
    _onEvent = onEvent;
    try {
      await _channel.invokeMethod<void>('present', {
        'title': request.title,
        'confirmLabel': request.confirmLabel,
        'cancellable': request.cancellable,
        'serverUrl': request.values.serverUrl,
        'apiKey': request.values.apiKey,
        'socksProxy': request.values.socksProxy,
        'proxyHint': request.proxyHint,
      });
    } on Object {
      _onEvent = null;
      rethrow;
    }
  }

  @override
  Future<void> update(ConnectionSheetState state) =>
      _channel.invokeMethod<void>('update', {
        'canSubmit': state.canSubmit,
        'busy': state.busy,
        'urlError': state.urlError,
        'proxyError': state.proxyError,
        'failure': state.failure,
      });

  @override
  Future<void> dismiss() async {
    _onEvent = null;
    try {
      await _channel.invokeMethod<void>('dismiss');
    } on MissingPluginException {
      // Nothing was ever shown.
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final onEvent = _onEvent;
    if (onEvent == null) return null;
    ConnectionConfig values() {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      return ConnectionConfig(
        serverUrl: args['serverUrl'] as String? ?? '',
        apiKey: args['apiKey'] as String? ?? '',
        socksProxy: args['socksProxy'] as String? ?? '',
      );
    }

    switch (call.method) {
      case 'changed':
        onEvent(ConnectionSheetChanged(values()));
      case 'submitted':
        onEvent(ConnectionSheetSubmitted(values()));
      case 'cancelled':
        onEvent(const ConnectionSheetCancelled());
    }
    return null;
  }
}
```

Check `ConnectionConfig`'s constructor in `lib/domain/connection.dart`; if its fields have different names or aren't optional, match them.

- [ ] **Step 6: Run the tests and confirm they pass.**

- [ ] **Step 7: Add the provider.** In `providers.dart`:

```dart
/// The native connection sheet: an AppKit sheet on macOS, none elsewhere.
/// [ConnectionSheetNotifier.disable] drops it for the rest of the session
/// when it fails to open, and every host falls back to the drawn form.
final connectionSheetProvider =
    NotifierProvider<ConnectionSheetNotifier, ConnectionSheet?>(
      ConnectionSheetNotifier.new,
    );

class ConnectionSheetNotifier extends Notifier<ConnectionSheet?> {
  @override
  ConnectionSheet? build() {
    if (defaultTargetPlatform != TargetPlatform.macOS) return null;
    final sheet = ChannelConnectionSheet();
    unawaited(sheet.reset());
    return sheet;
  }

  void disable() => state = null;
}
```

- [ ] **Step 8: Add the fake.** Create `test/support/fake_connection_sheet.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';

/// A [ConnectionSheet] that records what it is told and lets a test act
/// as the user through [send].
class FakeConnectionSheet implements ConnectionSheet {
  FakeConnectionSheet({this.failPresent = false});

  bool failPresent;
  ConnectionSheetRequest? presented;
  final List<ConnectionSheetState> updates = [];
  bool dismissed = false;
  void Function(ConnectionSheetEvent event)? _onEvent;

  bool get isOpen => _onEvent != null;

  void send(ConnectionSheetEvent event) => _onEvent?.call(event);

  @override
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  ) async {
    if (failPresent) throw MissingPluginException('no sheet');
    presented = request;
    dismissed = false;
    _onEvent = onEvent;
  }

  @override
  Future<void> update(ConnectionSheetState state) async => updates.add(state);

  @override
  Future<void> dismiss() async {
    dismissed = true;
    _onEvent = null;
  }
}

/// Overrides [connectionSheetProvider] with [sheet].
class FakeConnectionSheetNotifier extends ConnectionSheetNotifier {
  FakeConnectionSheetNotifier(this.sheet);
  final ConnectionSheet? sheet;

  @override
  ConnectionSheet? build() => sheet;
}
```

- [ ] **Step 9: Run the gate, then commit.**

```bash
git add apps/flutter/lib/features/connection/connection_sheet.dart apps/flutter/lib/services/channel_connection_sheet.dart apps/flutter/lib/app/providers.dart apps/flutter/lib/features/connection/connection_form.dart apps/flutter/test/services/channel_connection_sheet_test.dart apps/flutter/test/support/fake_connection_sheet.dart
git commit -m "feat(flutter): connection-sheet port and its macOS channel"
```

---

### Task 6: `ConnectionSheetPresenter`

**Files:**
- Create: `apps/flutter/lib/features/connection/connection_sheet_presenter.dart`
- Create: `apps/flutter/test/features/connection/connection_sheet_presenter_test.dart`

**Interfaces:**
- Consumes: Task 5's types. `ConnectionController` (a `ChangeNotifier` with `state`, `load()` and `testAndSave(ConnectionConfig)`) and `ConnectionPhase` from `connection_controller.dart`. `connectionProxyHint`.
- Produces: `ConnectionSheetPresenter({required ConnectionSheet sheet, required ConnectionController controller, required void Function(ConnectionConfig config) onConnected, required VoidCallback onCancelled})` with `Future<void> open({required String title, required String confirmLabel, required bool cancellable})` (rethrows the sheet's failure) and `Future<void> close()`.

- [ ] **Step 1: Write the failing tests.** Build a real `ConnectionController` the way `test/features/connection/connection_controller_test.dart` does (with `FakeConnectionStore`, `FakeStashApi` and an environment map). Then:

```dart
void main() {
  late FakeConnectionSheet sheet;
  late List<ConnectionConfig> connected;
  late int cancelled;

  ConnectionSheetPresenter presenter(ConnectionController controller) =>
      ConnectionSheetPresenter(
        sheet: sheet,
        controller: controller,
        onConnected: connected.add,
        onCancelled: () => cancelled++,
      );

  setUp(() {
    sheet = FakeConnectionSheet();
    connected = [];
    cancelled = 0;
  });

  test('loads the stored connection before presenting', () async {
    final controller = _controller(
      saved: const ConnectionConfig(serverUrl: 'https://old.test'),
    );
    await presenter(controller).open(
      title: 'Connection',
      confirmLabel: 'Save',
      cancellable: true,
    );

    expect(sheet.presented!.values.serverUrl, 'https://old.test');
    expect(sheet.presented!.proxyHint, connectionProxyHint);
    expect(sheet.updates.last.canSubmit, isTrue);
  });

  test('canSubmit follows the URL field', () async {
    final controller = _controller();
    await presenter(controller).open(
      title: 'Connect to Stash',
      confirmLabel: 'Connect',
      cancellable: false,
    );
    expect(sheet.updates.last.canSubmit, isFalse);

    sheet.send(const ConnectionSheetChanged(
      ConnectionConfig(serverUrl: 'https://stash.test'),
    ));
    expect(sheet.updates.last.canSubmit, isTrue);

    sheet.send(const ConnectionSheetChanged(ConnectionConfig(serverUrl: '  ')));
    expect(sheet.updates.last.canSubmit, isFalse);
  });

  test('a failed test shows busy, then the error, and stays open', () async {
    final controller = _controller(
      api: FakeStashApi(versionFailure: const TransportFailure('down')),
    );
    await presenter(controller).open(
      title: 'Connection',
      confirmLabel: 'Save',
      cancellable: true,
    );

    sheet.send(const ConnectionSheetSubmitted(
      ConnectionConfig(serverUrl: 'https://stash.test'),
    ));
    await pumpEventQueue();

    expect(sheet.updates.any((s) => s.busy), isTrue);
    expect(sheet.updates.last.busy, isFalse);
    expect(sheet.updates.last.failure ?? sheet.updates.last.urlError,
        isNotNull);
    expect(sheet.dismissed, isFalse);
    expect(connected, isEmpty);
  });

  test('a bad proxy lands under the proxy field', () async {
    final controller = _controller();
    await presenter(controller).open(
      title: 'Connection',
      confirmLabel: 'Save',
      cancellable: true,
    );

    sheet.send(const ConnectionSheetSubmitted(
      ConnectionConfig(serverUrl: 'https://stash.test', socksProxy: 'a:b:c'),
    ));
    await pumpEventQueue();

    expect(sheet.updates.last.proxyError, isNotNull);
  });

  test('success dismisses and reports the config', () async {
    final controller = _controller();
    await presenter(controller).open(
      title: 'Connection',
      confirmLabel: 'Save',
      cancellable: true,
    );

    sheet.send(const ConnectionSheetSubmitted(
      ConnectionConfig(serverUrl: 'https://stash.test'),
    ));
    await pumpEventQueue();

    expect(sheet.dismissed, isTrue);
    expect(connected.single.serverUrl, 'https://stash.test');
  });

  test('cancel is reported and does not dismiss by itself', () async {
    final controller = _controller();
    await presenter(controller).open(
      title: 'Connection',
      confirmLabel: 'Save',
      cancellable: true,
    );

    sheet.send(const ConnectionSheetCancelled());

    expect(cancelled, 1);
  });

  test('open rethrows when the sheet cannot be shown', () async {
    sheet.failPresent = true;
    await expectLater(
      presenter(_controller()).open(
        title: 'Connection',
        confirmLabel: 'Save',
        cancellable: true,
      ),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
```

`_controller({ConnectionConfig? saved, FakeStashApi? api})` builds `ConnectionController(store: FakeConnectionStore(saved: saved), environment: const {}, apiFactory: (_) => api ?? FakeStashApi())`. Check `FakeConnectionStore`'s constructor and `StashApiFactory`'s signature in `test/support/fakes.dart` and `providers.dart`, and match them. Check `FakeStashApi`'s default `version()` succeeds; if it needs a configured version, set one.

- [ ] **Step 2: Run them and confirm they fail.**

- [ ] **Step 3: Implement.** Create `connection_sheet_presenter.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/connection.dart';
import 'connection_controller.dart';
import 'connection_form.dart';
import 'connection_sheet.dart';

/// Runs a [ConnectionSheet] against the [ConnectionController]: every
/// rule stays here in Dart, and the sheet only shows what it's told.
///
/// - The stored connection is loaded before the sheet appears, so nothing
///   can be typed before the fields are seeded.
/// - Submit runs `testAndSave`. While it runs, the sheet is busy (fields
///   and both buttons disabled, since `testAndSave` saves the moment
///   Stash answers and a close mid-test would leave it saved but unused).
/// - Errors land under their fields. Success dismisses the sheet and
///   reports the config through [onConnected].
/// - Cancel is reported through [onCancelled]; the owner decides whether
///   that closes the sheet (via [close]).
class ConnectionSheetPresenter {
  ConnectionSheetPresenter({
    required this.sheet,
    required this.controller,
    required this.onConnected,
    required this.onCancelled,
  });

  final ConnectionSheet sheet;
  final ConnectionController controller;
  final void Function(ConnectionConfig config) onConnected;
  final VoidCallback onCancelled;

  ConnectionConfig _values = const ConnectionConfig();
  ConnectionSheetState? _lastSent;
  ConnectionPhase? _lastPhase;
  bool _open = false;

  /// Loads the stored connection, then shows the sheet seeded with it.
  /// Rethrows the sheet's own failure to open.
  Future<void> open({
    required String title,
    required String confirmLabel,
    required bool cancellable,
  }) async {
    await controller.load();
    _values = controller.state.config;
    _lastPhase = controller.state.phase;
    await sheet.present(
      ConnectionSheetRequest(
        title: title,
        confirmLabel: confirmLabel,
        cancellable: cancellable,
        values: _values,
        proxyHint: connectionProxyHint,
      ),
      _onEvent,
    );
    _open = true;
    controller.addListener(_onController);
    _push();
  }

  /// Closes the sheet. Safe to call when it isn't open.
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    controller.removeListener(_onController);
    await sheet.dismiss();
  }

  void _onEvent(ConnectionSheetEvent event) {
    switch (event) {
      case ConnectionSheetChanged(:final values):
        _values = values;
        _push();
      case ConnectionSheetSubmitted(:final values):
        _values = values;
        unawaited(controller.testAndSave(values));
      case ConnectionSheetCancelled():
        onCancelled();
    }
  }

  void _onController() {
    final state = controller.state;
    final previous = _lastPhase;
    _lastPhase = state.phase;
    if (previous != ConnectionPhase.ready &&
        state.phase == ConnectionPhase.ready) {
      unawaited(close());
      onConnected(state.config);
      return;
    }
    _push();
  }

  void _push() {
    final state = controller.state;
    final next = ConnectionSheetState(
      // Same rule as ConnectionFields.canSubmit.
      canSubmit: _values.serverUrl.trim().isNotEmpty,
      busy: state.phase == ConnectionPhase.loading,
      urlError: state.fieldError,
      proxyError: state.proxyFieldError,
      failure: state.failure,
    );
    if (next == _lastSent) return;
    _lastSent = next;
    unawaited(sheet.update(next));
  }
}
```

- [ ] **Step 4: Run the tests and confirm they pass.** Then run the gate.

- [ ] **Step 5: Commit.** `git add` both files, then `git commit -m "feat(flutter): presenter that runs the connection sheet from Dart"`

---

### Task 7: Use the sheet on first launch and for Settings

**Files:**
- Create: `apps/flutter/lib/features/connection/connection_sheet_host.dart`
- Modify: `apps/flutter/lib/features/connection/connection_screen.dart`
- Modify: `apps/flutter/lib/features/library/library_screen.dart`
- Modify: `apps/flutter/lib/app/app_router.dart`
- Create: `apps/flutter/test/features/connection/connection_sheet_host_test.dart`
- Modify: `apps/flutter/test/app/app_router_test.dart` (add a test)

**Interfaces:**
- Consumes: Tasks 5 and 6; `appControllerProvider`, whose notifier has `replaceConnection(ConnectionConfig)` and `closeSettings()`; `connectionControllerProvider`; `logDiagnostic`.
- Produces: `ConnectionSheetHost({required bool open, required String title, required String confirmLabel, required bool cancellable, required void Function(ConnectionConfig) onConnected, VoidCallback? onCancelled, required Widget child})`.

- [ ] **Step 1: Write the failing tests.** Create `connection_sheet_host_test.dart`. Pump a `ProviderScope` whose overrides are:
  - `connectionSheetProvider.overrideWith(() => FakeConnectionSheetNotifier(sheet))`
  - `connectionStoreProvider.overrideWithValue(FakeConnectionStore(...))`
  - `stashApiFactoryProvider.overrideWithValue((_) => FakeStashApi())`
  - `connectionControllerOverride`

  Copy the provider setup from `test/features/connection/connection_settings_dialog_test.dart`'s `_pump`. The child is `MaterialApp(theme: buildAppTheme(Brightness.light), home: ConnectionSheetHost(...))`. Tests:
  1. `open: true` presents the sheet with the given title/confirm/cancellable after `pump()`, and the child still renders.
  2. Changing `open` from true to false (rebuild through a `StatefulBuilder` or a `ValueNotifier`) dismisses it (`sheet.dismissed`).
  3. `sheet.send(ConnectionSheetCancelled())` calls `onCancelled`.
  4. A successful submit calls `onConnected` with the config.
  5. With `FakeConnectionSheet(failPresent: true)`, the provider becomes null after `pump()`: read `container.read(connectionSheetProvider)` through `ProviderScope.containerOf`.
  6. With no sheet (a `FakeConnectionSheetNotifier(null)`), nothing is presented and the child renders.

  In `app_router_test.dart`, add a test: with `connectionSheetProvider` overridden to a fake sheet and the destination `library(settingsOpen: true)`, `find.byType(ConnectionSettingsDialog)` finds nothing and `sheet.presented!.title == 'Connection'`. Follow the file's existing setup for pumping the router.

- [ ] **Step 2: Run them and confirm they fail.**

- [ ] **Step 3: Implement the host.** Create `connection_sheet_host.dart`:

```dart
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/connection.dart';
import '../../shared/diagnostics.dart';
import 'connection_controller.dart';
import 'connection_sheet_presenter.dart';

/// Shows the native connection sheet over [child] while [open] is true,
/// when the app has one (macOS). With no sheet it just shows [child],
/// and the caller draws its own form.
///
/// If the sheet fails to open, it disables [connectionSheetProvider] for
/// the rest of the session, which brings every drawn fallback back (the
/// router's settings dialog, the first-launch form).
class ConnectionSheetHost extends ConsumerStatefulWidget {
  const ConnectionSheetHost({
    required this.open,
    required this.title,
    required this.confirmLabel,
    required this.cancellable,
    required this.onConnected,
    required this.child,
    this.onCancelled,
    super.key,
  });

  final bool open;
  final String title;
  final String confirmLabel;
  final bool cancellable;
  final void Function(ConnectionConfig config) onConnected;
  final VoidCallback? onCancelled;
  final Widget child;

  @override
  ConsumerState<ConnectionSheetHost> createState() =>
      _ConnectionSheetHostState();
}

class _ConnectionSheetHostState extends ConsumerState<ConnectionSheetHost> {
  ConnectionSheetPresenter? _presenter;

  /// Bumped on every open and close, so an open still loading when the
  /// host closes can tell it has been superseded.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.open) _scheduleOpen();
  }

  @override
  void didUpdateWidget(ConnectionSheetHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) _scheduleOpen();
    if (!widget.open && oldWidget.open) _close();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  // After the frame: opening loads through the connection controller,
  // and Riverpod forbids changing provider state mid-build.
  void _scheduleOpen() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());

  Future<void> _open() async {
    if (!mounted || !widget.open || _presenter != null) return;
    final sheet = ref.read(connectionSheetProvider);
    if (sheet == null) return;
    final generation = ++_generation;
    final presenter = ConnectionSheetPresenter(
      sheet: sheet,
      controller: ref.read(connectionControllerProvider),
      onConnected: (config) {
        _presenter = null;
        widget.onConnected(config);
      },
      onCancelled: () => widget.onCancelled?.call(),
    );
    _presenter = presenter;
    try {
      await presenter.open(
        title: widget.title,
        confirmLabel: widget.confirmLabel,
        cancellable: widget.cancellable,
      );
    } on Object catch (error) {
      if (error is! MissingPluginException && error is! PlatformException) {
        rethrow;
      }
      _presenter = null;
      logDiagnostic('connection', 'native sheet unavailable, drawing: $error');
      if (mounted) ref.read(connectionSheetProvider.notifier).disable();
      return;
    }
    // Closed while it was loading: take the fresh sheet straight down.
    if (generation != _generation || !mounted) unawaited(presenter.close());
  }

  void _close() {
    _generation++;
    final presenter = _presenter;
    _presenter = null;
    if (presenter != null) unawaited(presenter.close());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
```

- [ ] **Step 4: First launch.** In `ConnectionScreen.build`, first thing:

```dart
    // On macOS the form is a native sheet over an empty window.
    if (ref.watch(connectionSheetProvider) != null) {
      return ConnectionSheetHost(
        open: true,
        title: 'Connect to Stash',
        confirmLabel: 'Connect',
        cancellable: false,
        onConnected: (_) => widget.onConnected(),
        child: const Scaffold(body: SizedBox.expand()),
      );
    }
```

(Imports: `../../app/providers.dart`, `connection_sheet_host.dart`.) Update the class doc comment to mention the macOS sheet. This goes above the existing `ref.listen` so the drawn path's listener isn't registered twice. The presenter reports `ready` itself.

- [ ] **Step 5: Settings.** In `LibraryScreen.build`, wrap the returned `Scaffold`:

```dart
    return ConnectionSheetHost(
      open: ref.watch(
        appControllerProvider.select(
          (d) => d is LibraryDestination && d.settingsOpen,
        ),
      ),
      title: 'Connection',
      confirmLabel: 'Save',
      cancellable: true,
      onConnected: (config) => unawaited(
        ref.read(appControllerProvider.notifier).replaceConnection(config),
      ),
      onCancelled: () =>
          ref.read(appControllerProvider.notifier).closeSettings(),
      child: Scaffold(/* unchanged */),
    );
```

- [ ] **Step 6: The router.** In `app_router.dart`, add `final nativeSheet = ref.watch(connectionSheetProvider) != null;` in `build`, pass it to `_pagesFor(destination, nativeSheet: nativeSheet)`, and change the library case to `if (settingsOpen && !nativeSheet) _settingsPage`. Add a comment there: on macOS the library's `ConnectionSheetHost` shows settings as a native sheet instead. Import `providers.dart`.

- [ ] **Step 7: Run the tests and confirm they pass.** Then run the gate.

- [ ] **Step 8: Commit.** `git add` the new files, then `git commit -am "feat(flutter): native connection sheet for first launch and Settings on macOS"`

---

### Task 8: `ConnectionSheetChannel.swift`

**Files:**
- Create: `apps/flutter/macos/Runner/ConnectionSheetChannel.swift`
- Modify: `apps/flutter/macos/Runner/MainFlutterWindow.swift`
- Modify: `apps/flutter/macos/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the wire format from Task 5.
  - `present {title, confirmLabel, cancellable, serverUrl, apiKey, socksProxy, proxyHint}` returns a `FlutterError` with code `already-open` if a sheet is already up.
  - `update {canSubmit, busy, urlError?, proxyError?, failure?}`
  - `dismiss`
  - `reset`
- Produces events to Dart: `changed`, `submitted` (each `{serverUrl, apiKey, socksProxy}`) and `cancelled`.

- [ ] **Step 1: Create the Swift file** `ConnectionSheetChannel.swift`:

```swift
import Cocoa
import FlutterMacOS

/// The connection form as a real AppKit sheet, over
/// `stash_player/connection_sheet`. Dart (`ConnectionSheetPresenter`)
/// owns every rule: this only lays out the fields, reports edits, submit
/// and cancel, and shows the state Dart sends back.
final class ConnectionSheetChannel: NSObject, NSTextFieldDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var panel: NSPanel?
  private var content: ConnectionSheetContent?
  private var wasBusy = false

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    channel = FlutterMethodChannel(name: "stash_player/connection_sheet", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "present":
      guard panel == nil else {
        result(FlutterError(code: "already-open", message: "a connection sheet is already open", details: nil))
        return
      }
      guard let window, let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad-args", message: "present needs a window and arguments", details: nil))
        return
      }
      present(args, over: window)
      result(nil)
    case "update":
      if let args = call.arguments as? [String: Any] { update(args) }
      result(nil)
    case "dismiss", "reset":
      dismiss()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(_ args: [String: Any], over window: NSWindow) {
    let content = ConnectionSheetContent(
      title: args["title"] as? String ?? "",
      confirmLabel: args["confirmLabel"] as? String ?? "OK",
      cancellable: args["cancellable"] as? Bool ?? true,
      proxyHint: args["proxyHint"] as? String ?? "",
      target: self
    )
    content.urlField.stringValue = args["serverUrl"] as? String ?? ""
    content.apiKeyField.stringValue = args["apiKey"] as? String ?? ""
    content.proxyField.stringValue = args["socksProxy"] as? String ?? ""
    for field in content.fields { field.delegate = self }

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    panel.contentView = content.root
    panel.setContentSize(content.root.fittingSize)
    panel.initialFirstResponder = content.urlField
    self.panel = panel
    self.content = content
    wasBusy = false
    window.beginSheet(panel)
  }

  private func update(_ args: [String: Any]) {
    guard let content, let panel else { return }
    let busy = args["busy"] as? Bool ?? false
    let canSubmit = args["canSubmit"] as? Bool ?? false
    content.confirm.isEnabled = canSubmit && !busy
    content.cancel?.isEnabled = !busy
    for field in content.fields { field.isEnabled = !busy }
    if busy {
      content.spinner.startAnimation(nil)
    } else {
      content.spinner.stopAnimation(nil)
    }
    content.show(args["urlError"] as? String, in: content.urlError)
    content.show(args["proxyError"] as? String, in: content.proxyError)
    content.show(args["failure"] as? String, in: content.failure)
    panel.setContentSize(content.root.fittingSize)
    // A failed test re-enables the fields; put the cursor back where the
    // user will fix the entry.
    if wasBusy && !busy {
      panel.makeFirstResponder(content.urlField)
    }
    wasBusy = busy
  }

  private func dismiss() {
    guard let panel else { return }
    (panel.sheetParent ?? window)?.endSheet(panel)
    self.panel = nil
    content = nil
  }

  // MARK: Events

  @objc func confirmPressed(_ sender: Any?) {
    send("submitted")
  }

  @objc func cancelPressed(_ sender: Any?) {
    channel.invokeMethod("cancelled", arguments: nil)
  }

  func controlTextDidChange(_ notification: Notification) {
    send("changed")
  }

  private func send(_ method: String) {
    guard let content else { return }
    channel.invokeMethod(method, arguments: [
      "serverUrl": content.urlField.stringValue,
      "apiKey": content.apiKeyField.stringValue,
      "socksProxy": content.proxyField.stringValue,
    ])
  }
}

/// The sheet's views, built fresh for each presentation.
///
/// Every view is built as a local and assigned at the end of `init`:
/// Swift forbids reading `self` before all stored properties are set.
private final class ConnectionSheetContent {
  let root: NSView
  let urlField: NSTextField
  let apiKeyField: NSSecureTextField
  let proxyField: NSTextField
  let urlError: NSTextField
  let proxyError: NSTextField
  let failure: NSTextField
  let spinner: NSProgressIndicator
  let confirm: NSButton
  let cancel: NSButton?
  private let grid: NSGridView

  var fields: [NSTextField] { [urlField, apiKeyField, proxyField] }

  init(title: String, confirmLabel: String, cancellable: Bool, proxyHint: String, target: ConnectionSheetChannel) {
    let urlField = NSTextField()
    urlField.placeholderString = "https://stash.example.com"
    let apiKeyField = NSSecureTextField()
    apiKeyField.placeholderString = "Optional"
    let proxyField = NSTextField()
    proxyField.placeholderString = "Optional"
    for field in [urlField, apiKeyField, proxyField] {
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    }

    let urlError = Self.messageLabel(color: .systemRed)
    let proxyError = Self.messageLabel(color: .systemRed)
    let failure = Self.messageLabel(color: .systemRed)
    failure.isHidden = true
    let hint = Self.messageLabel(color: .secondaryLabelColor)
    hint.stringValue = proxyHint

    let heading = NSTextField(labelWithString: title)
    heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    // Messages get rows of their own, so the label/field rows can align
    // on the first baseline and an empty message row can be hidden.
    let grid = NSGridView(views: [
      [Self.fieldLabel("Server URL:"), urlField],
      [NSGridCell.emptyContentView, urlError],
      [Self.fieldLabel("API Key:"), apiKeyField],
      [Self.fieldLabel("SOCKS5 Proxy:"), proxyField],
      [NSGridCell.emptyContentView, proxyError],
      [NSGridCell.emptyContentView, hint],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.rowAlignment = .firstBaseline
    grid.column(at: 0).xPlacement = .trailing
    grid.row(at: 1).isHidden = true
    grid.row(at: 4).isHidden = true

    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    let confirm = NSButton(
      title: confirmLabel, target: target, action: #selector(ConnectionSheetChannel.confirmPressed(_:)))
    // Return: the default button, drawn in the accent colour.
    confirm.keyEquivalent = "\r"
    confirm.isEnabled = false
    var cancel: NSButton?
    if cancellable {
      let button = NSButton(
        title: "Cancel", target: target, action: #selector(ConnectionSheetChannel.cancelPressed(_:)))
      button.keyEquivalent = "\u{1b}"
      cancel = button
    }

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.setViews([spinner] + [cancel, confirm].compactMap { $0 }, in: .trailing)

    let stack = NSStackView(views: [heading, grid, failure, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

    self.root = stack
    self.urlField = urlField
    self.apiKeyField = apiKeyField
    self.proxyField = proxyField
    self.urlError = urlError
    self.proxyError = proxyError
    self.failure = failure
    self.spinner = spinner
    self.confirm = confirm
    self.cancel = cancel
    self.grid = grid
  }

  /// Shows [message] in [label], or hides it (and its grid row) when nil.
  func show(_ message: String?, in label: NSTextField) {
    label.stringValue = message ?? ""
    let hidden = message == nil
    if label === failure {
      label.isHidden = hidden
    } else if let row = rowIndex(of: label) {
      grid.row(at: row).isHidden = hidden
    }
  }

  private func rowIndex(of view: NSView) -> Int? {
    (0..<grid.numberOfRows).first { grid.cell(atColumnIndex: 1, rowIndex: $0).contentView === view }
  }

  private static func fieldLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.alignment = .right
    return label
  }

  private static func messageLabel(color: NSColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: "")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = color
    label.preferredMaxLayoutWidth = 280
    return label
  }
}
```

- [ ] **Step 2: Register it in `MainFlutterWindow.swift`.** Add `private var connectionSheet: ConnectionSheetChannel?`, and after the toolbar channel:

```swift
    connectionSheet = ConnectionSheetChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )
```

- [ ] **Step 3: Add the file to the Xcode project,** as in Task 4 Step 3. Use file ref `5A7B0C0100000000000000A2` and build file `5A7B0C0100000000000000B2`, named `ConnectionSheetChannel.swift`. Verify: `grep -c ConnectionSheetChannel.swift apps/flutter/macos/Runner.xcodeproj/project.pbxproj` prints `4`.

- [ ] **Step 4: Run the gate.** `nix develop .#flutter -c just flutter-check`.

- [ ] **Step 5: Commit.** `git add` the three files, then `git commit -m "feat(flutter): AppKit connection sheet on macOS"`

---

### Task 9: Docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-09-24-native-look-and-feel-design.md`
- Modify: `docs/superpowers/specs/2026-09-24-settings-dialog-design.md`
- Modify: `apps/flutter/README.md`, only if it describes the macOS toolbar or settings UI (check with `grep -n -i "toolbar\|settings" apps/flutter/README.md`)

- [ ] **Step 1: `CLAUDE.md`.**
  - In the `lib/ui/` bullet, add `toolbar/` (the `AppToolbar` spec, and the `NativeToolbar` port that macOS fills as an `NSToolbar`).
  - In the `lib/services/` bullet, add `channel_native_toolbar.dart` and `channel_connection_sheet.dart`.
  - In "Native runners", add that `macos/Runner/NativeToolbarChannel.swift` implements `stash_player/toolbar` (the library's controls as a real `NSToolbar`) and `ConnectionSheetChannel.swift` implements `stash_player/connection_sheet` (the connection form as an AppKit sheet, with rules kept in Dart by `ConnectionSheetPresenter`). Also note that new Swift files need entries in `Runner.xcodeproj/project.pbxproj`.

- [ ] **Step 2: Look-and-feel spec.**
  - In its Decisions table, change the "In-content native views" row's decision to: "Not used inside content; the macOS toolbar and connection sheet are native (see `2026-09-24-macos-native-controls-design.md`)".
  - In §1's "Native" bullet, add "the macOS window toolbar and sheets".

- [ ] **Step 3: Settings-dialog spec.** Under its status line, add: "Amended by `2026-09-24-macos-native-controls-design.md`: on macOS the dialog is a native AppKit sheet, and the drawn macOS layout here is its fallback."

- [ ] **Step 4: Commit.** `git add -f docs/superpowers/specs/*.md` (`/docs` is gitignored, and tracked docs are force-added), then `git add CLAUDE.md` and `git commit -m "docs: native macOS toolbar and connection sheet"`

---

## Manual gates (macOS; from the spec, for whoever runs them)

These are the spec's §5 manual gates. They aren't automated. Add them to the PR description as an unticked checklist.
