# Native look and feel on Linux and macOS — design

**Date:** 2026-09-24
**Scope:** `apps/flutter/` only

## Goal

Make the Flutter client look and behave like a platform app on each OS:
a libadwaita app on Linux and an AppKit app on macOS. Screens, layout and
controllers stay shared. Only the widget layer (`lib/ui/`) and the two
native runners change, and every menu's behaviour is defined once in Dart.

## Decisions

| Topic | Decision |
|---|---|
| Approach | Two dialects (Adwaita, macOS) from one codebase, switched on `Theme.of(context).platform` |
| Organizing rule | Native where the OS shows its own popup (menus, menu bar, alerts); drawn per dialect inside the content |
| Menus | Real `NSMenu` (macOS) and `GtkMenu` (Linux) over a method channel, from one Dart spec |
| Menu bar | macOS only, via `PlatformMenuBar`, built from the same specs; none on Linux (GNOME convention) |
| Accent colour | Read from the OS, live; falls back to `#3584E4` |
| Icons | Adwaita symbolic on Linux; Lucide on macOS |
| In-content native views | Not used (no `NSSlider` etc. platform views) |

Out of scope: the Linux double titlebar (runner `GtkHeaderBar` plus the
app's own strip), MPRIS / Now Playing / media keys, sleep inhibition,
remembering window geometry, and ⌘/Ctrl shortcut conventions. Those are
the "window chrome" and "OS integration" follow-ups.

## 1. Organizing rule

- **Native** — anything the OS presents as its own popup or window:
  context and dropdown menus, the macOS menu bar, confirmation alerts.
- **Drawn to match** — anything inside the Flutter content: buttons,
  sliders, text fields, switches, toasts, progress indicators, tooltips,
  icons, and content-bearing popovers (the tasks popover).

Feature code never picks a platform. It builds a spec or a `lib/ui/`
widget, and the platform choice happens underneath.

## 2. Native menus (`lib/ui/menu/`)

### Spec (`app_menu.dart`)

Pure Dart, no Flutter imports beyond `services.dart` for keys:

```dart
sealed class AppMenuEntry {}
final class AppMenuItem extends AppMenuEntry {
  // label, enabled, checked (null = not a check item),
  // shortcut (AppMenuShortcut?), onSelected (VoidCallback)
}
final class AppMenuSeparator extends AppMenuEntry {}
final class AppSubmenu extends AppMenuEntry { /* label, entries */ }
final class AppMenu { final List<AppMenuEntry> entries; }
```

`AppMenuShortcut` wraps a `LogicalKeyboardKey` plus modifiers. Player
shortcuts come from `playerKeyBindings`, so a menu can't show a key that
doesn't work. A unit test asserts that every shortcut shown in a menu is
bound.

### Port (`native_menus.dart`)

```dart
abstract interface class NativeMenus {
  /// Shows [menu] anchored below [anchor] (global logical coordinates)
  /// and runs the chosen item's callback. Completes when the menu closes.
  Future<void> show(AppMenu menu, Rect anchor);
}
```

- **`ChannelNativeMenus`** serializes the spec to a tree of maps. Each
  item gets a generated integer id, and callbacks stay in a Dart-side
  `id → callback` table. It sends `show` on `stash_player/menu` with the
  tree plus the anchor rect, and receives the chosen id or null.
  - **macOS** (`macos/Runner/NativeMenuChannel.swift`) builds an
    `NSMenu` (with `state = .on` for checked items and `keyEquivalent`
    plus modifier mask for shortcuts, display only) and calls
    `popUp(positioning:at:in:)` on the Flutter view, flipping the y axis.
  - **Linux** (`linux/runner/native_menu_channel.cc`) builds a `GtkMenu`
    of `GtkMenuItem`/`GtkCheckMenuItem`/`GtkSeparatorMenuItem` with
    accelerator labels, then calls `gtk_menu_popup_at_rect` against the
    `FlView`'s `GdkWindow` (`GDK_GRAVITY_SOUTH_WEST` →
    `GDK_GRAVITY_NORTH_WEST`). A `GtkMenu` opens as its own popup surface
    (an xdg_popup on Wayland), so it composes over the Flutter view.
    It replies on `activate` / `deactivate`.
- **`DrawnMenus`** renders the same spec with a dialect-styled
  `MenuAnchor`. Widget tests use it, and it is the runtime fallback.

