# Native AppKit toolbar and connection sheet on macOS — design

**Date:** 2026-09-24
**Scope:** `apps/flutter/`, macOS only; Linux is unchanged
**Follows:** `2026-09-24-native-look-and-feel-design.md`,
`2026-09-24-settings-dialog-design.md` (built in #13; this replaces its
drawn macOS sheet at runtime)

## Goal

On macOS the library's titlebar strip and the connection form read as
imitations of AppKit. The strip is a row of flat tinted rectangles with
Material ink, the form's push buttons are colour fills with a hairline
border, and the icons are Lucide rather than SF Symbols. On macOS 27's
Liquid Glass chrome no drawn widget can match, and a drawn match would
drift again with the next release.

Replace both with real AppKit: an `NSToolbar` for the library's controls,
and a window sheet for the connection form. Both are described and driven
from Dart over method channels, the same pattern as the native menus.

The look-and-feel spec's organizing rule becomes: **native wherever macOS
draws system chrome** (menus, the menu bar, the toolbar, sheets); drawn
inside the content.

Out of scope: the player's controls (they sit over video and already look
right), the tasks popover's content, Linux, and ⌘F-to-search.

## 1. Native toolbar

### Spec (`lib/ui/toolbar/app_toolbar.dart`)

```dart
sealed class AppToolbarItem {
  // id (stable across rebuilds), label, tooltip, enabled
}
final class AppToolbarMenu<T> extends AppToolbarItem {
  // icon?, items (value + label), value, onChanged
}
final class AppToolbarToggle extends AppToolbarItem {
  // icon, selected, onPressed
}
final class AppToolbarAction extends AppToolbarItem {
  // icon, onPressed (null = disabled), badge
}
final class AppToolbarSearch extends AppToolbarItem {
  // text, placeholder, onChanged
}
final class AppToolbarGroup extends AppToolbarItem {
  // children: menus and toggles drawn as one capsule
}
final class AppToolbarSpace extends AppToolbarItem {} // flexible space
class AppToolbar { final List<AppToolbarItem> items; }
```

The spec is pure Dart and lives in `lib/ui/`, so it has no Riverpod.

`AppIcon` gains an SF Symbol name for every glyph, used only by native
surfaces. Lucide stays for everything drawn. Organized is tri-state, so it
maps to three symbols (any, yes, no), like its three `AppIcon`s today. A
unit test asserts that every `AppIcon` has a symbol name.

### Port (`lib/ui/toolbar/native_toolbar.dart`)

```dart
abstract interface class NativeToolbar {
  /// Replaces the window toolbar's items with [toolbar]. An empty
  /// toolbar leaves the titlebar spacer only. Completes with false if
  /// the native side is unavailable; the caller then draws its own strip.
  Future<bool> set(AppToolbar toolbar);
}
```

`lib/ui/` widgets find it through a `NativeToolbarScope` inherited widget.
The app root provides `ChannelNativeToolbar` on macOS and no scope
elsewhere. With no scope, as on Linux and in most widget tests, the
library draws today's strip.

### Channel (`stash_player/toolbar`)

`ChannelNativeToolbar` (`lib/services/`) keeps an `id → item` table for
dispatch.

- **Dart → Swift:** `setItems(list)`, the whole spec serialized as maps,
  and `reset` (see §4).
- **Swift → Dart:**
  - `activated(id, rect)`: `rect` is the item's frame in the Flutter
    view's logical coordinates (top-left origin), so a caller can anchor
    a drawn popover to it. It is null when the item was chosen from the
    overflow menu. `AppToolbarAction.onPressed` is
    `void Function(Rect? anchor)?`
  - `menuSelected(id, index)`
  - `searchChanged(id, text)`

### Swift (`macos/Runner/NativeToolbarChannel.swift`)

An `NSToolbarDelegate` on the existing unified spacer toolbar
(`MainFlutterWindow.swift`). The spacer stays because it is what centres
the traffic lights in the 52pt titlebar.

| Spec | AppKit |
|---|---|
| `AppToolbarMenu` | `NSMenuToolbarItem`, current value checked (`state = .on`) |
| `AppToolbarToggle` | `NSToolbarItem` with a toggle-type `NSButton` (`setButtonType(.pushOnPushOff)`), `state` from `selected` |
| `AppToolbarAction` | `NSToolbarItem` with an `NSButton`; `badge` via `NSToolbarItem.badge = .indicator` on macOS 26+ |
| `AppToolbarSearch` | `NSSearchToolbarItem` |
| `AppToolbarGroup` | `NSToolbarItemGroup` of the children's items, drawn as one capsule |
| `AppToolbarSpace` | `.flexibleSpace` |

