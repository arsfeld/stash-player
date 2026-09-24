# Native look and feel on Linux and macOS — design

**Date:** 2026-09-24
**Scope:** `apps/flutter/` only
**Plan:** `docs/superpowers/plans/2026-09-24-native-look-and-feel.md`

## Goal

Make the Flutter client look and behave like a platform app on each OS:
a libadwaita app on Linux and an AppKit app on macOS. Screens, layout and
controllers stay shared. Only the widget layer (`lib/ui/`) and the two
native runners change, and every menu's behaviour is defined once in Dart.

## Decisions

| Topic | Decision |
|---|---|
| Approach | Two dialects (Adwaita, macOS) from one codebase, switched on `Theme.of(context).platform` |
| Organizing rule | Native where the OS shows its own popup (menus, menu bar); drawn per dialect inside the content |
| Menus | Real `NSMenu` (macOS) and `GtkMenu` (Linux) over a method channel, from one Dart spec |
| Menu bar | macOS only, via `PlatformMenuBar`, built from the same specs; none on Linux (GNOME convention) |
| Accent colour | Read from the OS, live; falls back to `#3584E4` |
| UI font | GNOME's interface font on Linux (from the settings portal); the system font on macOS |
| Icons | GNOME icon-development-kit (CC0) on Linux; Lucide (ISC) on macOS |
| In-content native views | Not used (no `NSSlider` etc. platform views) |

