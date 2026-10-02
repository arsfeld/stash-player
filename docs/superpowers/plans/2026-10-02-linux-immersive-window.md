# Linux Immersive Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One GTK-drawn titlebar on Linux: a real `GtkHeaderBar` with native toolbar controls in the library, and a video that fills the window with native window buttons overlaid in the player.

**Architecture:** The Linux runner puts the `FlView` in a `GtkOverlay`. A new `stash_player/window` channel hides the titlebar and shows an overlaid, background-less header bar (window buttons only) while a scene is open. A Linux implementation of the existing `stash_player/toolbar` channel fills the titlebar `GtkHeaderBar` from the `AppToolbar` spec the library already publishes on macOS. Dart gains one port (`WindowFrame`) and reuses `NativeToolbar`.

**Tech Stack:** Flutter (Dart, Riverpod), GTK 3 (C++ runner, `flutter_linux`), CMake.

**Spec:** `docs/superpowers/specs/2026-10-02-linux-immersive-window-design.md`

## Global Constraints

- Header-bar mode applies on Wayland and on X11 under GNOME Shell. X11 under any other WM keeps the WM title bar and the Flutter-drawn strip, exactly as today; both channels answer `unavailable` there.
- Every native piece degrades to today's behaviour when its channel is missing or errors. Log once with `logDiagnostic`.
- `lib/ui/` never imports Riverpod.
- macOS and Windows runners are not touched. macOS behaviour must not change.
- No fullscreen work, no rounded-corner work, no changes to the drawn Adwaita dialect inside the Flutter view.
- Channel names: `stash_player/window` (new), `stash_player/toolbar` (existing protocol: `setItems`, `reset`; events `activated`, `menuSelected`, `searchChanged`).
- All Flutter commands run from the repo root through the Nix shell:
  `nix develop .#flutter --command bash -c "cd apps/flutter && <command>"`.
  Below, `FL <command>` is shorthand for that.
- Before every commit: `FL dart format .` then `FL flutter analyze --fatal-infos --fatal-warnings`.
- `/docs` is git-ignored; docs under it are committed with `git add -f`.
- Commit messages follow the repo style (`feat(flutter): …`, `docs: …`), with no attribution lines.

## File Structure

| File | Responsibility |
|---|---|
| `apps/flutter/lib/ui/window/window_frame.dart` (new) | `WindowFrame` port, `WindowButtonInsets`, `WindowFrameScope` |
| `apps/flutter/lib/services/channel_window_frame.dart` (new) | `stash_player/window` implementation of the port |
| `apps/flutter/test/support/recording_window_frame.dart` (new) | Test fake |
| `apps/flutter/linux/runner/window_channel.{h,cc}` (new) | Immersive switch, overlaid window buttons, drag |
| `apps/flutter/linux/runner/native_toolbar_channel.{h,cc}` (new) | `AppToolbar` spec → GTK widgets in the header bar |
| `apps/flutter/linux/runner/my_application.cc` | `GtkOverlay`, channel construction |
| `apps/flutter/lib/features/player/player_top_bar.dart` | Insets and drag area |
| `apps/flutter/lib/features/player/scene_screen.dart` | Drives the window frame |
| `apps/flutter/lib/features/library/library_toolbar.dart` | No band on Linux, main menu in the native spec |
| `apps/flutter/lib/services/channel_native_toolbar.dart` | `icon` field |
| `apps/flutter/lib/app/providers.dart`, `app.dart` | Provider and scope wiring |

Task order: the window slice (Tasks 1–4) comes first and ends in a manual gate that proves the three risky GTK behaviours before the larger toolbar work (Tasks 5–6) starts.

---

### Task 1: `WindowFrame` port and channel implementation

**Files:**
- Create: `apps/flutter/lib/ui/window/window_frame.dart`
- Create: `apps/flutter/lib/services/channel_window_frame.dart`
- Create: `apps/flutter/test/support/recording_window_frame.dart`
- Test: `apps/flutter/test/services/channel_window_frame_test.dart`

**Interfaces:**
- Produces: `WindowButtonInsets({double leading, double trailing})` with `WindowButtonInsets.zero` and `isZero`; `WindowFrame` with `setImmersive(bool)`, `setControlsVisible(bool)`, `startDrag()`, `ValueListenable<WindowButtonInsets> insets`, `ValueListenable<bool> controlsHovered`; `WindowFrameScope.maybeOf(context)`; `ChannelWindowFrame` with `reset()`; `RecordingWindowFrame` with `calls`, and `insets` / `controlsHovered` as `ValueNotifier`s.

- [ ] **Step 1: Write the port**

`apps/flutter/lib/ui/window/window_frame.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The width the platform's own window buttons take at each end of the
/// view's top edge while they are drawn over it, in logical pixels.
@immutable
class WindowButtonInsets {
  const WindowButtonInsets({this.leading = 0, this.trailing = 0});

  static const zero = WindowButtonInsets();

  final double leading;
  final double trailing;

  bool get isZero => leading == 0 && trailing == 0;

  @override
  bool operator ==(Object other) =>
      other is WindowButtonInsets &&
      other.leading == leading &&
      other.trailing == trailing;

  @override
  int get hashCode => Object.hash(leading, trailing);

  @override
  String toString() => 'WindowButtonInsets($leading, $trailing)';
}

/// The window's own chrome, where the platform lets the app hide its
/// titlebar and draw the window buttons over the content (Linux; see
/// `window_channel.cc`).
abstract interface class WindowFrame {
  /// True hides the titlebar so the view fills the window, with the
  /// window buttons drawn over its top edge. False restores it.
  Future<void> setImmersive(bool immersive);

  /// Shows or hides the overlaid window buttons. Only has an effect
  /// while immersive.
  Future<void> setControlsVisible(bool visible);

  /// Starts moving the window with the pointer. Call while a mouse
  /// button is held.
  Future<void> startDrag();

  /// Zero unless immersive.
  ValueListenable<WindowButtonInsets> get insets;

  /// Whether the pointer is over an overlaid window button.
  ValueListenable<bool> get controlsHovered;
}

/// Provides the app's [WindowFrame] to `lib/ui/` and feature widgets
/// without Riverpod. With no scope (macOS, and most widget tests)
/// [maybeOf] is null.
class WindowFrameScope extends InheritedWidget {
  const WindowFrameScope({required this.frame, required super.child, super.key});

  final WindowFrame frame;

  /// Registers no dependency: the scope is fixed for the app's lifetime.
  static WindowFrame? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WindowFrameScope>()?.frame;

  @override
  bool updateShouldNotify(WindowFrameScope oldWidget) =>
      frame != oldWidget.frame;
}
```

- [ ] **Step 2: Write the test fake**

`apps/flutter/test/support/recording_window_frame.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:stash_player_flutter/ui/window/window_frame.dart';

/// A [WindowFrame] that records every call as `'<method> <argument>'`
/// and lets a test move [insets] and [controlsHovered] by hand.
class RecordingWindowFrame implements WindowFrame {
  final List<String> calls = [];

  @override
  final ValueNotifier<WindowButtonInsets> insets = ValueNotifier(
    WindowButtonInsets.zero,
  );

  @override
  final ValueNotifier<bool> controlsHovered = ValueNotifier(false);

  @override
  Future<void> setImmersive(bool immersive) async =>
      calls.add('setImmersive $immersive');

  @override
  Future<void> setControlsVisible(bool visible) async =>
      calls.add('setControlsVisible $visible');

  @override
  Future<void> startDrag() async => calls.add('startDrag');
}
```

- [ ] **Step 3: Write the failing channel test**

`apps/flutter/test/services/channel_window_frame_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/channel_window_frame.dart';
import 'package:stash_player_flutter/ui/window/window_frame.dart';

const _channel = MethodChannel('stash_player/window');

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

  Future<void> deliver(String method, Object? args) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('sends each call with its argument', () async {
    final frame = ChannelWindowFrame();
    await frame.reset();
    await frame.setImmersive(true);
    await frame.setControlsVisible(false);
    await frame.startDrag();

    expect(sent.map((call) => '${call.method} ${call.arguments}'), [
      'reset null',
      'setImmersive true',
      'setControlsVisible false',
      'startDrag null',
    ]);
  });

  test('native events move the listenables', () async {
    final frame = ChannelWindowFrame();

    await deliver('insetsChanged', {'leading': 0, 'trailing': 96.5});
    await deliver('controlsHovered', true);

    expect(frame.insets.value, const WindowButtonInsets(trailing: 96.5));
    expect(frame.controlsHovered.value, isTrue);
  });

  test('a missing plugin turns every call into a no-op', () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final frame = ChannelWindowFrame();

    await frame.setImmersive(true);
    await frame.setControlsVisible(false);
    await frame.startDrag();

    expect(frame.insets.value, WindowButtonInsets.zero);
    expect(frame.controlsHovered.value, isFalse);
  });

  test('a platform error stops further sends and clears state', () async {
    final frame = ChannelWindowFrame();
    await deliver('insetsChanged', {'leading': 0.0, 'trailing': 96.0});
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      throw PlatformException(code: 'unavailable');
    });

    await frame.setImmersive(true);
    await frame.setImmersive(false);

    expect(sent, hasLength(1));
    expect(frame.insets.value, WindowButtonInsets.zero);
  });
}
```

- [ ] **Step 4: Run it to see it fail**

Run: `FL flutter test test/services/channel_window_frame_test.dart`
Expected: FAIL, `channel_window_frame.dart` does not exist.

- [ ] **Step 5: Write the implementation**