Images are `NSImage(systemSymbolName:accessibilityDescription:)` with the
item's label as the description, and `toolTip` comes from `tooltip`.

`setItems` reconciles by `id`:
- An item whose id and kind are unchanged is updated in place: state,
  enabled, image, badge, menu checkmarks, and search text. The search text
  only changes if it differs, so the caret doesn't jump while typing.
- Items that were added, removed or reordered go through
  `insertItem(withItemIdentifier:at:)` and `removeItem(at:)`.

A filter change therefore never rebuilds the toolbar or flickers it.

`allowsUserCustomization` is off, since the item set is fixed by the
screen. AppKit's overflow chevron (`»`) takes items the window is too
narrow to show.

### Library on macOS

`LibraryToolbar` checks `NativeToolbarScope`. When a native toolbar is
there, it:

- builds an `AppToolbar`:
  - a group of sort (menu), direction (action: it isn't on/off, so each
    press flips it and its icon shows the current direction), minimum
    rating (menu), organized (toggle) and hide watched (toggle)
  - play random (action)
  - flexible space
  - search
  - scan (action)
  - tasks (action, `badge: tasksActive`)
- publishes it only while `publishNative` is true. `LibraryScreen` passes
  `ref.watch(appControllerProvider) is LibraryDestination`. This is not
  `ModalRoute.isCurrent`, because the tasks popover is a route too, and
  opening it would clear the toolbar. Publishing happens after every
  build (the channel drops a spec identical to the last one sent). When
  `publishNative` turns false, and again in `dispose`, it publishes an
  empty toolbar
- renders only an empty band of `AppWindowChrome.stripHeightFor(macOS)`
  in the chrome colour, which still drags the window
  (`isMovableByWindowBackground`)

There is no settings item: the settings-dialog spec moves settings to the
menu bar's "Settings…" (⌘,) on macOS.

Because of this, the narrow two-row layout, the Filters toggle and the
strip's `FocusTraversalOrder` don't apply on macOS. AppKit's overflow
replaces the first two, and Full Keyboard Access replaces the third.

Behaviour that stays in Dart and is shared with the drawn strip:
- the 250 ms search debounce, which runs on `searchChanged`
- `cycleOrganized`
- the minimum-rating sentinel
- the spec's search text is `_searchController.text`. A `searchChanged`
  sets it straight away, and "Clear filters" sets it in
  `didUpdateWidget`, as today. Swift applies an incoming text only while
  the search field isn't being edited (its field editor isn't the
  window's first responder). A republish that lands mid-typing therefore
  can't overwrite a newer keystroke

Tasks: `activated('tasks', rect)` opens `showTasksPopover` anchored to
`rect`. The popover stays drawn and only its anchor changes source.
`showTasksPopover` gains an overload that takes a `Rect` in place of the
anchor `BuildContext`.

### Other destinations

The library is the only publisher. `AppRouter` keeps the library page
mounted under the scene page, so opening a scene turns `publishNative`
false and the library clears the toolbar. Returning to the library turns
it back on and the library republishes. The connection destination replaces the
library page, so `dispose` clears the toolbar there. On those screens the
titlebar is the bare spacer toolbar, exactly as today, so `PlayerTopBar`'s
traffic-light metrics don't change.

## 2. Native connection sheet

