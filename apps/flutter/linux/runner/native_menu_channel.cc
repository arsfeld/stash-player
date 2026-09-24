#include "native_menu_channel.h"

#include <gtk/gtk.h>

struct _NativeMenuChannel {
  FlMethodChannel* channel;
  FlView* view;
};

// One open menu: the pending call it answers and the item chosen so far.
typedef struct {
  FlMethodCall* call;
  GtkWidget* menu;
  gint64 chosen;
  gboolean answered;
} MenuSession;

static const gchar* kIdKey = "stash-player-menu-id";

static gboolean answer_idle(gpointer user_data) {
  MenuSession* session = static_cast<MenuSession*>(user_data);
  g_autoptr(FlValue) value = session->chosen >= 0
                                 ? fl_value_new_int(session->chosen)
                                 : fl_value_new_null();
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(session->call, response, nullptr);
  g_object_unref(session->call);
  gtk_widget_destroy(session->menu);
  g_object_unref(session->menu);
  g_free(session);
  return G_SOURCE_REMOVE;
}

static void item_activate_cb(GtkMenuItem* item, gpointer user_data) {
  static_cast<MenuSession*>(user_data)->chosen =
      GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), kIdKey));
}

// GTK emits the menu's "deactivate" before the chosen item's "activate"
// (gtk_menu_shell_activate_item deactivates first), so the answer is sent
// from an idle callback, after both have run.
static void menu_deactivate_cb(GtkMenuShell* shell, gpointer user_data) {
  MenuSession* session = static_cast<MenuSession*>(user_data);
  if (session->answered) return;
  session->answered = TRUE;
  g_idle_add(answer_idle, session);
}

static void respond_error(FlMethodCall* call, const gchar* code,
                          const gchar* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}

static gdouble lookup_double(FlValue* map, const gchar* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT
             ? fl_value_get_float(value)
             : 0;
}

static GtkWidget* build_item(FlValue* item, MenuSession* session) {
  FlValue* type = fl_value_lookup_string(item, "type");
  if (type != nullptr && g_strcmp0(fl_value_get_string(type), "separator") == 0) {
    return gtk_separator_menu_item_new();
  }
  FlValue* label = fl_value_lookup_string(item, "label");
  const gchar* text = label != nullptr ? fl_value_get_string(label) : "";
  FlValue* checked = fl_value_lookup_string(item, "checked");
  GtkWidget* widget;
  if (checked != nullptr && fl_value_get_type(checked) == FL_VALUE_TYPE_BOOL) {
    widget = gtk_check_menu_item_new_with_label(text);
    // Before "activate" is connected: set_active emits it.
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(widget),
                                   fl_value_get_bool(checked));
  } else {
    widget = gtk_menu_item_new_with_label(text);
  }
  FlValue* enabled = fl_value_lookup_string(item, "enabled");
  gtk_widget_set_sensitive(widget,
                           enabled == nullptr || fl_value_get_bool(enabled));
  FlValue* id = fl_value_lookup_string(item, "id");
  g_object_set_data(G_OBJECT(widget), kIdKey,
                    GINT_TO_POINTER(id != nullptr ? fl_value_get_int(id) : -1));
  g_signal_connect(widget, "activate", G_CALLBACK(item_activate_cb), session);
  return widget;
}