Out of scope: the Linux double titlebar (runner `GtkHeaderBar` plus the
app's own strip), MPRIS / Now Playing / media keys, sleep inhibition,
remembering window geometry, ⌘/Ctrl shortcut conventions, and native
alerts (the app shows no confirmation dialogs yet). Those are the "window
chrome" and "OS integration" follow-ups.

## 1. Organizing rule

- **Native**: anything the OS presents as its own popup: context and
  dropdown menus, and the macOS menu bar. Alerts would join this list
  when the app first needs one.
- **Drawn to match**: anything inside the Flutter content: buttons, text
  fields, toasts, progress indicators, tooltips, icons, and
  content-bearing popovers (the tasks popover).

Feature code never picks a platform. It builds a spec or a `lib/ui/`
widget, and the platform choice happens underneath.

## 2. Native menus (`lib/ui/menu/`)

### Spec (`app_menu.dart`)

```dart
sealed class AppMenuEntry {}
final class AppMenuAction extends AppMenuEntry {
  // label, onSelected, enabled, checked (null = not a check item),
  // shortcut (SingleActivator?, menu bar only)
}
final class AppMenuSeparator extends AppMenuEntry {}
class AppMenu { final List<AppMenuEntry> entries; }
```

Menus are one level deep; nothing the app shows needs submenus.
`AppMenuAction` is named to stay clear of the existing `AppMenuItem<T>`
(the value list of `AppMenuButton`). Shortcuts are only shown and
registered by the macOS menu bar, and the Playback/View ones are looked up
from `playerKeyBindings`, so a menu can't show a key that does something
else. A unit test asserts that.

### Port (`native_menus.dart`)

```dart
abstract interface class NativeMenus {
  /// Shows [menu] anchored below [anchor] (global logical coordinates),
  /// runs the chosen action's callback, and completes when it closes.
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor);
}
```

`lib/ui/` widgets find the renderer through a `NativeMenusScope`
inherited widget (`lib/ui/` doesn't use Riverpod); with no scope, as in
most widget tests, they get `DrawnMenus`. The app root provides the
scope from `nativeMenusProvider`, which picks `ChannelNativeMenus` on
macOS/Linux and `DrawnMenus` elsewhere.

- **`ChannelNativeMenus`** (`lib/services/`) serializes the spec to a
  list of maps. Each action gets an integer id local to one `show` call,
  and callbacks stay in a Dart-side `id → action` table. It sends `show`
  on `stash_player/menu` with the list plus the anchor rect, and receives
  the chosen id or null.
  - **macOS** (`NativeMenuChannel` in `MainFlutterWindow.swift`, which
    avoids an Xcode project edit) builds an `NSMenu` (`state = .on` for
    checked items) and calls `popUp(positioning:at:in:)` on the Flutter
    view, flipping the y axis. `popUp` returns once the menu closes.
  - **Linux** (`linux/runner/native_menu_channel.cc`) builds a `GtkMenu`
    of `GtkMenuItem`/`GtkCheckMenuItem`/`GtkSeparatorMenuItem` and calls
    `gtk_menu_popup_at_rect` against the `FlView`'s `GdkWindow`
    (`GDK_GRAVITY_SOUTH_WEST` → `GDK_GRAVITY_NORTH_WEST`). A `GtkMenu`
    opens as its own popup surface (an xdg_popup on Wayland), so it
    composes over the Flutter view. It answers from an idle callback
    after `deactivate`, since GTK emits that before the chosen item's
    `activate`.
- **`DrawnMenus`** renders the same spec with the theme-styled Material
  `showMenu`. Widget tests use it, and it is the runtime fallback.

### Call sites converted

- The sort and minimum-rating dropdowns (`AppMenuButton` in
  `lib/ui/widgets/filter_controls.dart`, currently `showMenu`). The
  current value is a checked item.
- The stream picker in `lib/features/player/player_top_bar.dart`
  (currently `PopupMenuButton<SceneStream>`).

The tasks popover (`tasks_popover.dart`) holds content, not commands, so
it stays drawn and only picks up the dialect styling.

### macOS menu bar

A `PlatformMenuBar` at the app root (`lib/app/app_menu_bar.dart`). It
replaces the bar `MainMenu.xib` loads, so it lists everything:

- **App menu**: About, Check for Updates…, Services, Hide/Hide
  Others/Show All, Quit. "Check for Updates…" reaches Sparkle over a
  small `stash_player/updates` channel.
- **Edit**: Cut, Copy, Paste, Select All, each invoking the matching
  text-editing intent on the focused widget.
- **Playback** (enabled only on the scene screen): Play/Pause, seek
  ±5s / ±10s / ±1 min, start/end, Volume Up/Down, Mute.
- **View**: Enter/Exit Full Screen.
- **Window**: Minimize, Zoom, Bring All to Front.

Playback and View are `AppMenu`s (`lib/features/player/playback_menu.dart`)
converted by an `AppMenu → PlatformMenu` adapter; they dispatch the same
`PlayerAction`s the keyboard shortcuts do, through the scene's
`PlaybackController`. `PlatformMenuItem` has no check state, so toggles
relabel ("Mute" / "Unmute") as macOS menus conventionally do. Flutter
sees a key before AppKit's menu does, so a key the player already handles
is never also fired by its menu item.

`MainMenu.xib` shrinks to its app menu (it only shows until the first
frame). The template Edit/View/Window/Help menus and the unwired
Preferences… item go.

## 3. Drawn dialects (`lib/ui/theme/`)

### Dialect selection

`PlatformDialect.of(context)` derives `adwaita` | `macos` from
`Theme.of(context).platform`, the same way `AppWindowChrome` already
reads the platform, so a widget test can pin either dialect. Windows and
every other platform get `adwaita`. `buildAppTheme(brightness,
{platform, accent, fontFamily, bodyFontPt})` builds the matching theme.

### Per-dialect tokens

| Token | Adwaita | macOS |
|---|---|---|
| Font | GNOME's `font-name` (portal), else Adwaita Sans, then Cantarell | `.AppleSystemUIFont` (SF Pro) |
| Body size | 11pt = 14.67px (or GNOME's size) | 13px |
| Control radius / panel radius | 6 / 12 | 5 / 10 |
| Button height / label weight | 34 / bold | 24 / regular |
| Accent use | Suggested-action buttons, focus rings, slider fill | Default push button, focus rings, slider fill |

The top strip keeps its 28px control band on both platforms: its
geometry is measured against the macOS traffic lights (see
`AppTokens.macOSStripHeight`), and the strip's compact controls read well
at that size in both dialects.

The palette splits into four `AppPalette` constants (Adwaita light/dark
from libadwaita 1.6's named colours; macOS light/dark from AppKit's
semantic colours). The values are compiled in and tested for WCAG 4.5:1
text contrast. Only the accent is read from the OS.

### Widgets and component themes

- **Buttons**: the existing `FilledButton` / `OutlinedButton` /
  `TextButton` call sites stay; their component themes speak the
  dialect (Adwaita suggested-action / wash / flat; macOS default push
  button / hairline bezel / accent link style).
- **`AppSpinner`**: Adwaita arc spinner; macOS twelve-spoke activity
  indicator. Replaces `CircularProgressIndicator`. The
  `LinearProgressIndicator` only takes the accent.
- **Text fields**: `InputDecorationTheme` per dialect (Adwaita 2px accent
  focus ring; macOS 3px half-opacity ring).
- **Tooltips**: `TooltipThemeData` per dialect (Adwaita dark rounded
  bubble; macOS light rectangle with a hairline border, 11pt).
- **Toasts**: `ToastHost` (`lib/app/`) replaces the `SnackBar` in
  `app.dart`, still driven by `globalNoticeProvider`, and draws an
  `AppToast`: on Adwaita a bottom-centred dark pill like `AdwToast`, on
  macOS a top-centred HUD panel. Severity colouring keeps today's
  mapping.
- The app has no switches, and the player's sliders sit over video with
  their own dialect-neutral styling (a white knob on a thin track, which
  is also what both platforms draw), so neither gets a new widget.

### Accent colour and font (`stash_player/appearance`)

An `EventChannel` streams `{accent: ARGB int?, fontName: String?}`:

- **macOS**: `NSColor.controlAccentColor` converted to sRGB, re-sent on
  `NSSystemColorsDidChangeNotification`. `fontName` is always null.
- **Linux**: portal `org.freedesktop.portal.Settings.ReadOne` for
  `org.freedesktop.appearance` `accent-color` (an `(ddd)` sRGB triple,
  GNOME 47+) and `org.gnome.desktop.interface` `font-name`, plus the
  `SettingChanged` signal. This works inside the Flatpak because the
  portal is always reachable.

`systemAppearanceProvider` (a `StreamProvider`) feeds `buildAppTheme`.
Until the first value arrives, or if the channel fails, the theme uses
`#3584E4` and the dialect's default font.

### Icons (`lib/ui/icons/app_icons.dart`)

`AppIcon` names each of the 36 glyphs the app uses by meaning
(`AppIcon.play`, `.seekBack10`, `.search`, `.filters`, `.settings`,
`.error`…) and resolves it per dialect; `AppIconView` draws it with
`flutter_svg`, tinted like an `Icon`.

- **Adwaita**: GNOME's icon-development-kit, the CC0 set libadwaita apps
  draw from. It covers every meaning, including 10-second seek arrows.
  Its GTK "GPA" SVGs carry several animation states per file, so
  `tool/fetch_icons.py` flattens each to one state when fetching.
- **macOS**: Lucide (ISC). Its 2px strokes sit closest to SF Symbols'
  regular weight. Lucide has no 10-second seek glyph, so those draw a
  small "10" inside its rotate arrows.

Both sets are pinned, bundled under `assets/icons/{gnome,lucide}/` with
their licence texts, and credited in `README.md`. No `Icons.*`
references remain in `lib/`; a grep test in `test/` enforces that, and
another parses every bundled SVG so an icon `flutter_svg` can't draw
fails a test instead of rendering blank.

## 4. Error handling

- A missing or failing `stash_player/menu` channel (`MissingPluginException`
  or a `PlatformException`): `ChannelNativeMenus` falls back to
  `DrawnMenus` for that call, and logs once per session through
  `lib/shared/diagnostics.dart`.
- Stale callbacks: the `id → action` table is scoped to one `show` call,
  so a late reply can't fire an item from a different menu, and an
  unknown id runs nothing.
- Appearance channel failure or a missing portal key: the fallback accent
  and font, with no user-visible notice.
- Opening a second native menu while one is open closes the first; GTK
  and AppKit both do this themselves, and the first `show` completes with
  no selection.

## 5. Testing

- **Unit**: channel serialization (ids, check state, anchor); unknown
  ids; fallback on missing plugin and on native error; the
  `AppMenu → PlatformMenu` adapter; every Playback/View shortcut is the
  key bound to the action it runs; appearance event and font-name
  decoding; palette contrast; per-dialect type scale and radii.
- **Widget**: each converted call site with a recording `NativeMenus`
  fake; `DrawnMenus` selection, dismissal and disabled items; icons,
  spinner and toast under both dialects by pinning `platform`; the toast
  host driven by `globalNoticeProvider`; the app theme following an
  overridden `systemAppearanceProvider`; the menu bar mounted only on
  macOS.
- **Manual gates** (the release spec's §6 pattern), on GNOME Wayland
  (Flatpak) and macOS: native menus open at the anchor and select
  correctly, including from the fullscreen player; the menu bar's
  Playback items act and relabel with state, and keys don't double-fire;
  changing the system accent recolours the app live; the fonts match the
  system.

Golden images were considered and left out: they would differ between
the Linux and macOS machines that run `just flutter-check`, and the
property assertions above pin the same decisions.

`just flutter-check` stays the CI gate. There are no new CI jobs.

## 6. Delivery order

Each step leaves the app shippable:

1. Dialects, palettes, type scale, radii and component themes.
2. Accent and font channel (`stash_player/appearance`, both runners).
3. `AppIcon` and both icon sets; remove `Icons.*`.
4. Spinner and toasts.
5. Menu spec, `DrawnMenus`, and conversion of the two call sites.
6. `ChannelNativeMenus` with the macOS and Linux implementations.
7. The macOS menu bar, updates channel and `MainMenu.xib` cleanup.
8. Docs and the manual gate checklist.
