# Linux immersive window

Date: 2026-10-02

## Problem

On Linux the Flutter client has a double titlebar. The runner
(`apps/flutter/linux/runner/my_application.cc`) installs a stock
`GtkHeaderBar` titled "Stash Player", and Flutter draws its own strip
beneath it: `AppWindowChrome` in the library, `PlayerTopBar` over the
video. The header bar carries nothing but the window buttons, and in the
player it stops the video from filling the window.

macOS already has the result we want. The library's controls are a real
`NSToolbar` filled from the `AppToolbar` spec, and in the player the
video runs under native traffic lights while Flutter draws the rest of
the top bar so it fades with the OSD.

The Flutter-drawn strip also imitates Adwaita, which looks wrong under
other GTK themes (Yaru, for one). The window chrome should be drawn by
GTK so it follows the user's theme.

## Goals

- One titlebar on Linux. In the library it is a real `GtkHeaderBar`
  holding native GTK controls. In the player the video fills the window.
- Window buttons are always GTK's own: their set, side, and look come
  from the desktop (`gtk-decoration-layout` and the GTK theme).
- Same split as macOS, reusing the `AppToolbar` spec and the
  `NativeToolbar` port.
- Every native piece degrades to today's behaviour when unavailable.

## Out of scope

- Real fullscreen. `setFullscreenPlatform` stays a stub.
- Rounded top corners in the player. With the titlebar hidden the window
  has square top corners; accepted.