`apps/flutter/lib/services/channel_window_frame.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../shared/diagnostics.dart';
import '../ui/window/window_frame.dart';

/// Drives the Linux runner's window chrome over `stash_player/window`
/// (`window_channel.cc`).
///
/// If the native side is missing or answers with an error (it answers
/// `unavailable` when the window manager draws the title bar), every
/// later call is a no-op, [insets] stays zero, and it logs once.
class ChannelWindowFrame implements WindowFrame {
  ChannelWindowFrame({
    MethodChannel channel = const MethodChannel('stash_player/window'),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final _insets = ValueNotifier(WindowButtonInsets.zero);
  final _controlsHovered = ValueNotifier(false);
  bool _unavailable = false;

  @override
  ValueListenable<WindowButtonInsets> get insets => _insets;

  @override
  ValueListenable<bool> get controlsHovered => _controlsHovered;

  /// Asks the runner to drop whatever a previous isolate left behind (a
  /// hot restart while a scene was open).
  Future<void> reset() => _invoke('reset');

  @override
  Future<void> setImmersive(bool immersive) =>
      _invoke('setImmersive', immersive);

  @override
  Future<void> setControlsVisible(bool visible) =>
      _invoke('setControlsVisible', visible);

  @override
  Future<void> startDrag() => _invoke('startDrag');

  Future<void> _invoke(String method, [Object? argument]) async {
    if (_unavailable) return;
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on MissingPluginException catch (error) {
      _disable(error);
    } on PlatformException catch (error) {
      _disable(error);
    }
  }

  void _disable(Object error) {
    if (_unavailable) return;
    _unavailable = true;
    _insets.value = WindowButtonInsets.zero;
    _controlsHovered.value = false;
    logDiagnostic('window', 'native window frame unavailable: $error');
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_unavailable) return null;
    final args = call.arguments;
    switch (call.method) {
      case 'insetsChanged' when args is Map:
        _insets.value = WindowButtonInsets(
          leading: (args['leading'] as num?)?.toDouble() ?? 0,
          trailing: (args['trailing'] as num?)?.toDouble() ?? 0,
        );
      case 'controlsHovered' when args is bool:
        _controlsHovered.value = args;
    }
    return null;
  }
}
```

- [ ] **Step 6: Run the test to see it pass**

Run: `FL flutter test test/services/channel_window_frame_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 7: Format, analyze, commit**

```bash
git add apps/flutter/lib/ui/window apps/flutter/lib/services/channel_window_frame.dart apps/flutter/test/support/recording_window_frame.dart apps/flutter/test/services/channel_window_frame_test.dart
git commit -m "feat(flutter): WindowFrame port and its channel implementation"
```

---

### Task 2: Runner window structure and `window_channel`

**Files:**
- Create: `apps/flutter/linux/runner/window_channel.h`
- Create: `apps/flutter/linux/runner/window_channel.cc`
- Modify: `apps/flutter/linux/runner/my_application.cc`
- Modify: `apps/flutter/linux/runner/CMakeLists.txt`

**Interfaces:**
- Consumes: the `stash_player/window` protocol from Task 1 (`reset`, `setImmersive(bool)`, `setControlsVisible(bool)`, `startDrag`; events `insetsChanged({leading, trailing})`, `controlsHovered(bool)`).
- Produces: `window_channel_new(FlView*, GtkWindow*, GtkWidget* titlebar, GtkOverlay*)` and `window_channel_free`. In `my_application.cc`, a local `GtkHeaderBar* header_bar` that is null in WM-title-bar mode, and a `GtkOverlay` holding the view; Task 6 uses `header_bar`.

There is no automated test for runner code (none of the runner channels have one). The deliverable is a debug build that compiles and still behaves as before, since nothing calls the channel until Task 4.

- [ ] **Step 1: Write the header**

`apps/flutter/linux/runner/window_channel.h`:

```cpp
#ifndef RUNNER_WINDOW_CHANNEL_H_
#define RUNNER_WINDOW_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Switches the window between its two looks on `stash_player/window`:
//
// - not immersive: [titlebar] (the GtkHeaderBar) is shown;
// - immersive: [titlebar] is hidden, so the Flutter view fills the
//   window, and a second, background-less header bar in [overlay] draws
//   only the window buttons over the view's top edge.
//
// Methods: `setImmersive(bool)`, `setControlsVisible(bool)` (fades the
// overlaid buttons), `startDrag`, `reset`. Events: `insetsChanged`
// ({leading, trailing}: the widths the buttons take at each end) and
// `controlsHovered(bool)`.
//
// With a null [titlebar] (the window manager draws the title bar) every
// method answers the `unavailable` error.
typedef struct _WindowChannel WindowChannel;

WindowChannel* window_channel_new(FlView* view, GtkWindow* window,
                                  GtkWidget* titlebar, GtkOverlay* overlay);
void window_channel_free(WindowChannel* self);

#endif  // RUNNER_WINDOW_CHANNEL_H_
```

- [ ] **Step 2: Write the implementation**

`apps/flutter/linux/runner/window_channel.cc`:

```cpp
#include "window_channel.h"

struct _WindowChannel {
  FlMethodChannel* channel;
  GtkWindow* window;
  // Null when the window manager draws the title bar.
  GtkWidget* titlebar;
  // The overlaid header bar that carries only the window buttons.
  GtkWidget* controls;
  gboolean immersive;
  gboolean controls_visible;
  gint leading;
  gint trailing;
  gint hovered_buttons;
  // Fade: opacity runs from fade_from to the target over kFadeMicros.
  guint fade_tick;
  gint64 fade_start;
  gdouble fade_from;
};

static const gint64 kFadeMicros = 200 * 1000;
// Space kept between the window buttons and Flutter's own controls.
static const gint kInsetGap = 6;
static const gchar* kHoverConnectedKey = "stash-player-hover-connected";

// The overlaid bar keeps the theme's window buttons but none of the
// header bar's own surface, and reads as on-video chrome (`osd`).
static const gchar* kControlsCss =
    "headerbar.stash-window-controls {"
    "  background: none;"
    "  border: none;"
    "  box-shadow: none;"
    "  min-height: 44px;"
    "}";

static void send_insets(WindowChannel* self) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "leading", fl_value_new_float(self->leading));
  fl_value_set_string_take(args, "trailing",
                           fl_value_new_float(self->trailing));
  fl_method_channel_invoke_method(self->channel, "insetsChanged", args,
                                  nullptr, nullptr, nullptr);
}

static void set_insets(WindowChannel* self, gint leading, gint trailing) {
  if (self->leading == leading && self->trailing == trailing) return;
  self->leading = leading;
  self->trailing = trailing;
  send_insets(self);
}

static void send_hovered(WindowChannel* self) {
  g_autoptr(FlValue) value = fl_value_new_bool(self->hovered_buttons > 0);
  fl_method_channel_invoke_method(self->channel, "controlsHovered", value,
                                  nullptr, nullptr, nullptr);
}

static gboolean button_enter_cb(GtkWidget* widget, GdkEventCrossing* event,
                                gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  if (self->hovered_buttons++ == 0) send_hovered(self);
  return GDK_EVENT_PROPAGATE;
}

static gboolean button_leave_cb(GtkWidget* widget, GdkEventCrossing* event,
                                gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  if (self->hovered_buttons > 0 && --self->hovered_buttons == 0) {
    send_hovered(self);
  }
  return GDK_EVENT_PROPAGATE;
}

static void connect_hover_cb(GtkWidget* button, gpointer user_data) {
  if (g_object_get_data(G_OBJECT(button), kHoverConnectedKey) != nullptr) {
    return;
  }
  g_object_set_data(G_OBJECT(button), kHoverConnectedKey,
                    GINT_TO_POINTER(TRUE));
  g_signal_connect(button, "enter-notify-event", G_CALLBACK(button_enter_cb),
                   user_data);
  g_signal_connect(button, "leave-notify-event", G_CALLBACK(button_leave_cb),
                   user_data);
}

typedef struct {
  WindowChannel* self;
  gint bar_width;
  gint leading;
  gint trailing;
} InsetScan;

// One internal child of the overlaid bar: a box of window buttons at one
// end. GTK rebuilds these boxes whenever gtk-decoration-layout changes,
// so hover handlers are (re)connected here too.
static void scan_button_box_cb(GtkWidget* child, gpointer user_data) {
  InsetScan* scan = static_cast<InsetScan*>(user_data);
  if (!GTK_IS_BOX(child) || !gtk_widget_get_visible(child)) return;
  if (child == gtk_header_bar_get_custom_title(
                   GTK_HEADER_BAR(scan->self->controls))) {
    return;
  }
  GtkAllocation box;
  gtk_widget_get_allocation(child, &box);
  if (box.width <= 1) return;
  gtk_container_foreach(GTK_CONTAINER(child), connect_hover_cb, scan->self);
  GtkAllocation bar;
  gtk_widget_get_allocation(scan->self->controls, &bar);
  gint start = box.x - bar.x;
  if (start + box.width / 2 < scan->bar_width / 2) {
    scan->leading = MAX(scan->leading, start + box.width + kInsetGap);
  } else {
    scan->trailing =
        MAX(scan->trailing, scan->bar_width - start + kInsetGap);
  }
}

static void controls_allocated_cb(GtkWidget* controls,
                                  GdkRectangle* allocation,
                                  gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  if (!self->immersive) return;
  InsetScan scan = {self, allocation->width, 0, 0};
  gtk_container_forall(GTK_CONTAINER(controls), scan_button_box_cb, &scan);
  set_insets(self, scan.leading, scan.trailing);
}