static void show_menu(NativeMenuChannel* self, FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  FlValue* anchor = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                        ? fl_value_lookup_string(args, "anchor")
                        : nullptr;
  FlValue* items = anchor != nullptr ? fl_value_lookup_string(args, "items")
                                     : nullptr;
  if (items == nullptr || fl_value_get_type(items) != FL_VALUE_TYPE_LIST) {
    respond_error(call, "bad-args", "show needs anchor and items");
    return;
  }
  GtkWidget* view = GTK_WIDGET(self->view);
  GdkWindow* window = gtk_widget_get_window(view);
  if (window == nullptr) {
    respond_error(call, "no-window", "the Flutter view is not realized");
    return;
  }

  MenuSession* session = g_new0(MenuSession, 1);
  session->call = FL_METHOD_CALL(g_object_ref(call));
  session->chosen = -1;
  session->menu = GTK_WIDGET(g_object_ref_sink(gtk_menu_new()));
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    GtkWidget* widget = build_item(fl_value_get_list_value(items, i), session);
    gtk_widget_show(widget);
    gtk_menu_shell_append(GTK_MENU_SHELL(session->menu), widget);
  }
  gulong deactivate_id = g_signal_connect(
      session->menu, "deactivate", G_CALLBACK(menu_deactivate_cb), session);
  gtk_menu_attach_to_widget(GTK_MENU(session->menu), view, nullptr);

  // A no-window widget draws into its parent's GdkWindow, where its own
  // origin is its allocation's; a widget with its own window is at 0,0.
  gint origin_x = 0, origin_y = 0;
  if (!gtk_widget_get_has_window(view)) {
    GtkAllocation allocation;
    gtk_widget_get_allocation(view, &allocation);
    origin_x = allocation.x;
    origin_y = allocation.y;
  }
  GdkRectangle rect = {
      origin_x + static_cast<gint>(lookup_double(anchor, "x")),
      origin_y + static_cast<gint>(lookup_double(anchor, "y")),
      MAX(1, static_cast<gint>(lookup_double(anchor, "width"))),
      MAX(1, static_cast<gint>(lookup_double(anchor, "height"))),
  };
  // gtk_menu_popup_at_rect needs a real event to take the pointer/keyboard
  // grab it opens with. Called from a platform-channel handler there is no
  // current GDK event for it to fall back on (gtk_get_current_event()
  // returns null here, which would otherwise make it warn and still try
  // the grab with a null event), so one is synthesized: a button-press on
  // the view's own window, timestamped now, attributed to the default
  // seat's pointer.
  GdkEvent* trigger_event = gdk_event_new(GDK_BUTTON_PRESS);
  trigger_event->button.window = GDK_WINDOW(g_object_ref(window));
  trigger_event->button.time = GDK_CURRENT_TIME;
  GdkSeat* seat = gdk_display_get_default_seat(gdk_window_get_display(window));
  if (seat != nullptr) {
    gdk_event_set_device(trigger_event, gdk_seat_get_pointer(seat));
  }
  gtk_menu_popup_at_rect(GTK_MENU(session->menu), window, &rect,
                         GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST,
                         trigger_event);
  gdk_event_free(trigger_event);

  // If GTK couldn't take the grab the popup needs (another surface already
  // holds it, for instance), gtk_menu_popup_at_rect returns without ever
  // showing the menu or emitting "deactivate", so menu_deactivate_cb would
  // never run and the pending call (and whatever the Dart side is holding
  // open while it awaits the reply, e.g. the player bar staying pinned
  // visible) would hang forever. Answer with an error instead:
  // ChannelNativeMenus turns any PlatformException into its DrawnMenus
  // fallback, so the user still gets a menu.
  if (!session->answered && !gtk_widget_get_visible(session->menu)) {
    g_signal_handler_disconnect(session->menu, deactivate_id);
    respond_error(call, "popup-failed", "the menu failed to open");
    g_object_unref(session->call);
    gtk_widget_destroy(session->menu);
    g_object_unref(session->menu);
    g_free(session);
  }
}

static void method_cb(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(call), "show") == 0) {
    show_menu(static_cast<NativeMenuChannel*>(user_data), call);
    return;
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}

NativeMenuChannel* native_menu_channel_new(FlView* view) {
  NativeMenuChannel* self = g_new0(NativeMenuChannel, 1);
  self->view = view;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "stash_player/menu", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_cb, self,
                                            nullptr);
  return self;
}

void native_menu_channel_free(NativeMenuChannel* self) {
  g_clear_object(&self->channel);
  g_free(self);
}