- The drawn Adwaita dialect inside the Flutter view (dialogs, tiles,
  popovers, the player's own controls).
- Aspect-ratio locking and drag-from-anywhere on the video.
- macOS and Windows runners: untouched.

## Window modes

The runner already decides, at startup, between a header bar and a
WM-drawn title bar. That rule is unchanged:

| Session | Mode |
|---|---|
| Wayland, any compositor | header-bar mode |
| X11 under GNOME Shell | header-bar mode |
| X11 under any other WM | WM-title-bar mode |

**WM-title-bar mode** behaves exactly as today: the WM draws the title
bar, Flutter draws its strip, and both new channels report
`unavailable`.

**Header-bar mode** has two states, switched from Dart:

- **Library state.** The `GtkHeaderBar` is the window's titlebar and
  holds the toolbar controls. Flutter draws no strip.
- **Player state.** The header bar is hidden, so the Flutter view fills
  the window; GTK still treats the window as client-side decorated and
  keeps its shadows and resize edges. A second header bar with no
  background, in a `GtkOverlay` above the Flutter view, shows only the
  window buttons.

## Native side (runner)

### Window structure (`my_application.cc`)

- The `FlView` is added to a `GtkOverlay`, and the overlay to the
  window.
- In header-bar mode the titlebar `GtkHeaderBar` is created as today,
  with `show-close-button` set. The window title is set in both modes
  for the task switcher and overview.
- The overlay holds the window-buttons bar: a `GtkHeaderBar` with
  `show-close-button`, no title, a transparent background (application
  CSS) and the `osd` style class, top-aligned. It is hidden in the
  library state and fades with its own opacity animation (200 ms,
  matching the OSD). It is not wrapped in a `GtkRevealer`, whose own
  input windows would block the pass-through below.
- The overlay bar passes pointer input through to the Flutter view
  everywhere except on its buttons.

### `native_toolbar_channel.cc` / `.h`

The Linux implementation of `stash_player/toolbar`, with the same
protocol as `NativeToolbarChannel.swift`: methods `setItems` and
`reset`; events `activated`, `menuSelected`, `searchChanged`.

| Spec item | GTK widget |
|---|---|
| `menu` | `GtkMenuButton` labelled with the selected option, popping a `GtkMenu` of radio items |
| `toggle` | `GtkToggleButton` with a symbolic icon |
| `action` | `GtkButton` with a symbolic icon; insensitive when `enabled` is false; `badge` drawn as a dot |
| `search` | `GtkSearchEntry` set as the header bar's custom title, so it sits in the centre and takes the spare width |
| `group` | `GtkBox` with the `linked` style class holding its children |
| `space` | No widget: items before the first space are packed at the start, items after it at the end |

- Items are reconciled by id. An item whose id and type are unchanged
  is updated in place, so a republish does not rebuild widgets, move
  focus, or disturb the search entry. As on macOS, `text` is applied to
  the search entry only while it does not have focus.
- Each item's `tooltip` becomes the widget tooltip and its `label` the
  accessible name.
- Icons: toggles and actions carry an `icon` field, the `AppIcon.gnome`
  file name. The runner loads
  `flutter_assets/assets/icons/gnome/<icon>.svg` from the bundle and
  paints its alpha in the widget's foreground colour, so it follows the
  theme and the insensitive state. (The files are not named
  `*-symbolic.svg`, so GTK would not recolour them itself.) These are
  the same files Flutter draws.
- `activated` for an action carries `rect`: the button's frame in the
  Flutter view's logical coordinates. The header bar is above the view,
  so `y` is clamped to 0 and the height to 0; a popover anchored to it
  hangs from the view's top edge under the button. Toggles send no rect.
- `reset` removes every item.
- In WM-title-bar mode `setItems` answers with an `unavailable` error.

### `window_channel.cc` / `.h`

A new `stash_player/window` channel.

| Direction | Message | Meaning |
|---|---|---|
| Dart → native | `setImmersive(bool)` | `true`: player state. `false`: library state. |
| Dart → native | `setControlsVisible(bool)` | Reveal or conceal the overlaid window buttons. Only has an effect in the player state. |
| Dart → native | `startDrag` | `gtk_window_begin_move_drag` at the current pointer position. |
| Dart → native | `reset` | Back to the library state with controls visible. |
| native → Dart | `insetsChanged({leading, trailing})` | Logical-pixel widths the window buttons occupy at each side of the overlay bar. Sent on entering the player state and whenever the allocation or `gtk-decoration-layout` changes. Both are 0 in the library state. |
| native → Dart | `controlsHovered(bool)` | The pointer entered or left the window buttons. |

In WM-title-bar mode every method answers with an `unavailable` error.

Both channels are constructed in `my_application_activate` and freed in
`my_application_dispose`, like `appearance_channel` and `native_menus`.

## Dart side

### Toolbar

- `nativeToolbarProvider` (`lib/app/providers.dart`) returns a
  `ChannelNativeToolbar` on Linux as well as macOS.
- `ChannelNativeToolbar._encode` adds `'icon': item.icon.gnome` beside
  `symbol` for toggles and actions.
- `LibraryToolbar`: when the native toolbar is in use, macOS keeps the
  empty `AppWindowChrome` band (its toolbar floats over the Flutter
  view); Linux renders nothing (its header bar is outside the view).
  The existing `_nativeFailed` fallback draws the strip when `set`
  returns false, which covers WM-title-bar mode.
- The native spec gains a trailing `main-menu` action on the Adwaita
  dialect (GNOME's primary menu, holding Preferences), which the drawn
  strip already has and the macOS spec omits. It opens through
  `NativeMenus` at the button's anchor.
- Screens that publish no toolbar (the connection screen, the settings
  dialog) show the bare header bar with the window title.

### Window frame port

- `lib/ui/window/window_frame.dart`:

  ```dart
  abstract interface class WindowFrame {
    Future<void> setImmersive(bool immersive);
    Future<void> setControlsVisible(bool visible);
    Future<void> startDrag();
    ValueListenable<WindowButtonInsets> get insets;
    ValueListenable<bool> get controlsHovered;
  }
  ```

  `WindowButtonInsets` is an immutable pair of `leading` and `trailing`
  doubles with a `zero` constant. `WindowFrameScope` is an
  `InheritedWidget` with `maybeOf`, shaped like `NativeToolbarScope`.
  `lib/ui/` imports no Riverpod.
- `lib/services/channel_window_frame.dart`: `ChannelWindowFrame`, the
  `stash_player/window` implementation, with a `reset()` like
  `ChannelNativeToolbar`'s. On `MissingPluginException` or
  `PlatformException` it marks itself unavailable, logs once through
  `logDiagnostic`, and from then on every call is a no-op; insets stay
  zero and hover stays false.
- `windowFrameProvider` in `providers.dart`: a `ChannelWindowFrame` on
  Linux (calling `reset()` on creation), null elsewhere. `app.dart`
  wraps the content in `WindowFrameScope` when it is non-null.

### Player screen

- `SceneScreen` calls `setImmersive(true)` when it mounts and
  `setImmersive(false)` when it disposes.
- `PlayerTopBar` takes the insets and adds `leading` to its left
  padding and `trailing` to its right padding. Its empty area (the
  title and the gaps, not the buttons) starts a window drag on pan
  start through an `onStartDrag` callback. `PlayerTopBar` stays purely
  presentational; `SceneScreen` reads the scope and passes both in.
- `SceneScreen` calls `setControlsVisible` whenever the controls'
  effective visibility changes, so the GTK buttons show and hide with
  the OSD. It listens to `controlsHovered` and feeds it into the same
  path as the top bar's `MouseRegion` (`_setHovering`), so the OSD does
  not hide while the pointer is on a window button.
- `SceneMetadataDrawer` gets a top inset of the strip height when
  either window-button inset is non-zero, so the buttons never cover
  its content.

## Failure behaviour

| Failure | Result |
|---|---|
| Toolbar channel missing or `unavailable` | The library draws its own strip, as today. Logged once. |
| Window channel missing or `unavailable` | The player looks as today: no overlaid buttons, zero insets. Logged once. |
| Hot restart | `reset` on both channels clears the toolbar and returns the window to the library state. |

## Testing

- `test/services/channel_native_toolbar_test.dart`: the `icon` field in
  the payload for toggles and actions.
- `test/services/channel_window_frame_test.dart`: each method call,
  inset and hover events updating the listenables, and the unavailable
  path turning calls into no-ops.
- `test/features/library/library_toolbar_test.dart`: with a native
  scope on Linux the toolbar renders no band; on macOS it still renders
  the empty band; a failed `set` falls back to the drawn strip on both.
- `test/features/player/` with a fake `WindowFrame`: insets pad
  `PlayerTopBar`; immersive is set on mount and cleared on dispose;
  `setControlsVisible` follows the controls' visibility; hover holds
  the hide timer; a pan on the bar's empty area starts a drag and a
  pan on a button does not; the drawer is inset when insets are
  non-zero.
- The GTK code has no automated tests, like the other runner channels.
  Manual checklist, each in light and dark:
  - Wayland GNOME with the Yaru theme and with Adwaita.
  - Button layouts: close only on the right, all three on the right,
    buttons on the left, empty layout.
  - X11 under GNOME Shell.
  - X11 under another WM (drawn strip, WM title bar, as today).
  - The Flatpak build (`nix run .#flatpak`).
  - In each: library controls work and reflect state; search keeps
    focus while typing; the Tasks popover and main menu anchor under
    their buttons; opening a scene hides the header bar and the video
    fills the window; window buttons fade with the OSD and stay while
    hovered; dragging the top bar moves the window; going back restores
    the header bar.

## Implementation order

1. The window slice: `WindowFrame` port and channel implementation,
   runner window structure and `window_channel`, player screen changes.
2. **Manual gate** on Wayland and X11, standing in for a spike, before
   the larger toolbar work. The design depends on all three:
   1. Hiding the titlebar on a live window keeps shadows and resize
      edges, and showing it again restores the header bar.
   2. The overlaid header bar lets clicks through to Flutter everywhere
      except on its buttons.
   3. `startDrag` from a Flutter pointer-down moves the window.

   If (1) fails, fall back to swapping the titlebar widget for an empty
   one. If (2) fails, fall back to two end-aligned bars, each only as
   wide as its buttons. If (3) fails, drop dragging from the top bar.
   The channel protocol and the Dart side are the same under every
   fallback.
3. Toolbar: `icon` field, provider and `LibraryToolbar` changes, then
   `native_toolbar_channel` in the runner.
4. Manual checklist; update `CLAUDE.md` and `apps/flutter/README.md`
   for the new channels and files.

## Spike outcome

The manual gate and the manual checklist were not run before merge, at
the owner's direction, because the implementation session had no display.
The runner code was compiled under `-Wall -Werror` and reviewed, but it
has never been executed. Nothing here was verified on screen.

What therefore remains unverified at runtime:

- (a) Hiding the titlebar keeps the window's shadows and resize edges.
- (b) The overlaid header bar passes clicks through to Flutter except on
  its buttons.
- (c) `startDrag` moves the window, and Flutter recovers its pointer state
  afterwards.
- (d) Window-button legibility over video, in light and dark themes.
- (e) The native toolbar's widgets, icons, menus, search entry and the
  keyboard-focus hand-back to the Flutter view.
- (f) Non-default button layouts, the Yaru theme, X11 sessions, and the
  Flatpak build.

If any of these fail, the fallbacks listed under "Implementation order"
remain available.