static void stop_fade(WindowChannel* self) {
  if (self->fade_tick == 0) return;
  gtk_widget_remove_tick_callback(self->controls, self->fade_tick);
  self->fade_tick = 0;
}

static gboolean fade_tick_cb(GtkWidget* controls, GdkFrameClock* clock,
                             gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  gdouble target = self->controls_visible ? 1 : 0;
  gdouble t = static_cast<gdouble>(gdk_frame_clock_get_frame_time(clock) -
                                   self->fade_start) /
              kFadeMicros;
  if (t < 1) {
    gtk_widget_set_opacity(controls,
                           self->fade_from + (target - self->fade_from) * t);
    return G_SOURCE_CONTINUE;
  }
  gtk_widget_set_opacity(controls, target);
  // Hidden rather than merely transparent, so an invisible close button
  // can't take a click.
  if (!self->controls_visible) gtk_widget_hide(controls);
  self->fade_tick = 0;
  return G_SOURCE_REMOVE;
}

static void fade_controls(WindowChannel* self, gboolean visible) {
  if (self->controls_visible == visible) return;
  self->controls_visible = visible;
  if (!self->immersive) return;
  stop_fade(self);
  if (visible) gtk_widget_show(self->controls);
  self->fade_from = gtk_widget_get_opacity(self->controls);
  GdkFrameClock* clock = gtk_widget_get_frame_clock(self->controls);
  if (clock == nullptr) {
    gtk_widget_set_opacity(self->controls, visible ? 1 : 0);
    if (!visible) gtk_widget_hide(self->controls);
    return;
  }
  self->fade_start = gdk_frame_clock_get_frame_time(clock);
  self->fade_tick = gtk_widget_add_tick_callback(self->controls, fade_tick_cb,
                                                 self, nullptr);
}

static void set_immersive(WindowChannel* self, gboolean immersive) {
  if (self->immersive == immersive) return;
  self->immersive = immersive;
  stop_fade(self);
  self->controls_visible = TRUE;
  gtk_widget_set_opacity(self->controls, 1);
  if (immersive) {
    // A hidden titlebar takes no height, and GTK keeps the window
    // client-side decorated: shadows and resize edges stay.
    gtk_widget_hide(self->titlebar);
    gtk_widget_show(self->controls);
  } else {
    gtk_widget_hide(self->controls);
    gtk_widget_show(self->titlebar);
    set_insets(self, 0, 0);
    if (self->hovered_buttons != 0) {
      self->hovered_buttons = 0;
      send_hovered(self);
    }
  }
}

static void start_drag(WindowChannel* self) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(self->window));
  GdkSeat* seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) return;
  gint x = 0, y = 0;
  gdk_device_get_position(gdk_seat_get_pointer(seat), nullptr, &x, &y);
  // Called from a platform-channel handler, so there is no current GDK
  // event to take a timestamp from. On Wayland GDK uses the seat's last
  // implicit-grab serial, which is the press Flutter is reacting to.
  gtk_window_begin_move_drag(self->window, 1, x, y, GDK_CURRENT_TIME);
}

static void method_cb(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  const gchar* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  gboolean flag = args != nullptr &&
                  fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                  fl_value_get_bool(args);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (self->titlebar == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "the window manager draws the title bar", nullptr));
  } else if (g_strcmp0(name, "setImmersive") == 0) {
    set_immersive(self, flag);
  } else if (g_strcmp0(name, "setControlsVisible") == 0) {
    fade_controls(self, flag);
  } else if (g_strcmp0(name, "startDrag") == 0) {
    start_drag(self);
  } else if (g_strcmp0(name, "reset") == 0) {
    set_immersive(self, FALSE);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  if (response == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

static GtkWidget* build_controls(WindowChannel* self, GtkOverlay* overlay) {
  GtkWidget* controls = gtk_header_bar_new();
  gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(controls), TRUE);
  // An empty custom title, so the bar shows no title text.
  GtkWidget* no_title = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_show(no_title);
  gtk_header_bar_set_custom_title(GTK_HEADER_BAR(controls), no_title);
  gtk_widget_set_valign(controls, GTK_ALIGN_START);
  gtk_widget_set_halign(controls, GTK_ALIGN_FILL);
  gtk_widget_set_no_show_all(controls, TRUE);

  GtkStyleContext* context = gtk_widget_get_style_context(controls);
  gtk_style_context_add_class(context, "osd");
  gtk_style_context_add_class(context, "stash-window-controls");
  g_autoptr(GtkCssProvider) css = gtk_css_provider_new();
  gtk_css_provider_load_from_data(css, kControlsCss, -1, nullptr);
  gtk_style_context_add_provider(context, GTK_STYLE_PROVIDER(css),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  gtk_overlay_add_overlay(overlay, controls);
  // Clicks anywhere on the bar except its buttons (which have their own
  // input windows) go to the Flutter view underneath.
  gtk_overlay_set_overlay_pass_through(overlay, controls, TRUE);
  g_signal_connect(controls, "size-allocate",
                   G_CALLBACK(controls_allocated_cb), self);
  return controls;
}

WindowChannel* window_channel_new(FlView* view, GtkWindow* window,
                                  GtkWidget* titlebar, GtkOverlay* overlay) {
  WindowChannel* self = g_new0(WindowChannel, 1);
  self->window = window;
  self->titlebar = titlebar;
  self->controls_visible = TRUE;
  if (titlebar != nullptr) self->controls = build_controls(self, overlay);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "stash_player/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_cb, self,
                                            nullptr);
  return self;
}

void window_channel_free(WindowChannel* self) {
  if (self->controls != nullptr) {
    stop_fade(self);
    g_signal_handlers_disconnect_by_data(self->controls, self);
  }
  g_clear_object(&self->channel);
  g_free(self);
}
```

- [ ] **Step 3: Wire it into `my_application.cc`**

Add the include next to the others:

```cpp
#include "window_channel.h"
```

Add a field to `struct _MyApplication`:

```cpp
  WindowChannel* window_channel;
```

In `my_application_activate`, replace the `if (use_header_bar) { … } else { … }` block with one that keeps the header bar in a variable and always sets the window title (the header bar shows the window's title when it has none of its own):

```cpp
  // Null when the window manager draws the title bar.
  GtkHeaderBar* header_bar = nullptr;
  gtk_window_set_title(window, "Stash Player");
  if (use_header_bar) {
    header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Stash Player");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }
```

Replace the two lines that show the view and add it to the window:

```cpp
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
```

with:

```cpp
  // An overlay, so the window buttons can be drawn over the view while a
  // scene is open (see window_channel.h).
  GtkWidget* overlay = gtk_overlay_new();
  gtk_widget_show(overlay);
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), overlay);
  gtk_widget_show(GTK_WIDGET(view));
```

After `self->native_menus = native_menu_channel_new(view);` add:

```cpp
  self->window_channel = window_channel_new(
      view, window, header_bar != nullptr ? GTK_WIDGET(header_bar) : nullptr,
      GTK_OVERLAY(overlay));
```

In `my_application_dispose`, next to the other channel frees:

```cpp
  g_clear_pointer(&self->window_channel, window_channel_free);
```

`first_frame_cb` calls `gtk_widget_get_toplevel(view)`, which still resolves to the window through the overlay; leave it.

- [ ] **Step 4: Add the source to CMake**

In `apps/flutter/linux/runner/CMakeLists.txt`, add `"window_channel.cc"` to the `add_executable` list after `"native_menu_channel.cc"`.

- [ ] **Step 5: Build**

Run: `just flutter-build`
Expected: the debug bundle builds with no warnings from `window_channel.cc` (the runner compiles with `-Wall -Werror`).

- [ ] **Step 6: Smoke-check that nothing changed yet**

Run: `just flutter-launch`
Expected: the app looks and behaves exactly as before (header bar on top, Flutter strip below it), because Dart does not call the channel yet. Close it.

- [ ] **Step 7: Commit**

```bash
git add apps/flutter/linux/runner
git commit -m "feat(flutter): Linux window channel for the immersive player"
```

---

### Task 3: `PlayerTopBar` insets and drag area

**Files:**
- Modify: `apps/flutter/lib/features/player/player_top_bar.dart`
- Test: `apps/flutter/test/features/player/player_top_bar_test.dart`

**Interfaces:**
- Consumes: `WindowButtonInsets` from Task 1.
- Produces: two new optional `PlayerTopBar` parameters, `WindowButtonInsets windowInsets` (default `WindowButtonInsets.zero`) and `VoidCallback? onStartDrag`.

- [ ] **Step 1: Write the failing tests**

Add to `player_top_bar_test.dart`, with this import at the top:

```dart
import 'package:stash_player_flutter/ui/window/window_frame.dart';
```

and these tests inside `main()`:

```dart
  group('window buttons drawn over the bar', () {
    PlayerTopBar bar({
      WindowButtonInsets insets = WindowButtonInsets.zero,
      VoidCallback? onStartDrag,
    }) => PlayerTopBar(
      title: 'Scene 42',
      metadataOpen: false,
      onBack: _noop,
      onToggleMetadata: _noop,
      streamOptions: const [],
      currentStream: null,
      onSelectStream: _noopSelectStream,
      onMenuOpenChanged: _noopMenuOpenChanged,
      windowInsets: insets,
      onStartDrag: onStartDrag,
    );

    testWidgets('their insets pad both ends of the bar', (tester) async {
      await _pump(
        tester,
        TargetPlatform.linux,
        bar(insets: const WindowButtonInsets(leading: 40, trailing: 90)),
      );

      final width = tester.getSize(find.byType(PlayerTopBar)).width;
      expect(tester.getTopLeft(_backButton).dx, AppTokens.stripInset + 40);
      expect(
        tester.getTopRight(find.byTooltip('Show details')).dx,
        width - AppTokens.space3 - 90,
      );
    });

    testWidgets('dragging the title starts a window drag', (tester) async {
      var drags = 0;
      await _pump(tester, TargetPlatform.linux, bar(onStartDrag: () => drags++));

      await tester.drag(find.text('Scene 42'), const Offset(60, 0));

      expect(drags, 1);
    });

    testWidgets('dragging a button does not', (tester) async {
      var drags = 0;
      await _pump(tester, TargetPlatform.linux, bar(onStartDrag: () => drags++));

      await tester.drag(_backButton, const Offset(60, 0));

      expect(drags, 0);
    });
  });
