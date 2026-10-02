#include "window_channel.h"

struct _WindowChannel {
  FlMethodChannel* channel;
  // Borrowed: only used from method handlers, while the window is alive.
  FlView* view;
  GtkWindow* window;
  // Null when the window manager draws the title bar.
  GtkWidget* titlebar;
  // The overlaid header bar that carries only the window buttons.
  GtkWidget* controls;
  gboolean immersive;
  gboolean controls_visible;
  gint leading;
  gint trailing;
  // The window button the pointer is over, or null. Not owned: cleared
  // when that button is unmapped or destroyed.
  GtkWidget* hovered_button;
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
  g_autoptr(FlValue) value = fl_value_new_bool(self->hovered_button != nullptr);
  fl_method_channel_invoke_method(self->channel, "controlsHovered", value,
                                  nullptr, nullptr, nullptr);
}

static void clear_hovered(WindowChannel* self, GtkWidget* button) {
  if (self->hovered_button != button) return;
  self->hovered_button = nullptr;
  send_hovered(self);
}

static gboolean button_enter_cb(GtkWidget* widget, GdkEventCrossing* event,
                                gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  gboolean was_hovered = self->hovered_button != nullptr;
  self->hovered_button = widget;
  if (!was_hovered) send_hovered(self);
  return GDK_EVENT_PROPAGATE;
}

static gboolean button_leave_cb(GtkWidget* widget, GdkEventCrossing* event,
                                gpointer user_data) {
  WindowChannel* self = static_cast<WindowChannel*>(user_data);
  clear_hovered(self, widget);
  return GDK_EVENT_PROPAGATE;
}

// A hovered button that goes away (GtkHeaderBar rebuilds its button boxes,
// or the bar is hidden) gets no leave event.
static void button_gone_cb(GtkWidget* widget, gpointer user_data) {
  clear_hovered(static_cast<WindowChannel*>(user_data), widget);
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
  g_signal_connect(button, "unmap", G_CALLBACK(button_gone_cb), user_data);
  g_signal_connect(button, "destroy", G_CALLBACK(button_gone_cb), user_data);
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
    // Hiding a bar that holds GTK focus (the search entry) leaves the window
    // with none, and the Flutter view only gets keys while it is focused.
    gtk_widget_grab_focus(GTK_WIDGET(self->view));
    // A hidden titlebar takes no height, and GTK keeps the window
    // client-side decorated: shadows and resize edges stay.
    gtk_widget_hide(self->titlebar);
    gtk_widget_show(self->controls);
  } else {
    gtk_widget_hide(self->controls);
    gtk_widget_show(self->titlebar);
    set_insets(self, 0, 0);
    if (self->hovered_button != nullptr) {
      self->hovered_button = nullptr;
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

  // The channel keeps its own reference: the window (and so the overlay)
  // is destroyed before the application disposes of the channel.
  g_object_ref_sink(controls);
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
  self->view = view;
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
    // Destroying the bar destroys its buttons, which carry handlers with
    // `self` as data; they must be gone before `self` is.
    gtk_widget_destroy(self->controls);
    g_clear_object(&self->controls);
  }
  g_clear_object(&self->channel);
  g_free(self);
}