The settings dialog (#13) already ships a drawn macOS sheet:
`AppDialog._macos`, pushed as an `AppDialogPage` by `AppRouter`. This
design keeps that code as the fallback and puts a real AppKit sheet in
front of it. These parts of the settings-dialog design still apply
unchanged on macOS:
- the `settingsOpen` router state, `openSettings`/`closeSettings`
- the menu bar "Settings…" (⌘,) item
- `ConnectionFields`/`ConnectionForm`, which remain Linux's form and the
  macOS fallback

### Port (`lib/features/connection/connection_sheet.dart`)

```dart
abstract interface class ConnectionSheet {
  /// Shows the sheet. [onEvent] receives edits, submit and cancel until
  /// [dismiss]. Throws `MissingPluginException`/`PlatformException` when
  /// the native side is unavailable.
  Future<void> present(
    ConnectionSheetRequest request,
    void Function(ConnectionSheetEvent event) onEvent,
  );
  Future<void> update(ConnectionSheetState state);
  Future<void> dismiss();
}
// ConnectionSheetRequest: title, confirmLabel, cancellable, url, apiKey,
//   proxy, proxyHint
// ConnectionSheetState: canSubmit, busy, urlError?, proxyError?, failure?
// ConnectionSheetEvent: Changed(values) | Submitted(values) | Cancelled
```

`ChannelConnectionSheet` (`lib/services/`) implements it over
`stash_player/connection_sheet`, with methods `present`, `update`,
`dismiss` and `reset`, and events `changed`, `submitted` and `cancelled`.
`present` returns an error if a sheet is already open.

### Presenter (`lib/features/connection/connection_sheet_presenter.dart`)

The presenter holds every rule in Dart and bridges the sheet to
`ConnectionController`:

- On `changed`, it records the values and sends `update` with
  `canSubmit` set to `values.serverUrl.trim().isNotEmpty`, the same rule
  as `ConnectionFields.canSubmit`.
- On `submitted`, it calls `testAndSave(values)`.
- While it runs, it mirrors the controller: `busy` follows
  `ConnectionPhase.loading`, and `urlError`, `proxyError` and `failure`
  follow `fieldError`, `proxyFieldError` and `failure`.
- On `ready`, it dismisses the sheet. In settings mode it also calls
  `replaceConnection(config)`, which shows the "Connected to …" toast.
- On `cancelled`, it calls `closeSettings()`.

Seeding: the presenter awaits `controller.load()` (local storage, env
overrides included) before it calls `present`, and it passes the loaded
config as the request's field values. Nothing is typed before the sheet
exists, so the drawn form's "don't clobber typed text" race can't
happen, and `ConnectionFields` isn't needed. The presenter tracks the
latest values from `changed` in a plain `ConnectionConfig`.

### Swift (`macos/Runner/ConnectionSheetChannel.swift`)

`window.beginSheet` with an `NSPanel` whose content is:

- a bold title (`NSFont.boldSystemFont`, 13pt)
- an `NSGridView` with right-aligned labels "Server URL:", "API Key:" and
  "SOCKS5 Proxy:", and an `NSTextField`, an `NSSecureTextField` and an
  `NSTextField` with placeholders
- under each field, a small (11pt) `systemRed` label for its error,
  hidden when empty
- under the proxy field, `proxyHint` as a small `secondaryLabelColor`
  label
- `failure` as a `systemRed` line above the buttons
- a bottom-right button row:
  - Cancel: `keyEquivalent = "\u{1b}"`, omitted when not `cancellable`
  - the confirm button: `keyEquivalent = "\r"`, which makes it the
    default button with the accent colour
- a small spinning `NSProgressIndicator` left of the buttons, shown while
  `busy`

`busy` disables the fields and both buttons, which keeps the settings
spec's rule that the sheet can't close mid-test. The confirm button's
`isEnabled` is `canSubmit && !busy`. Every edit sends `changed` through
`controlTextDidChange`.

There is no reveal toggle on the API key, following the AppKit
convention for secure fields.

### Uses

- **First launch:** on macOS, `ConnectionScreen` draws only the window
  background and presents the sheet with `title: 'Connect to Stash'`,
  `confirmLabel: 'Connect'` and `cancellable: false`.
- **Settings:** on macOS, when a `ConnectionSheet` is provided,
  `AppRouter._pagesFor` doesn't add `_settingsPage` for `settingsOpen`. Instead a `ConnectionSheetHost` in the library screen
  watches `settingsOpen` and presents the sheet with
  `title: 'Connection'`, `confirmLabel: 'Save'` and `cancellable: true`.
  When the flag clears, it dismisses the sheet.

When no `ConnectionSheet` is provided, as in widget tests, the drawn path
from #13 is used: `ConnectionScreen`, and `ConnectionSettingsDialog` in
`AppDialog`'s macOS layout. If `present` throws `MissingPluginException`,
the host calls `connectionSheetProvider.notifier.disable()`, which sets
the provider to null for the rest of the session. The router watches the
provider, so it adds `_settingsPage` again, and `ConnectionScreen` draws
its form again.

## 3. Wiring

- `providers.dart` gains `nativeToolbarProvider` (the channel
  implementation on macOS, null elsewhere) and `connectionSheetProvider`.
  The latter is a `Notifier<ConnectionSheet?>`: `ChannelConnectionSheet`
  on macOS, null elsewhere, and set to null by `disable()` after a channel
  failure.
- `app.dart` provides `NativeToolbarScope` from the first.
- `MainFlutterWindow.swift` registers `NativeToolbarChannel` (with the
  window and its toolbar) and `ConnectionSheetChannel` (with the window),
  next to `NativeMenuChannel`.

## 4. Error handling

- **Toolbar channel failure** (`MissingPluginException` or
  `PlatformException` from `setItems`): `LibraryToolbar` falls back to the
  drawn strip for the rest of the session. It logs once through
  `lib/shared/diagnostics.dart`.
- **Unknown ids** in a toolbar event: nothing runs. Ids are stable per
  item, so reconciling never re-targets a callback.
- **Sheet channel failure:** the drawn form, as described in §2.
- **Hot restart:** on its first attach, each Dart channel sends `reset`.
  Swift ends any open sheet and empties the toolbar, so a sheet left over
  from the previous isolate can't strand a debug session.
- **OS floor:** the deployment target stays macOS 14.
  - Everything above works there except `NSToolbarItem.badge` (macOS
    26+).
  - Below 26, the tasks item shows the filled variant of its symbol while
    `badge` is true.
  - The badge path is behind `#if compiler(>=6.2)`, so only an Xcode 26
    build compiles it. Release builds run on Xcode 16, so shipped CI
    builds always use the filled-symbol fallback, even on macOS 26.
  - The glass capsule look is whatever the running OS draws for a
    toolbar item group.

## 5. Testing

**Unit**
- Toolbar spec serialization: every item kind, menu check state, groups.
- Event decoding and dispatch: `activated` with a rect, `menuSelected`,
  `searchChanged`, unknown ids.
- Fallback when the plugin is missing.
- Every `AppIcon` has an SF Symbol name.
- Sheet request/state serialization.
- `ConnectionSheetPresenter` against a fake sheet and controller:
  - `canSubmit` follows `changed`
  - busy and errors mirror a failed test
  - success dismisses (and in settings mode calls `replaceConnection`)
  - cancel calls `closeSettings`

**Widget** (with `platform: TargetPlatform.macOS` and a recording
`NativeToolbar` fake)
- `LibraryToolbar` publishes the expected spec and republishes on filter
  and `tasksActive` changes.
- Events route to the right callbacks, and search is debounced.
- "Clear filters" carries the new search text.
- Tasks opens the popover at the reported rect.
- The band has no drawn controls.
- With no scope, the strip is drawn: macOS falls back, and Linux is
  unchanged.
- Pushing a scene route publishes an empty toolbar, and popping it
  republishes the library's items. Disposing the toolbar publishes an
  empty one.
- On macOS, first launch presents a non-cancellable sheet through a fake
  `ConnectionSheet`, and `settingsOpen` presents a cancellable one.

**Manual gates** (leave unticked for whoever runs them)
- [ ] macOS 27: the library toolbar shows SF Symbols, and the sort/filter
      group renders as one glass capsule.
- [ ] Narrowing the window moves items into `»`, and each still works
      from there, including the menus.
- [ ] Changing sort, rating, organized and hide watched updates the
      checkmarks and toggle states with no toolbar flicker.
- [ ] Typing in search filters after the debounce. "Clear filters" empties
      the field.
- [ ] While a scan runs, the tasks item shows its badge. Clicking it opens
      the popover under the item.
- [ ] The scene and connection screens show no toolbar items, and the
      traffic lights haven't moved.
- [ ] Full Keyboard Access (Tab with it enabled) reaches the toolbar items.
- [ ] ⌘, opens the sheet. Esc cancels. A bad URL shows a red error under
      the field while the sheet stays open. Busy disables everything.
      Return with a good URL saves, closes the sheet and shows the toast.
- [ ] First launch (no stored connection) shows the sheet with no Cancel.
      Connect works.
- [ ] A build running on macOS 14 or 15 shows the toolbar, and the tasks
      badge fallback appears while a scan runs.
- [ ] Hot restart with the sheet open closes it.

`just flutter-check` stays the CI gate. There are no new CI jobs.

## 6. Delivery order

The settings dialog (#13) is already on `main`, so nothing blocks this.
Each step leaves the app shippable:

1. The toolbar spec, the `NativeToolbar` port, `NativeToolbarScope`, and
   SF Symbol names on `AppIcon`.
2. `ChannelNativeToolbar`, `NativeToolbarChannel.swift`, and
   `LibraryToolbar`'s macOS branch, plus the empty toolbar from the other
   screens and the tasks popover's rect anchor.
3. The `ConnectionSheet` port, `ChannelConnectionSheet`,
   `ConnectionSheetChannel.swift`, the presenter, and both uses.
4. Docs:
   - CLAUDE.md: the runner channel list, and the toolbar and sheet under
     `lib/ui/`
   - the look-and-feel spec: its organizing rule and "In-content native
     views" row now point here
   - the settings-dialog spec: a note that its macOS sheet is now the
     fallback behind the native one