```

- [ ] **Step 2: Run them to see them fail**

Run: `FL flutter test test/features/player/player_top_bar_test.dart`
Expected: FAIL to compile, `windowInsets` and `onStartDrag` are not parameters.

- [ ] **Step 3: Implement**

In `player_top_bar.dart`, add the import:

```dart
import '../../ui/window/window_frame.dart';
```

Add to the constructor after `required this.onMenuOpenChanged,`:

```dart
    this.windowInsets = WindowButtonInsets.zero,
    this.onStartDrag,
```

Add the fields after `onMenuOpenChanged`:

```dart
  /// Room taken by window buttons the platform draws over this bar
  /// (Linux, while the titlebar is hidden). Zero elsewhere: macOS's
  /// traffic lights are already covered by [AppWindowChrome]'s inset.
  final WindowButtonInsets windowInsets;

  /// Starts moving the window. Called when the title is dragged; null
  /// where the platform's own titlebar handles that.
  final VoidCallback? onStartDrag;
```

Change the `Padding`'s insets to include them:

```dart
        padding: EdgeInsets.only(
          left:
              AppWindowChrome.leadingInsetFor(Theme.of(context).platform) +
              windowInsets.leading,
          right: AppTokens.space3 + windowInsets.trailing,
          bottom: AppTokens.space5,
        ),
```

Replace the `Expanded(child: Text(…))` title with a version whose whole flexible area is the drag handle:

```dart
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: onStartDrag == null
                      ? null
                      : (_) => onStartDrag!(),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.playerText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
```

Extend the class doc with one paragraph:

```dart
/// On Linux the window's own header bar is hidden while a scene is open
/// and GTK draws the window buttons over this bar (`window_channel.cc`).
/// [windowInsets] keeps the bar's controls clear of them, and the title
/// doubles as the handle that moves the window ([onStartDrag]).
```

- [ ] **Step 4: Run the whole file**

Run: `FL flutter test test/features/player/player_top_bar_test.dart`
Expected: PASS, including every pre-existing test (the defaults leave the layout unchanged).

- [ ] **Step 5: Format, analyze, commit**

```bash
git add apps/flutter/lib/features/player/player_top_bar.dart apps/flutter/test/features/player/player_top_bar_test.dart
git commit -m "feat(flutter): player top bar clears overlaid window buttons"
```

---

### Task 4: Scene screen drives the window frame; app wiring; manual gate

**Files:**
- Modify: `apps/flutter/lib/features/player/scene_screen.dart`
- Modify: `apps/flutter/lib/app/providers.dart`
- Modify: `apps/flutter/lib/app/app.dart`
- Test: `apps/flutter/test/features/player/scene_screen_test.dart`

**Interfaces:**
- Consumes: `WindowFrame`, `WindowFrameScope`, `WindowButtonInsets`, `ChannelWindowFrame.reset()` (Task 1); `RecordingWindowFrame` (Task 1); `PlayerTopBar.windowInsets` / `onStartDrag` (Task 3); the runner channel (Task 2).
- Produces: `windowFrameProvider` (`Provider<WindowFrame?>`).

- [ ] **Step 1: Let the test harness provide a window frame**

In `scene_screen_test.dart`, add imports:

```dart
import 'package:stash_player_flutter/ui/window/window_frame.dart';

import '../../support/recording_window_frame.dart';
```

Give `_app` and `_pumpReadyScene` an optional frame:

```dart
Widget _app(
  ProviderContainer container,
  String sceneId, {
  BrowseContext? browse,
  WindowFrame? frame,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildAppTheme(Brightness.light),
    builder: (context, child) => frame == null
        ? child!
        : WindowFrameScope(frame: frame, child: child!),
    home: SceneScreen(sceneId: sceneId, browse: browse),
  ),
);
```

In `_pumpReadyScene`, add the parameter `WindowFrame? frame,` and pass it on: `_app(harness.container, scene.id, browse: browse, frame: frame)`.

- [ ] **Step 2: Write the failing tests**

Add a group to `scene_screen_test.dart`:

```dart
  group('window frame', () {
    testWidgets('goes immersive while mounted and back on teardown', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final frame = RecordingWindowFrame();
      await _pumpReadyScene(tester, harness, _scene(), frame: frame);

      expect(frame.calls.first, 'setImmersive true');
      expect(frame.calls, isNot(contains('setImmersive false')));

      await _tearDownScene(tester, harness);
      expect(frame.calls.last, 'setImmersive false');
    });

    testWidgets('the window buttons hide and show with the controls', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final frame = RecordingWindowFrame();
      await _pumpReadyScene(tester, harness, _scene(), frame: frame);

      await tester.pump(const Duration(seconds: 4));
      expect(frame.calls.last, 'setControlsVisible false');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(frame.calls.last, 'setControlsVisible true');
      await _tearDownScene(tester, harness);
    });

    testWidgets('hovering a window button holds the auto-hide timer', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final frame = RecordingWindowFrame();
      await _pumpReadyScene(tester, harness, _scene(), frame: frame);

      frame.controlsHovered.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(_controlsOpacity(tester), 1.0);

      frame.controlsHovered.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(_controlsOpacity(tester), 0.0);
      await _tearDownScene(tester, harness);
    });

    testWidgets('insets pad the top bar and drop the drawer below it', (
      tester,
    ) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final frame = RecordingWindowFrame();
      await _pumpReadyScene(tester, harness, _scene(), frame: frame);
      expect(tester.getTopLeft(find.byType(SceneMetadataDrawer)).dy, 0);

      frame.insets.value = const WindowButtonInsets(trailing: 100);
      await tester.pump();

      final width = tester.getSize(find.byType(SceneScreen)).width;
      expect(
        tester.getTopRight(find.byTooltip('Show details')).dx,
        width - AppTokens.space3 - 100,
      );
      expect(
        tester.getTopLeft(find.byType(SceneMetadataDrawer)).dy,
        AppTokens.stripHeight,
      );
      await _tearDownScene(tester, harness);
    });

    testWidgets('dragging the title asks the window to move', (tester) async {
      final harness = _harness();
      addTearDown(harness.container.dispose);
      final frame = RecordingWindowFrame();
      final scene = _scene();
      await _pumpReadyScene(tester, harness, scene, frame: frame);

      await tester.drag(find.text(scene.displayTitle), const Offset(60, 0));

      expect(frame.calls, contains('startDrag'));
      await _tearDownScene(tester, harness);
    });
  });
```

If `find.text(scene.displayTitle)` matches more than one widget (the drawer repeats the title), narrow it with `find.descendant(of: find.byType(PlayerTopBar), matching: find.text(scene.displayTitle))` and import `player_top_bar.dart`.

- [ ] **Step 3: Run them to see them fail**

Run: `FL flutter test test/features/player/scene_screen_test.dart --plain-name "window frame"`
Expected: FAIL, `frame.calls` is empty.

- [ ] **Step 4: Implement in `scene_screen.dart`**

Add imports:

```dart
import '../../ui/widgets/window_chrome.dart';
import '../../ui/window/window_frame.dart';
```

Add fields to `_SceneScreenState`, after `_menuOpen`:

```dart
  /// The window's own chrome where the platform draws its buttons over
  /// the video (Linux). Null elsewhere.
  WindowFrame? _windowFrame;

  /// Kept apart from [_hoveringControls]: the pointer leaving Flutter's
  /// bar for a GTK window button reports "left" and "entered" from two
  /// different sources, in no guaranteed order.
  bool _hoveringWindowButtons = false;
```

Add after `initState`:

```dart
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_windowFrame != null) return;
    final frame = WindowFrameScope.maybeOf(context);
    if (frame == null) return;
    _windowFrame = frame;
    frame.insets.addListener(_onWindowInsetsChanged);
    frame.controlsHovered.addListener(_onWindowButtonsHovered);
    unawaited(frame.setImmersive(true));
  }

  void _onWindowInsetsChanged() {
    if (mounted) setState(() {});
  }

  void _onWindowButtonsHovered() {
    if (!mounted) return;
    _hoveringWindowButtons = _windowFrame!.controlsHovered.value;
    _registerActivity(ref.read(playbackControllerProvider).state);
  }
```

At the top of `dispose()`, before `_lifecycleListener.dispose();`:

```dart
    final frame = _windowFrame;
    if (frame != null) {
      frame.insets.removeListener(_onWindowInsetsChanged);
      frame.controlsHovered.removeListener(_onWindowButtonsHovered);
      unawaited(frame.setImmersive(false));
    }
```

In `_suppressHide`, add `_hoveringWindowButtons ||` after `_hoveringControls ||`.

In `_setControlsVisible`, after the `setState` line:

```dart
    unawaited(_windowFrame?.setControlsVisible(value));
```

In `_buildSceneStack`, pass two more arguments to `PlayerTopBar`:

```dart
                                  windowInsets:
                                      _windowFrame?.insets.value ??
                                      WindowButtonInsets.zero,
                                  onStartDrag: _windowFrame == null
                                      ? null
                                      : () => unawaited(
                                          _windowFrame!.startDrag(),
                                        ),
