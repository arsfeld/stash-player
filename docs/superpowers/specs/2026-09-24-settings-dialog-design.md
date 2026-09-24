# Connection settings as a dialog

Status: approved design, 2026-09-24. Follows
`2026-09-24-native-look-and-feel-design.md`.

## Goal

Connection settings today is `ConnectionScreen(settingsMode: true)` pushed
as a full-screen `MaterialPageRoute` from the library toolbar's gear button.
Replace it with a modal dialog that is drawn in Flutter but shaped like each
platform's own: an `AdwDialog`-style card with a header bar on Linux, a
window sheet on macOS. Entry points move to each platform's convention:
the macOS app menu's "Settings…" (⌘,) and a GNOME primary menu on Linux.

This is "drawn to match" under the look-and-feel spec's organizing rule:
the dialog's content is Flutter widgets, not a native window or native text
fields.

Out of scope: an About dialog on Linux, opening settings from the player,
Flutter multi-window, and any change to the first-launch connection page
beyond sharing its form with the dialog.

## 1. Navigation: settings as router state

Settings becomes part of `AppController`'s state, not an imperative
`Navigator.push`.

- `LibraryDestination` gains `final bool settingsOpen` (default `false`),
  with `==`/`hashCode`. `AppDestination.library({bool settingsOpen})`
  forwards it.
- `AppController.openSettings()` sets `library(settingsOpen: true)`, and
  only when the current destination is `LibraryDestination`. Anywhere else
  it does nothing.
- `AppController.closeSettings()` sets `library()`.
- `AppRouter._pagesFor` returns `[_libraryPage, _settingsPage]` when
  `settingsOpen` is true. `_settingsPage` is a `SettingsDialogPage` (a
  `Page` that builds a `RawDialogRoute`-style modal route: barrier, no
  full-screen replacement), keyed `ValueKey('settings')`, named `settings`.
- `onDidRemovePage` for the `settings` page calls `closeSettings()`. That
  covers Cancel, Esc and (Adwaita) a click on the barrier, since all three
  pop the route.
- `replaceConnection` already sets `library()` on success, so the settings
  page leaves the list and the dialog closes with no `Navigator.pop` and no
  `context.mounted` check.
- `_LibraryRoute` and `_SettingsRoute` in `app_router.dart` are removed.
  `LibraryScreen`'s `onOpenSettings` becomes
  `ref.read(appControllerProvider.notifier).openSettings()` inside the
  library feature itself, so the parameter goes away.

## 2. `AppDialog` (`lib/ui/widgets/app_dialog.dart`)

A new drawn widget in `lib/ui/`. It follows that layer's rules: no Riverpod,
and the platform is picked through `PlatformDialect.of(context)`.

```dart
AppDialog({
  required String title,
  required Widget child,
  required AppDialogAction cancel,   // label + onPressed
  required AppDialogAction confirm,  // label + onPressed (null = disabled) + busy
})
```

- **Adwaita**: a centred card, max width 460, corner radius 12.
  A flat header bar holds the cancel button (flat) at the
  start, the title (bold, centred) and the confirm button (suggested action:
  accent fill) at the end. The body scrolls. The barrier dims the window and
  clicking it dismisses the dialog.
- **macOS**: a sheet attached to the top edge of the window, sliding down
  (about 200 ms). It has a bold centred title, then the body, then a
  bottom-right button row: Cancel, and confirm as the default (accent)
  button. Clicking the barrier does not dismiss it.
- Both: Esc runs cancel. Return runs confirm when it is enabled. On macOS
  that is the default-button convention; on Adwaita it follows the entry
  rows' activation. While `busy`, confirm shows `AppSpinner` in place of its
  label and is not pressable.

Form building blocks in the same file (or `app_form.dart` if it grows):

- `AppPreferencesGroup(title, description?, children)`: on Adwaita, a
  heading above a boxed list (rounded card, 1px separators between rows)
  with an optional dimmed description below. On macOS, plain rows with no
  card; the title is omitted when there is only one group.
- `AppEntryRow(label, controller, focusNode, obscure, trailing,
  errorText, …)`: on Adwaita, like `AdwEntryRow`, with the label inside the
  row and the field filling the rest, and the error in the error colour
  below the group row. On macOS, a right-aligned `Label:` column and a
  bordered text field, with the error below the field.

## 3. `ConnectionForm` (`lib/features/connection/connection_form.dart`)

This is extracted from `ConnectionScreen` so the first-launch page and the
dialog share one copy of the tricky logic.

- It owns the three `TextEditingController`s, the focus nodes, the API key
  show/hide toggle, `load()` on mount, and `_applyLoadedConfig`'s "don't
  clobber text the user typed" seeding. These move over unchanged.
