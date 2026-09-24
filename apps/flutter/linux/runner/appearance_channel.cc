#include "appearance_channel.h"

#include <gio/gio.h>

struct _AppearanceChannel {
  FlEventChannel* channel;
  GDBusProxy* portal;
  GCancellable* cancellable;
  gboolean listening;
  // ARGB, or -1 while unknown or unset.
  gint64 accent;
  gchar* font_name;
};

static const gchar* kAppearanceNamespace = "org.freedesktop.appearance";
static const gchar* kInterfaceNamespace = "org.gnome.desktop.interface";

static void send_state(AppearanceChannel* self) {
  if (!self->listening) return;
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "accent",
                           self->accent >= 0 ? fl_value_new_int(self->accent)
                                             : fl_value_new_null());
  fl_value_set_string_take(event, "fontName",
                           self->font_name != nullptr
                               ? fl_value_new_string(self->font_name)
                               : fl_value_new_null());
  fl_event_channel_send(self->channel, event, nullptr, nullptr);
}

// The portal reports the accent as an sRGB (ddd) triple in [0, 1]. Any
// component outside that range means "no accent set", per the spec.
static gint64 accent_from_variant(GVariant* value) {
  if (value == nullptr ||
      !g_variant_is_of_type(value, G_VARIANT_TYPE("(ddd)"))) {
    return -1;
  }
  gdouble r, g, b;
  g_variant_get(value, "(ddd)", &r, &g, &b);
  if (r < 0 || r > 1 || g < 0 || g > 1 || b < 0 || b > 1) return -1;
  auto channel = [](gdouble c) { return static_cast<gint64>(c * 255 + 0.5); };
  return (static_cast<gint64>(0xFF) << 24) | (channel(r) << 16) |
         (channel(g) << 8) | channel(b);
}

static void apply_setting(AppearanceChannel* self, const gchar* ns,
                          const gchar* key, GVariant* value) {
  if (g_strcmp0(ns, kAppearanceNamespace) == 0 &&
      g_strcmp0(key, "accent-color") == 0) {
    self->accent = accent_from_variant(value);
    send_state(self);
  } else if (g_strcmp0(ns, kInterfaceNamespace) == 0 &&
             g_strcmp0(key, "font-name") == 0) {
    g_clear_pointer(&self->font_name, g_free);
    if (value != nullptr &&
        g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
      self->font_name = g_variant_dup_string(value, nullptr);
    }
    send_state(self);
  }
}

typedef struct {
  AppearanceChannel* self;
  gchar* ns;
  gchar* key;
} ReadRequest;

static void read_one_cb(GObject* source, GAsyncResult* result,
                        gpointer user_data) {
  ReadRequest* request = static_cast<ReadRequest*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_proxy_call_finish(G_DBUS_PROXY(source), result, &error);
  // A cancelled call means the channel was freed; `self` is gone.
  if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) &&
      reply != nullptr) {
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    apply_setting(request->self, request->ns, request->key, value);
  }
  g_free(request->ns);
  g_free(request->key);
  g_free(request);
}

static void read_one(AppearanceChannel* self, const gchar* ns,
                     const gchar* key) {
  ReadRequest* request = g_new0(ReadRequest, 1);
  request->self = self;
  request->ns = g_strdup(ns);
  request->key = g_strdup(key);
  g_dbus_proxy_call(self->portal, "ReadOne", g_variant_new("(ss)", ns, key),
                    G_DBUS_CALL_FLAGS_NONE, -1, self->cancellable,
                    read_one_cb, request);
}

static void portal_signal_cb(GDBusProxy* proxy, const gchar* sender,
                             const gchar* signal, GVariant* parameters,
                             gpointer user_data) {
  if (g_strcmp0(signal, "SettingChanged") != 0) return;
  const gchar* ns;
  const gchar* key;
  g_autoptr(GVariant) value = nullptr;
  g_variant_get(parameters, "(&s&sv)", &ns, &key, &value);
  apply_setting(static_cast<AppearanceChannel*>(user_data), ns, key, value);
}

static void portal_ready_cb(GObject* source, GAsyncResult* result,
                            gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  GDBusProxy* portal = g_dbus_proxy_new_for_bus_finish(result, &error);
  if (portal == nullptr) {
    if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
      g_warning("Settings portal unavailable: %s", error->message);
    }
    return;
  }
  AppearanceChannel* self = static_cast<AppearanceChannel*>(user_data);
  self->portal = portal;
  g_signal_connect(portal, "g-signal", G_CALLBACK(portal_signal_cb), self);
  read_one(self, kAppearanceNamespace, "accent-color");
  read_one(self, kInterfaceNamespace, "font-name");
}

static FlMethodErrorResponse* listen_cb(FlEventChannel* channel,
                                        FlValue* args, gpointer user_data) {
  AppearanceChannel* self = static_cast<AppearanceChannel*>(user_data);
  self->listening = TRUE;
  send_state(self);
  return nullptr;
}

static FlMethodErrorResponse* cancel_cb(FlEventChannel* channel,
                                        FlValue* args, gpointer user_data) {
  static_cast<AppearanceChannel*>(user_data)->listening = FALSE;
  return nullptr;
}

AppearanceChannel* appearance_channel_new(FlBinaryMessenger* messenger) {
  AppearanceChannel* self = g_new0(AppearanceChannel, 1);
  self->accent = -1;
  self->cancellable = g_cancellable_new();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_event_channel_new(messenger, "stash_player/appearance",
                                       FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->channel, listen_cb, cancel_cb,
                                       self, nullptr);
  g_dbus_proxy_new_for_bus(
      G_BUS_TYPE_SESSION, G_DBUS_PROXY_FLAGS_NONE, nullptr,
      "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.Settings", self->cancellable, portal_ready_cb,
      self);
  return self;
}

void appearance_channel_free(AppearanceChannel* self) {
  g_cancellable_cancel(self->cancellable);
  g_clear_object(&self->cancellable);
  if (self->portal != nullptr) {
    g_signal_handlers_disconnect_by_data(self->portal, self);
    g_clear_object(&self->portal);
  }
  g_clear_object(&self->channel);
  g_clear_pointer(&self->font_name, g_free);
  g_free(self);
}