```

In the drawer's `Positioned` (the one with `width: math.min(SceneMetadataDrawer.maxWidth, …)`), replace `top: 0,` with:

```dart
              // Below the window buttons GTK draws over the top edge,
              // when there are any.
              top: (_windowFrame?.insets.value.isZero ?? true)
                  ? 0
                  : AppWindowChrome.stripHeightFor(Theme.of(context).platform),
```

- [ ] **Step 5: Run the scene screen tests**

Run: `FL flutter test test/features/player/scene_screen_test.dart`
Expected: PASS, the new group and every pre-existing test.

- [ ] **Step 6: Wire the provider and scope**

In `providers.dart`, add imports for `../services/channel_window_frame.dart` and `../ui/window/window_frame.dart`, and after `nativeToolbarProvider`:

```dart
/// The window chrome the scene screen drives: the Linux runner's hidden
/// titlebar and overlaid window buttons, none elsewhere (macOS's
/// titlebar is already transparent, and tests run as Android).
final windowFrameProvider = Provider<WindowFrame?>((ref) {
  if (defaultTargetPlatform != TargetPlatform.linux) return null;
  final frame = ChannelWindowFrame();
  unawaited(frame.reset());
  return frame;
});
```

In `app.dart`, import `../ui/window/window_frame.dart`, watch the provider next to `nativeToolbar`:

```dart
    final windowFrame = ref.watch(windowFrameProvider);
```

and replace the `builder` body's return with:

```dart
          final withToolbar = nativeToolbar == null
              ? content
              : NativeToolbarScope(toolbar: nativeToolbar, child: content);
          return windowFrame == null
              ? withToolbar
              : WindowFrameScope(frame: windowFrame, child: withToolbar);
```

- [ ] **Step 7: Full check**

Run: `just flutter-check`
Expected: format clean, analyze clean, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add apps/flutter/lib apps/flutter/test
git commit -m "feat(flutter): the player hides the Linux titlebar and overlays window buttons"
```