A Riverpod provider picks `ChannelNativeMenus` on macOS/Linux and
`DrawnMenus` otherwise. Tests override it with a recording fake.

### Call sites converted

- Sort and filter dropdowns in `lib/ui/widgets/filter_controls.dart`
  (currently `showMenu`).
- The stream picker in `lib/features/player/player_top_bar.dart`
  (currently `PopupMenuButton<SceneStream>`).

The tasks popover (`tasks_popover.dart`) holds content, not commands, so
it stays drawn and only picks up the dialect styling.

### macOS menu bar

A `PlatformMenuBar` near the app root, built from `AppMenu` specs via a
small `AppMenu → PlatformMenu` adapter:

- **App menu**: About, Check for Updates…, Hide/Hide Others/Show All,
  Quit.
- **Edit**: Cut, Copy, Paste, Select All (for the text fields).
- **Playback** (enabled only on the scene screen): Play/Pause, Seek ±5s /
  ±10s / ±60s, Volume Up/Down, Mute.
- **View**: Enter/Exit Full Screen.

The scene screen publishes its current `AppMenu`s through a provider so
enabled and checked state tracks playback. `MainMenu.xib` shrinks to what
`PlatformMenuBar` can't provide: the Sparkle "Check for Updates…" action,
which `AppDelegate.swift` already owns, is kept there. The leftover
template items (Find, Spelling, Substitutions, the unwired Preferences…)
go.

## 3. Drawn dialects (`lib/ui/theme/`)

### Dialect selection

`AppTokens` gains `PlatformDialect dialect` (`adwaita` | `macos`), set in
`buildAppTheme` from `ThemeData.platform`. Widgets read it from the theme
extension, the same way `AppWindowChrome` already reads the platform, so
a widget test can pin either dialect. Windows and other platforms get
`adwaita`.

### Per-dialect tokens

| Token | Adwaita | macOS |
|---|---|---|
| Font | System UI font from portal `org.gnome.desktop.interface font-name`, else Cantarell, else default | `.AppleSystemUIFont` (SF Pro) |
| Body size | 14.67 px (11 pt) | 13 px |
| Control radius / panel radius | 6 / 12 | 5 / 10 |
| Control height | 34 | 22 (regular) / 28 (toolbar) |
| Accent use | Suggested-action buttons, focus rings, switch on, slider fill | Default push button, focus rings, switch on, slider fill |

The palette in `app_theme.dart` splits into `AdwaitaPalette` (libadwaita
1.6 named colours: `window_bg`, `view_bg`, `headerbar_bg`, `card_bg`,
light and dark) and `MacPalette` (`windowBackgroundColor`,
`controlBackgroundColor`, `separatorColor`, label colours, light and
dark). The fixed palette values are compiled in. Only the accent is read
from the OS.

### Widgets

Each is a single `lib/ui/widgets/` widget that switches on dialect
internally:

- **`AppButton`** (`flat`, `suggested`, `destructive`): Adwaita flat or
  pill buttons; macOS bordered push buttons with the accent-filled
  default. Replaces direct `FilledButton` / `OutlinedButton` /
  `TextButton` use.
- **`AppSwitch`**: Adwaita pill switch; macOS switch (smaller, with the
  knob shadow).
- **`AppSlider`**: Adwaita 4px trough with a round 20px knob; macOS 4px
  track with a white 20px knob with a shadow. Used by `player_bar.dart`'s
  `_PlayerSlider`, which keeps its own layout.
- **`AppSpinner`**: Adwaita arc spinner; macOS spoked activity indicator.
  Replaces `CircularProgressIndicator`. The `LinearProgressIndicator` gets
  dialect theming only.
- **Text fields**: styled through `InputDecorationTheme` per dialect
  (Adwaita filled with a focus ring; macOS bezel with an accent focus
  ring).
- **Tooltips**: `TooltipThemeData` per dialect (Adwaita dark rounded
  bubble; macOS light rectangle with a hairline border, 11pt).
- **Toasts**: `AppToastHost` replaces the `SnackBar` in `app.dart`,
  still driven by `globalNoticeProvider`. Adwaita shows a bottom-centred
  dark pill with an optional action button, like `AdwToast`. macOS shows
  a top-centred translucent HUD banner that fades out. Severity colouring
  keeps today's mapping.