- It renders the fields as two groups: **Server** (URL, and the API key with
  its eye toggle) and **Network** (SOCKS5 proxy, with the Tailscale hint as
  the group description). It uses `AppPreferencesGroup`/`AppEntryRow`, and
  also shows the controller's `fieldError`, `proxyFieldError` and `failure`.
- It exposes a `ConnectionFormController` (or a `GlobalKey<…State>`
  handle) with `ConnectionConfig current` and `bool get canSubmit` (the URL
  is not blank), so the host decides which button submits.

`ConnectionScreen` keeps being the full-screen first-launch page: the
"Connect to Stash" heading, `ConnectionForm`, and a "Connect" button that
runs `testAndSave`. `settingsMode`, `onCancel` and its `AppWindowChrome`
branch are removed.

## 4. `ConnectionSettingsDialog` (`lib/features/connection/`)

`AppDialog(title: 'Connection', cancel: Cancel, confirm: Save)` around
`ConnectionForm`.

- **Save** is enabled when `canSubmit` holds and the controller is not
  loading. It calls `testAndSave(form.current)`, and `busy` follows
  `ConnectionPhase.loading`. The fields are disabled while it is loading.
- A `ref.listen` on the transition to `ready` calls
  `appController.replaceConnection(config)`, which closes the dialog and
  shows the "Connected to …" toast.
- If it fails, the dialog stays open: `fieldError` shows under the URL row,
  `proxyFieldError` under the SOCKS row, and `failure` as an error line
  below the groups.
- Cancel, Esc and the barrier close the dialog without saving. A test still
  in flight when the dialog closes is ignored, because only the dialog's
  own listener calls `replaceConnection`, and it is gone by then. Reopening
  seeds from storage again, env overrides included (`STASH_URL`/
  `STASH_API_KEY`), the same as today.

## 5. Entry points

- **macOS**: the toolbar has no settings control. `buildMacMenuBar` gains
  an `onOpenSettings` callback, `null` when disabled. After the "About /
  Check for Updates…" group it adds a group of its own with
  `PlatformMenuItem(label: 'Settings…', shortcut: SingleActivator(
  LogicalKeyboardKey.comma, meta: true))`. `AppMenuBar` passes
  `openSettings` only while `destination is LibraryDestination` and `null`
  otherwise (disabled).
- **Linux**: the gear becomes a primary menu button (`AppIcon.mainMenu`,
  GNOME `open-menu-symbolic`, and on macOS a Lucide `menu` mapping for
  completeness, although it is never shown there) at the end of the
  toolbar, tooltip "Main Menu". It shows an `AppMenu` spec through
  `NativeMenus` (a native `GtkMenu`, falling back to the drawn menu) with
  a single item, **Preferences**, whose shortcut label is Ctrl+,.
  `LibraryScreen` wraps its body in `CallbackShortcuts` with
  `SingleActivator(comma, control: true)` → `openSettings()`, so the
  shortcut works only in the library, not the player. On macOS the menu
  bar item's own shortcut covers ⌘,.
- The toolbar's tab-order values stay contiguous after the change: the
  primary menu takes the old settings slot on Linux, and on macOS the last
  slot is dropped.

## 6. Tests

- `app_controller_test`: `openSettings` from the library sets
  `settingsOpen`, and it does nothing from the scene and connection
  destinations. `closeSettings` clears the flag, and a successful
  `replaceConnection` clears it too.
- `app_router_test`: `settingsOpen` stacks the dialog over the library page.
  Popping it (Esc) calls `closeSettings`.
- `app_dialog_test` (both dialects, via `ThemeData.platform`): Adwaita shows
  the header-bar layout and barrier dismissal. macOS shows the bottom
  button row, and the barrier does not dismiss. On both, Return confirms,
  Esc cancels and busy shows the spinner.
- `connection_form_test`: the existing seeding and "don't clobber" tests,
  moved from `connection_screen_test`, plus rendering of the field errors.
- `connection_settings_dialog_test`: Save disabled on an empty URL and while
  loading. A failure keeps the dialog open with inline errors. Success calls
  `replaceConnection`.
- `connection_screen_test`: the first-launch page still connects, and has no
  settings-mode chrome.
- `app_menu_bar_test`: Settings… is present with ⌘, and disabled off the
  library.
- `library_toolbar_test`: no settings control on macOS. On Linux the primary
  menu exists and its spec contains Preferences. Ctrl+, in the library opens
  settings.

`just flutter-check` gates the change.

## Manual checks

- [ ] Linux: the primary menu opens a native GTK menu, Preferences opens the
      dialog, Ctrl+, opens it from the library but not from the player.
- [ ] Linux: a wrong URL keeps the dialog open with the error under the URL
      row, and a good one closes it and shows the toast.
- [ ] macOS: Stash Player → Settings… and ⌘, open the sheet, the item is
      disabled while a scene plays, and Return saves.
- [ ] Both: Esc cancels mid-test without applying the result.
