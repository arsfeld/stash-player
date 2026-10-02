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
static const gchar* kTextKey = "stash-player-toolbar-text";

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
  // search-changed fires from a timeout, after `applying` is back to false,
  // so a text Dart itself set would echo back. Skip text we already know.
  const gchar* text = gtk_entry_get_text(GTK_ENTRY(entry));
  const gchar* known =
      static_cast<const gchar*>(g_object_get_data(G_OBJECT(entry), kTextKey));
  if (g_strcmp0(known != nullptr ? known : "", text) == 0) return;
  g_object_set_data_full(G_OBJECT(entry), kTextKey, g_strdup(text), g_free);
  g_autoptr(FlValue) args = event_for(G_OBJECT(entry));
  fl_value_set_string_take(args, "text", fl_value_new_string(text));
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
  // Destroy from a copy of the child list, not while iterating the bar.
  GList* children = gtk_container_get_children(GTK_CONTAINER(self->bar));
  g_list_foreach(children, reinterpret_cast<GFunc>(destroy_cb), nullptr);
  g_list_free(children);
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
      g_object_set_data_full(G_OBJECT(widget), kTextKey,
                             g_strdup(text_of(item, "text")), g_free);
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