- [ ] **Step 9: MANUAL GATE (the spec's spike). Stop and have the user verify.**

Run `just flutter-run` and open a scene. Check each item on Wayland, and on X11 GNOME if available:

1. Opening a scene hides the header bar, the video reaches the window's top edge, and the window keeps its shadow and can still be resized from every edge.
2. The window buttons appear over the video on the side and in the set the desktop is configured for, and each one works.
3. Back, quality and details in the Flutter top bar are clickable. Clicks beside the window buttons reach Flutter.
4. Dragging the title moves the window. Afterwards the first click in the window is not swallowed.
5. The window buttons fade out with the OSD, come back on pointer movement, and stay while the pointer rests on them.
6. The window buttons are legible over a dark frame and a bright frame, in the light and the dark system theme.
7. With the details drawer open, the window buttons do not cover its content.
8. Going back restores the header bar.

Fallbacks if an item fails (change only `window_channel.cc`; the Dart side and the channel protocol stay as they are):

- Item 1 fails (hiding the titlebar loses shadows or resize edges): keep the header bar visible but swap it out. In `set_immersive`, call `gtk_window_set_titlebar(self->window, empty_box)` with a zero-height `GtkBox` when entering and `gtk_window_set_titlebar(self->window, self->titlebar)` when leaving; hold a reference on both widgets (`g_object_ref_sink`) so the swap does not destroy them.
- Item 3 fails (the bar swallows clicks): drop the pass-through and stop spanning the width. Create two overlaid header bars, one with `halign` `GTK_ALIGN_START` and `gtk_header_bar_set_decoration_layout` set to the part of `gtk-decoration-layout` before the colon plus `":"`, one with `GTK_ALIGN_END` and `":"` plus the part after it, and report each one's allocated width as its inset.
- Item 4 fails on Wayland (no drag, or a stuck pointer): record it as a known limitation in the spec, pass `onStartDrag: null` from `SceneScreen`, and leave window moving to the compositor's shortcut (Super+drag).
- Item 6 fails: add `headerbar.stash-window-controls button.titlebutton { color: white; }` to `kControlsCss`.

Record the outcome under "Spike outcome" at the end of the spec, commit it (`git add -f`), and continue only once items 1–3 hold.

---

### Task 5: Toolbar, Dart side

**Files:**
- Modify: `apps/flutter/lib/services/channel_native_toolbar.dart`
- Modify: `apps/flutter/lib/features/library/library_toolbar.dart`
- Modify: `apps/flutter/lib/app/providers.dart`
- Test: `apps/flutter/test/services/channel_native_toolbar_test.dart`
- Test: `apps/flutter/test/features/library/library_screen_test.dart`

**Interfaces:**
- Produces: toggle and action payloads carry `'icon'` (the `AppIcon.gnome` file name). On Linux the published spec ends with an `AppToolbarAction` whose id is `main-menu`. `nativeToolbarProvider` is non-null on Linux.

Until Task 6 lands, the Linux runner has no `stash_player/toolbar` handler, so `set` fails with `MissingPluginException` and the library falls back to its drawn strip. The app stays usable between the two tasks.

- [ ] **Step 1: Update the channel test for the `icon` field**

In `channel_native_toolbar_test.dart`, in `'serializes every item kind'`, add `'icon': 'eye-crossed',` to the expected toggle map (after `'symbol': 'eye.slash',`), and after the `symbol` expectation for `items[3]`:

```dart
    expect(items[3], containsPair('icon', 'list'));
```

- [ ] **Step 2: Run it to see it fail**

Run: `FL flutter test test/services/channel_native_toolbar_test.dart`
Expected: FAIL, the toggle map has no `icon`.

- [ ] **Step 3: Add the field**

In `channel_native_toolbar.dart`'s `_encode`, add `'icon': item.icon.gnome,` after the `'symbol'` line in both the `AppToolbarToggle` and the `AppToolbarAction` cases. Update the class doc's first sentence to:

```dart
/// Shows [AppToolbar]s as the window's own toolbar over the
/// `stash_player/toolbar` channel: an `NSToolbar` on macOS
/// (`NativeToolbarChannel.swift`), the `GtkHeaderBar` on Linux
/// (`native_toolbar_channel.cc`).
///
/// Only ids, labels, icon names and state cross the channel (`symbol` is
/// the SF Symbol macOS draws, `icon` the bundled GNOME SVG Linux draws).
```

Run the test again. Expected: PASS.

- [ ] **Step 4: Write the failing library tests**

In `library_screen_test.dart`, after the `'native toolbar (macOS)'` group, add (importing `window_chrome.dart` and `recording_menus.dart` if the file does not already):

```dart
  group('native toolbar (Linux)', () {
    testWidgets('draws no strip of its own and adds the main menu', (
      tester,
    ) async {
      final toolbar = RecordingToolbar();
      await _pumpLibrary(tester, api: _pagedApi(), toolbar: toolbar);
      await tester.pump();

      expect(find.byType(AppWindowChrome), findsNothing);
      expect(toolbar.last.items.map((item) => item.id), [
        'filters',
        'play-random',
        'flexible-space',
        'search',
        'scan',
        'tasks',
        'main-menu',
      ]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('the main menu offers Preferences under its button', (
      tester,
    ) async {
      final toolbar = RecordingToolbar();
      final menus = RecordingMenus(choose: 'Preferences');
      final harness = await _pumpLibrary(
        tester,
        api: _pagedApi(),
        toolbar: toolbar,
        menus: menus,
      );
      await tester.pump();

      const anchor = Rect.fromLTWH(1100, 0, 34, 0);
      toolbar.item<AppToolbarAction>('main-menu').onPressed!(anchor);
      await tester.pump();

      expect(menus.anchors.single, anchor);
      expect(
        harness.container.read(appControllerProvider),
        const LibraryDestination(settingsOpen: true),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('falls back to the drawn strip when the native side is '
        'missing', (tester) async {
      final toolbar = RecordingToolbar(available: false);
      await _pumpLibrary(tester, api: _pagedApi(), toolbar: toolbar);
      await tester.pump();
      await tester.pump();

      expect(find.byType(AppWindowChrome), findsOneWidget);
      expect(find.byKey(const Key('library-search')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
```

`_Harness` already exposes its `ProviderContainer`; use whatever field name it has (the existing Preferences test near line 1466 shows how that file reads `appControllerProvider` and what state the app controller must be in for `openSettings` to apply; copy its setup). Also add one line to the existing macOS test `'publishes the controls and draws none of its own'`:

```dart
      expect(find.byType(AppWindowChrome), findsOneWidget);
```

- [ ] **Step 5: Run them to see them fail**

Run: `FL flutter test test/features/library/library_screen_test.dart --plain-name "native toolbar (Linux)"`
Expected: the first two FAIL (a strip is drawn; no `main-menu` item). The third already passes.

- [ ] **Step 6: Implement in `library_toolbar.dart`**

Replace the `_usesNative` branch in `build`:

```dart
      if (_usesNative) {
        _schedulePublish();
        // On macOS the toolbar floats over the Flutter view, so the
        // titlebar band stays Flutter's (it also moves the window). On
        // Linux the header bar sits above the view: nothing to draw.
        return Theme.of(context).platform == TargetPlatform.linux
            ? const SizedBox.shrink()
            : const AppWindowChrome(children: []);
      }
```

In `_nativeSpec`, after the `tasks` action and before the closing `]);`:

```dart
      if (_showsMainMenu)
        AppToolbarAction(
          id: 'main-menu',
          label: 'Main Menu',
          icon: AppIcon.mainMenu,
          onPressed: (anchor) => unawaited(
            NativeMenusScope.of(context).show(
              context,
              AppMenu([
                AppMenuAction(
                  label: 'Preferences',
                  onSelected: widget.onOpenSettings,
                ),
              ]),
              anchor ?? _trailingAnchor(),
            ),
          ),
        ),
```

Change `_nativeSpec`'s doc comment's last sentence to: "The main menu follows on GNOME; on macOS, Settings… is in the app menu."

In `_trailingAnchor`, replace the height argument so a Linux popover hangs from the view's top edge:

```dart
      Theme.of(context).platform == TargetPlatform.linux
          ? 0
          : AppWindowChrome.stripHeightFor(TargetPlatform.macOS),
```

Update the class doc's last paragraph to:

```dart
/// Where the app provides a [NativeToolbarScope], the controls are
/// published to the window's own toolbar instead of being drawn: an
/// `NSToolbar` on macOS, where the strip keeps only its empty titlebar
/// band, and the `GtkHeaderBar` on Linux, where the strip is not drawn
/// at all. If the native side reports itself unavailable, the drawn
/// strip comes back.
```

and `NativeToolbarScope`'s doc in `lib/ui/toolbar/native_toolbar.dart` to: "With no scope (most widget tests) [maybeOf] is null and the toolbar is drawn in Flutter."

- [ ] **Step 7: Enable the provider on Linux**

In `providers.dart`, change `nativeToolbarProvider`:

```dart
/// The window toolbar the library publishes its controls to: the real
/// `NSToolbar` on macOS and the `GtkHeaderBar` on Linux. None elsewhere
/// (tests run as Android).
final nativeToolbarProvider = Provider<NativeToolbar?>((ref) {
  if (defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.linux) {
    return null;
  }
  final toolbar = ChannelNativeToolbar();
  unawaited(toolbar.reset());
  return toolbar;
});
```

- [ ] **Step 8: Full check and commit**

Run: `just flutter-check`
Expected: all pass. If a pre-existing test that pins `TargetPlatform.linux` now fails because the app-level provider is non-null there, give it the drawn strip by overriding `nativeToolbarProvider.overrideWithValue(null)` in that test's container.

```bash
git add apps/flutter/lib apps/flutter/test
git commit -m "feat(flutter): publish the library toolbar to the native toolbar on Linux"
```

---

### Task 6: Runner `native_toolbar_channel`

**Files:**
- Create: `apps/flutter/linux/runner/native_toolbar_channel.h`
- Create: `apps/flutter/linux/runner/native_toolbar_channel.cc`
- Modify: `apps/flutter/linux/runner/my_application.cc`
- Modify: `apps/flutter/linux/runner/CMakeLists.txt`

**Interfaces:**
- Consumes: `header_bar` (null in WM-title-bar mode), `view` and `project` in `my_application_activate` (Task 2); the `setItems` payload from Task 5 (each item a map with `type`, `id`, `label`, `tooltip`, and per type: `options` + `selected`; `icon` + `selected`; `icon` + `enabled` + `badge`; `text` + `placeholder`; `children`).
- Produces: `native_toolbar_channel_new(FlView*, GtkHeaderBar*, const gchar* assets_path)` and `native_toolbar_channel_free`.

Design notes for the implementer:
- **Dart owns all state.** A toggle the user clicks is put straight back to its published state, then `activated` is sent; the republish that follows moves it.
- **Reconciliation.** A signature string (types, ids, menu options, nesting) identifies the spec's structure. Same signature: update widgets in place. Different: rebuild everything. The library's structure only changes between "empty" and "full", so in practice widgets are built once per visit.
- **Icons.** The bundled GNOME SVGs are not named `*-symbolic.svg`, so GTK would not recolour them. Each icon is a small drawing area that paints the SVG's alpha in the widget's current foreground colour, which follows the theme and the insensitive state.

- [ ] **Step 1: Write the header**

`apps/flutter/linux/runner/native_toolbar_channel.h`:

```cpp
#ifndef RUNNER_NATIVE_TOOLBAR_CHANNEL_H_
#define RUNNER_NATIVE_TOOLBAR_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Fills [bar], the window's GtkHeaderBar, with the toolbar Dart describes
// on `stash_player/toolbar`: the same `setItems` / `reset` protocol and
// `activated` / `menuSelected` / `searchChanged` events as the macOS
// runner's NativeToolbarChannel.swift.
//
// menu → GtkMenuButton with a radio GtkMenu; toggle → GtkToggleButton;
// action → GtkButton; search → GtkSearchEntry as the bar's centre widget;
// group → a `linked` GtkBox; space → items after it are packed at the end.
//
// Icons are the app's own GNOME SVGs under
// [assets_path]/assets/icons/gnome, painted in the theme's foreground
// colour.
//
// With a null [bar] (the window manager draws the title bar) `setItems`
// answers the `unavailable` error and Dart draws its own strip.
typedef struct _NativeToolbarChannel NativeToolbarChannel;

NativeToolbarChannel* native_toolbar_channel_new(FlView* view,
                                                 GtkHeaderBar* bar,
                                                 const gchar* assets_path);
void native_toolbar_channel_free(NativeToolbarChannel* self);

#endif  // RUNNER_NATIVE_TOOLBAR_CHANNEL_H_
```

- [ ] **Step 2: Write the implementation**

`apps/flutter/linux/runner/native_toolbar_channel.cc`:

```cpp
#include "native_toolbar_channel.h"

struct _NativeToolbarChannel {
  FlMethodChannel* channel;
  FlView* view;
  // Null when the window manager draws the title bar.
  GtkHeaderBar* bar;
  gchar* icons_dir;
  // Item id → its widget. The bar owns the widgets.
  GHashTable* widgets;
  // The structure of the spec the widgets were built from.
  gchar* signature;
  // Set while a spec is being applied, so the state changes it makes
  // aren't reported back to Dart as user input.
  gboolean applying;
};

static const gint kIconSize = 16;
static const gchar* kIdKey = "stash-player-toolbar-id";
static const gchar* kIndexKey = "stash-player-toolbar-index";
static const gchar* kSelectedKey = "stash-player-toolbar-selected";
static const gchar* kIconKey = "stash-player-toolbar-icon";
static const gchar* kLabelKey = "stash-player-toolbar-label";
static const gchar* kMenuKey = "stash-player-toolbar-menu";
static const gchar* kPixbufKey = "stash-player-toolbar-pixbuf";
static const gchar* kIconNameKey = "stash-player-toolbar-icon-name";
static const gchar* kBadgeKey = "stash-player-toolbar-badge";

// ---- reading the spec ------------------------------------------------

static const gchar* text_of(FlValue* map, const gchar* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : "";
}

static gboolean flag_of(FlValue* map, const gchar* key, gboolean fallback) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL
             ? fl_value_get_bool(value)
             : fallback;
}

static gint64 int_of(FlValue* map, const gchar* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT
             ? fl_value_get_int(value)
             : 0;
}

static FlValue* list_of(FlValue* map, const gchar* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_LIST
             ? value
             : nullptr;
}

static gboolean is_type(FlValue* item, const gchar* type) {
  return g_strcmp0(text_of(item, "type"), type) == 0;
}

static void append_signature(GString* out, FlValue* item) {
  g_string_append_printf(out, "%s:%s", text_of(item, "type"),
                         text_of(item, "id"));
  FlValue* options = list_of(item, "options");
  for (size_t i = 0; options != nullptr && i < fl_value_get_length(options);
       i++) {
    FlValue* option = fl_value_get_list_value(options, i);
    g_string_append_printf(out, "|%s",
                           fl_value_get_type(option) == FL_VALUE_TYPE_STRING
                               ? fl_value_get_string(option)
                               : "");
  }
  FlValue* children = list_of(item, "children");
  if (children != nullptr) {
    g_string_append_c(out, '[');
    for (size_t i = 0; i < fl_value_get_length(children); i++) {
      append_signature(out, fl_value_get_list_value(children, i));
    }
    g_string_append_c(out, ']');
  }
  g_string_append_c(out, ';');
}

// ---- events to Dart --------------------------------------------------

static FlValue* event_for(GObject* source) {
  FlValue* args = fl_value_new_map();
  fl_value_set_string_take(
      args, "id",
      fl_value_new_string(
          static_cast<const gchar*>(g_object_get_data(source, kIdKey))));
  return args;
}

static void send(NativeToolbarChannel* self, const gchar* method,
                 FlValue* args) {
  fl_method_channel_invoke_method(self->channel, method, args, nullptr,
                                  nullptr, nullptr);
}

// ---- icons -----------------------------------------------------------

static gboolean icon_draw_cb(GtkWidget* area, cairo_t* cr, gpointer data) {
  GdkPixbuf* pixbuf =
      GDK_PIXBUF(g_object_get_data(G_OBJECT(area), kPixbufKey));
  GtkStyleContext* context = gtk_widget_get_style_context(area);
  GdkRGBA color;
  gtk_style_context_get_color(context, gtk_style_context_get_state(context),
                              &color);
  if (pixbuf != nullptr) {
    cairo_surface_t* mask = gdk_cairo_surface_create_from_pixbuf(
        pixbuf, gtk_widget_get_scale_factor(area),
        gtk_widget_get_window(area));
    gdk_cairo_set_source_rgba(cr, &color);
    cairo_mask_surface(cr, mask, 0, 0);
    cairo_surface_destroy(mask);
  }
  if (g_object_get_data(G_OBJECT(area), kBadgeKey) != nullptr) {
    GdkRGBA accent = color;
    gtk_style_context_lookup_color(context, "theme_selected_bg_color",
                                   &accent);
    gdk_cairo_set_source_rgba(cr, &accent);
    cairo_arc(cr, kIconSize - 3, 3, 3, 0, 2 * G_PI);
    cairo_fill(cr);
  }
  return FALSE;
}

static GtkWidget* icon_new() {
  GtkWidget* area = gtk_drawing_area_new();
  gtk_widget_set_size_request(area, kIconSize, kIconSize);
  gtk_widget_set_halign(area, GTK_ALIGN_CENTER);
  gtk_widget_set_valign(area, GTK_ALIGN_CENTER);
  g_signal_connect(area, "draw", G_CALLBACK(icon_draw_cb), nullptr);
  gtk_widget_show(area);
  return area;
}

static void icon_set(NativeToolbarChannel* self, GtkWidget* area,
                     const gchar* name, gboolean badge) {
  g_object_set_data(G_OBJECT(area), kBadgeKey, GINT_TO_POINTER(badge));
  const gchar* current =
      static_cast<const gchar*>(g_object_get_data(G_OBJECT(area), kIconNameKey));
  if (g_strcmp0(current, name) != 0) {
    gint size = kIconSize * gtk_widget_get_scale_factor(area);
    g_autofree gchar* file = g_strdup_printf("%s.svg", name);
    g_autofree gchar* path =
        g_build_filename(self->icons_dir, file, nullptr);
    g_autoptr(GError) error = nullptr;
    GdkPixbuf* pixbuf =
        gdk_pixbuf_new_from_file_at_size(path, size, size, &error);
    if (pixbuf == nullptr) {
      g_warning("Toolbar icon %s: %s", path, error->message);
      g_object_set_data(G_OBJECT(area), kPixbufKey, nullptr);
    } else {
      g_object_set_data_full(G_OBJECT(area), kPixbufKey, pixbuf,
                             g_object_unref);
    }
    g_object_set_data_full(G_OBJECT(area), kIconNameKey, g_strdup(name),
                           g_free);
  }
  gtk_widget_queue_draw(area);
}

// ---- widget callbacks ------------------------------------------------

static void action_clicked_cb(GtkButton* button, gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  g_autoptr(FlValue) args = event_for(G_OBJECT(button));
  gint x = 0, y = 0;
  // The header bar is above the Flutter view, so the popover Dart anchors
  // to this rect hangs from the view's top edge, under the button.
  if (gtk_widget_translate_coordinates(GTK_WIDGET(button),
                                       GTK_WIDGET(self->view), 0, 0, &x, &y)) {
    FlValue* rect = fl_value_new_map();
    fl_value_set_string_take(rect, "x", fl_value_new_float(x));
    fl_value_set_string_take(rect, "y", fl_value_new_float(0));
    fl_value_set_string_take(
        rect, "width",
        fl_value_new_float(gtk_widget_get_allocated_width(GTK_WIDGET(button))));
    fl_value_set_string_take(rect, "height", fl_value_new_float(0));
    fl_value_set_string_take(args, "rect", rect);
  }
  send(self, "activated", args);
}

static void toggle_toggled_cb(GtkToggleButton* button, gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  if (self->applying) return;
  // Dart owns the state: put the button back, and let the spec Dart
  // republishes in answer move it.
  self->applying = TRUE;
  gtk_toggle_button_set_active(
      button,
      GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), kSelectedKey)));
  self->applying = FALSE;
  g_autoptr(FlValue) args = event_for(G_OBJECT(button));
  send(self, "activated", args);
}

static void menu_item_toggled_cb(GtkCheckMenuItem* item, gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  if (self->applying || !gtk_check_menu_item_get_active(item)) return;
  g_autoptr(FlValue) args = event_for(G_OBJECT(item));
  fl_value_set_string_take(
      args, "index",
      fl_value_new_int(
          GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), kIndexKey))));
  send(self, "menuSelected", args);
}

static void search_changed_cb(GtkSearchEntry* entry, gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  if (self->applying) return;
  g_autoptr(FlValue) args = event_for(G_OBJECT(entry));
  fl_value_set_string_take(
      args, "text",
      fl_value_new_string(gtk_entry_get_text(GTK_ENTRY(entry))));
  send(self, "searchChanged", args);
}

// Escape clears the search and gives the keyboard back to the Flutter
// view; Enter just gives it back.
static void search_stopped_cb(GtkSearchEntry* entry, gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  gtk_entry_set_text(GTK_ENTRY(entry), "");
  gtk_widget_grab_focus(GTK_WIDGET(self->view));
}

static void search_activated_cb(GtkEntry* entry, gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  gtk_widget_grab_focus(GTK_WIDGET(self->view));
}

// ---- building --------------------------------------------------------

static void tag(GtkWidget* widget, FlValue* item) {
  g_object_set_data_full(G_OBJECT(widget), kIdKey,
                         g_strdup(text_of(item, "id")), g_free);
}

static GtkWidget* build_icon_button(GtkWidget* button) {
  GtkWidget* icon = icon_new();
  gtk_container_add(GTK_CONTAINER(button), icon);
  g_object_set_data(G_OBJECT(button), kIconKey, icon);
  return button;
}

static GtkWidget* build_menu(NativeToolbarChannel* self, FlValue* item) {
  GtkWidget* button = gtk_menu_button_new();
  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget* label = gtk_label_new("");
  gtk_container_add(GTK_CONTAINER(box), label);
  gtk_container_add(
      GTK_CONTAINER(box),
      gtk_image_new_from_icon_name("pan-down-symbolic", GTK_ICON_SIZE_BUTTON));
  gtk_widget_show_all(box);
  gtk_container_add(GTK_CONTAINER(button), box);

  GtkWidget* menu = gtk_menu_new();
  GSList* group = nullptr;
  FlValue* options = list_of(item, "options");
  for (size_t i = 0; options != nullptr && i < fl_value_get_length(options);
       i++) {
    FlValue* option = fl_value_get_list_value(options, i);
    GtkWidget* entry = gtk_radio_menu_item_new_with_label(
        group, fl_value_get_type(option) == FL_VALUE_TYPE_STRING
                   ? fl_value_get_string(option)
                   : "");
    group = gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(entry));
    tag(entry, item);
    g_object_set_data(G_OBJECT(entry), kIndexKey,
                      GINT_TO_POINTER(static_cast<gint>(i)));
    g_signal_connect(entry, "toggled", G_CALLBACK(menu_item_toggled_cb), self);
    gtk_widget_show(entry);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), entry);
  }
  gtk_menu_button_set_popup(GTK_MENU_BUTTON(button), menu);
  g_object_set_data(G_OBJECT(button), kLabelKey, label);
  g_object_set_data(G_OBJECT(button), kMenuKey, menu);
  return button;
}

static GtkWidget* build_search(NativeToolbarChannel* self) {
  GtkWidget* entry = gtk_search_entry_new();
  gtk_entry_set_width_chars(GTK_ENTRY(entry), 28);
  gtk_widget_set_hexpand(entry, TRUE);
  g_signal_connect(entry, "search-changed", G_CALLBACK(search_changed_cb),
                   self);
  g_signal_connect(entry, "stop-search", G_CALLBACK(search_stopped_cb), self);
  g_signal_connect(entry, "activate", G_CALLBACK(search_activated_cb), self);
  return entry;
}

static GtkWidget* build_item(NativeToolbarChannel* self, FlValue* item) {
  GtkWidget* widget;
  if (is_type(item, "group")) {
    widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_style_context_add_class(gtk_widget_get_style_context(widget),
                                "linked");
    FlValue* children = list_of(item, "children");
    for (size_t i = 0;
         children != nullptr && i < fl_value_get_length(children); i++) {
      gtk_container_add(
          GTK_CONTAINER(widget),
          build_item(self, fl_value_get_list_value(children, i)));
    }
    gtk_widget_show(widget);
    return widget;
  }
  if (is_type(item, "menu")) {
    widget = build_menu(self, item);
  } else if (is_type(item, "toggle")) {
    widget = build_icon_button(gtk_toggle_button_new());
    g_signal_connect(widget, "toggled", G_CALLBACK(toggle_toggled_cb), self);
  } else if (is_type(item, "search")) {
    widget = build_search(self);
  } else {
    widget = build_icon_button(gtk_button_new());
    g_signal_connect(widget, "clicked", G_CALLBACK(action_clicked_cb), self);
  }
  tag(widget, item);
  g_hash_table_insert(self->widgets, g_strdup(text_of(item, "id")), widget);
  gtk_widget_show(widget);
  return widget;
}

static void destroy_cb(GtkWidget* widget, gpointer data) {
  gtk_widget_destroy(widget);
}

static void clear(NativeToolbarChannel* self) {
  g_hash_table_remove_all(self->widgets);
  g_clear_pointer(&self->signature, g_free);
  // The custom title first: with none, the bar shows the window title.
  gtk_header_bar_set_custom_title(self->bar, nullptr);
  gtk_container_foreach(GTK_CONTAINER(self->bar), destroy_cb, nullptr);
}

static void rebuild(NativeToolbarChannel* self, FlValue* items) {
  clear(self);
  gboolean at_end = FALSE;
  GList* trailing = nullptr;
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    FlValue* item = fl_value_get_list_value(items, i);
    if (is_type(item, "space")) {
      at_end = TRUE;
      continue;
    }
    GtkWidget* widget = build_item(self, item);
    if (is_type(item, "search")) {
      gtk_header_bar_set_custom_title(self->bar, widget);
    } else if (at_end) {
      trailing = g_list_prepend(trailing, widget);
    } else {
      gtk_header_bar_pack_start(self->bar, widget);
    }
  }
  // pack_end fills from the edge inwards, so the last item goes first.
  for (GList* l = trailing; l != nullptr; l = l->next) {
    gtk_header_bar_pack_end(self->bar, GTK_WIDGET(l->data));
  }
  g_list_free(trailing);
}

// ---- updating in place -----------------------------------------------

static void update_menu(GtkWidget* button, FlValue* item) {
  gint64 selected = int_of(item, "selected");
  FlValue* options = list_of(item, "options");
  if (options != nullptr && selected >= 0 &&
      static_cast<size_t>(selected) < fl_value_get_length(options)) {
    gtk_label_set_text(
        GTK_LABEL(g_object_get_data(G_OBJECT(button), kLabelKey)),
        fl_value_get_string(fl_value_get_list_value(options, selected)));
  }
  GtkWidget* menu =
      GTK_WIDGET(g_object_get_data(G_OBJECT(button), kMenuKey));
  GList* entries = gtk_container_get_children(GTK_CONTAINER(menu));
  GList* chosen = g_list_nth(entries, static_cast<guint>(selected));
  if (chosen != nullptr) {
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(chosen->data), TRUE);
  }
  g_list_free(entries);
}

static void update_item(NativeToolbarChannel* self, FlValue* item) {
  if (is_type(item, "group")) {
    FlValue* children = list_of(item, "children");
    for (size_t i = 0;
         children != nullptr && i < fl_value_get_length(children); i++) {
      update_item(self, fl_value_get_list_value(children, i));
    }
    return;
  }
  GtkWidget* widget = GTK_WIDGET(
      g_hash_table_lookup(self->widgets, text_of(item, "id")));
  if (widget == nullptr) return;
  gtk_widget_set_tooltip_text(widget, text_of(item, "tooltip"));
  atk_object_set_name(gtk_widget_get_accessible(widget),
                      text_of(item, "label"));
  if (is_type(item, "menu")) {
    update_menu(widget, item);
  } else if (is_type(item, "toggle")) {
    gboolean selected = flag_of(item, "selected", FALSE);
    g_object_set_data(G_OBJECT(widget), kSelectedKey,
                      GINT_TO_POINTER(selected));
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(widget), selected);
    icon_set(self,
             GTK_WIDGET(g_object_get_data(G_OBJECT(widget), kIconKey)),
             text_of(item, "icon"), FALSE);
  } else if (is_type(item, "action")) {
    gtk_widget_set_sensitive(widget, flag_of(item, "enabled", TRUE));
    icon_set(self,
             GTK_WIDGET(g_object_get_data(G_OBJECT(widget), kIconKey)),
             text_of(item, "icon"), flag_of(item, "badge", FALSE));
  } else if (is_type(item, "search")) {
    gtk_entry_set_placeholder_text(GTK_ENTRY(widget),
                                   text_of(item, "placeholder"));
    // Only while the user isn't typing, so a republish can't overwrite a
    // newer keystroke.
    if (!gtk_widget_has_focus(widget) &&
        g_strcmp0(gtk_entry_get_text(GTK_ENTRY(widget)),
                  text_of(item, "text")) != 0) {
      gtk_entry_set_text(GTK_ENTRY(widget), text_of(item, "text"));
    }
  }
}

static void set_items(NativeToolbarChannel* self, FlValue* items) {
  g_autoptr(GString) signature = g_string_new(nullptr);
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    append_signature(signature, fl_value_get_list_value(items, i));
  }
  self->applying = TRUE;
  if (g_strcmp0(signature->str, self->signature) != 0) {
    rebuild(self, items);
    self->signature = g_strdup(signature->str);
  }
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    update_item(self, fl_value_get_list_value(items, i));
  }
  self->applying = FALSE;
}

// ---- channel ---------------------------------------------------------

static void method_cb(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  NativeToolbarChannel* self = static_cast<NativeToolbarChannel*>(user_data);
  const gchar* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (self->bar == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "the window manager draws the title bar", nullptr));
  } else if (g_strcmp0(name, "setItems") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_LIST) {
      set_items(self, args);
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad-args", "setItems needs a list", nullptr));
    }
  } else if (g_strcmp0(name, "reset") == 0) {
    clear(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  if (response == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

NativeToolbarChannel* native_toolbar_channel_new(FlView* view,
                                                 GtkHeaderBar* bar,
                                                 const gchar* assets_path) {
  NativeToolbarChannel* self = g_new0(NativeToolbarChannel, 1);
  self->view = view;
  self->bar = bar;
  self->icons_dir =
      g_build_filename(assets_path, "assets", "icons", "gnome", nullptr);
  self->widgets =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, nullptr);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "stash_player/toolbar", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_cb, self,
                                            nullptr);
  return self;
}

void native_toolbar_channel_free(NativeToolbarChannel* self) {
  g_clear_object(&self->channel);
  g_clear_pointer(&self->widgets, g_hash_table_unref);
  g_clear_pointer(&self->signature, g_free);
  g_clear_pointer(&self->icons_dir, g_free);
  g_free(self);
}
```

- [ ] **Step 3: Wire it into `my_application.cc` and CMake**

Add `#include "native_toolbar_channel.h"`, a `NativeToolbarChannel* native_toolbar;` field in `struct _MyApplication`, and after the `window_channel_new` call:

```cpp
  self->native_toolbar = native_toolbar_channel_new(
      view, header_bar, fl_dart_project_get_assets_path(project));
```

In `my_application_dispose`:

```cpp
  g_clear_pointer(&self->native_toolbar, native_toolbar_channel_free);
```

Add `"native_toolbar_channel.cc"` to `CMakeLists.txt`'s `add_executable` list.

- [ ] **Step 4: Build**

Run: `just flutter-build`
Expected: builds cleanly under `-Wall -Werror`.

- [ ] **Step 5: Verify by hand**

Run `just flutter-run` and check:

1. The library shows one titlebar: the GTK header bar with the filter group, Play random, a centred search entry, Scan, Tasks and the main menu, drawn in the system GTK theme. No Flutter strip underneath.
2. Icons follow the theme's foreground colour in light and dark, and dim when Scan is disabled during a scan.
3. Sort and minimum rating open GTK menus; choosing an option refetches the grid and updates the button's label.
4. Direction, organized and hide-played change the grid; the toggles' pressed state matches the filter (organized: pressed for yes and for no, released for any).
5. Typing in the search entry filters after a short pause and never loses characters or focus. Escape clears it and returns the keyboard to the grid (arrow keys move the selection).
6. Tasks opens its popover under the Tasks button; its dot shows during a scan. The main menu opens under its button and Preferences opens the settings dialog.
7. Opening a scene hides the header bar; going back restores it with the controls and their state intact.
8. Hot restart (`R` in `flutter run`, via `FL flutter run -d linux`) leaves exactly one set of controls.

Fix anything that fails before committing.

- [ ] **Step 6: Commit**

```bash
git add apps/flutter/linux/runner
git commit -m "feat(flutter): native GTK toolbar in the Linux header bar"
```

---

### Task 7: Remaining checklist and docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `apps/flutter/README.md`
- Modify: `docs/superpowers/specs/2026-10-02-linux-immersive-window-design.md`

- [ ] **Step 1: Run the rest of the spec's manual checklist**

Each in light and dark; note results in the spec under "Spike outcome":

- Button layouts, set with `gsettings set org.gnome.desktop.wm.preferences button-layout '<value>'`: `appmenu:close`, `appmenu:minimize,maximize,close`, `close,minimize,maximize:appmenu`, and `:`. Restore the original value afterwards (read it first with `gsettings get`). Both the library header bar and the player's overlaid buttons must follow, live.
- GTK themes: Yaru and Adwaita.
- X11 under GNOME Shell.
- X11 under another window manager: WM title bar, Flutter-drawn strip, player unchanged from before this work.
- Flatpak: `nix run .#flatpak` then `flatpak run dev.arsfeld.stash-player`; icons load from the sandboxed bundle.

- [ ] **Step 2: Update `CLAUDE.md`**

In the Flutter client section:
- `lib/services/` bullet: add `channel_window_frame.dart` (`stash_player/window` method channel implementation), and say `channel_native_toolbar.dart` serves both runners.
- `lib/ui/` bullet: change the `toolbar/` description to "`NativeToolbar` port that macOS fills as an `NSToolbar` and Linux as the `GtkHeaderBar`, over a method channel", and add "`window/` (the `WindowFrame` port: hidden titlebar and overlaid window buttons for the player on Linux)".
- Native runners bullet: add that the Linux runner implements `stash_player/toolbar` (`native_toolbar_channel.cc`, the library's controls as GTK widgets in the header bar, icons painted from the bundled GNOME SVGs) and `stash_player/window` (`window_channel.cc`: while a scene is open the titlebar is hidden and a background-less header bar in a `GtkOverlay` draws the window buttons over the video), and that on X11 under a non-GNOME window manager both answer `unavailable` and the drawn strip is used.

- [ ] **Step 3: Update `apps/flutter/README.md`**

Add a short "Linux window chrome" subsection where the README describes platform behaviour, stating: one GTK header bar in the library with native controls; the player hides it and overlays GTK's window buttons; X11 under a non-GNOME WM keeps the WM title bar and the drawn strip.

- [ ] **Step 4: Final gate and commit**

Run: `just flutter-check`
Expected: all pass.

```bash
git add CLAUDE.md apps/flutter/README.md
git add -f docs/superpowers/specs/2026-10-02-linux-immersive-window-design.md
git commit -m "docs: Linux window chrome channels"
```