### Accent colour (`stash_player/appearance`)

An `EventChannel` streams the OS accent as an ARGB int:

- **macOS**: `NSColor.controlAccentColor` converted to sRGB. Re-sent on
  `NSSystemColorsDidChangeNotification`.
- **Linux**: portal `org.freedesktop.portal.Settings.ReadOne("org.freedesktop.appearance", "accent-color")`
  (an `(ddd)` RGB tuple, GNOME 47+), plus the `SettingChanged` signal. The
  same channel carries `font-name` from `org.gnome.desktop.interface`.
  This works inside the Flatpak because the portal is always reachable.

`appearanceProvider` (a `StreamProvider`) feeds `buildAppTheme(brightness,
appearance)`. Until the first value arrives, or if the channel fails, the
theme uses `#3584E4` and the dialect's default font.

### Icons (`lib/ui/icons/app_icons.dart`)

`AppIcons` names each of the roughly 35 glyphs the app uses by meaning
(`AppIcons.play`, `.pause`, `.seekBack10`, `.search`, `.filter`,
`.settings`, `.error`…) and resolves them per dialect:

- **Adwaita**: symbolic SVGs from GNOME's `adwaita-icon-theme`
  (CC-BY-SA 3.0 / LGPL-3.0), bundled under `assets/icons/adwaita/` and
  rendered with a small tinting SVG widget. The licence text ships as
  `assets/icons/adwaita/COPYING`, with attribution in `README.md`.
- **macOS**: Lucide (ISC licence), via the Lucide icon font bundled as an
  asset or an equivalent maintained package, whichever needs no native
  code. Lucide's 1.5–2px strokes sit closest to SF Symbols' regular
  weight.

If either set lacks a glyph (for example the 10-second seek icons), a
composed glyph (the base arrow plus a small "10" label) is drawn instead
of mixing in Material icons. No `Icons.*` references remain in `lib/`.
An analyzer-level test (a grep test in `test/`) enforces that.

## 4. Error handling

- A missing or failing `stash_player/menu` channel (`MissingPluginException`
  or a `PlatformException`): `ChannelNativeMenus` falls back to
  `DrawnMenus` for that call, and logs once per session through
  `lib/shared/diagnostics.dart`.
- Stale callbacks: the `id → callback` table is scoped to one `show`
  call and discarded when the call completes, so a late reply can't fire
  an old item.
- Appearance channel failure or a missing portal key: the fallback accent
  and font, with no user-visible notice.
- Only one native menu can be open at a time. A second `show` while one
  is open closes the first (natively this happens anyway; the Dart side
  completes the first future with no selection).

## 5. Testing

- **Unit**: spec serialization round-trips (ids, check state, shortcut
  encoding); every menu shortcut exists in `playerKeyBindings` or the
  Edit set; `AppMenu → PlatformMenu` adapter output.
- **Widget**: each converted call site with a recording `NativeMenus`
  fake (selecting an id runs the right callback); each `lib/ui/` widget
  under both dialects by pinning `platform`; the toast host driven by
  `globalNoticeProvider`; the theme rebuilt when `appearanceProvider`
  emits a new accent.
- **Golden**: the scene tile, library toolbar, player bar, a toast, and
  a `DrawnMenus` menu, per dialect and brightness (4 images per
  surface). Goldens use a bundled test font so they are deterministic.
- **Manual gates** (the release spec's §6 pattern), on GNOME
  Wayland (Flatpak) and macOS: native menus open at the anchor and select
  correctly, including from the fullscreen player; the menu bar's Playback
  items act and reflect state; changing the system accent recolours the
  app live; the fonts match the system.

`just flutter-check` stays the CI gate. There are no new CI jobs.

## 6. Delivery order

Each step leaves the app shippable:

1. Dialect plumbing plus palettes and fonts (`AppTokens.dialect`, split
   palettes, per-dialect type scale).
2. Accent channel (`stash_player/appearance`, both runners).
3. `AppIcons` and both icon sets; remove `Icons.*`.
4. Drawn widgets: button, switch, slider, spinner, fields, tooltips,
   toasts.
5. Menu spec, `DrawnMenus`, and conversion of the three call sites.
6. `ChannelNativeMenus` with the macOS and Linux implementations.
7. The macOS `PlatformMenuBar` and `MainMenu.xib` cleanup.
