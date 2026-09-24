#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <libsecret/secret.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "appearance_channel.h"
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* legacy_secret_channel;
  AppearanceChannel* appearance_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The Secret Service item the legacy GTK client (Rust `secret-service`
// crate) wrote. That crate sets no `xdg:schema` attribute, so the lookup
// must not match on the schema name.
static const SecretSchema* legacy_secret_schema() {
  static const SecretSchema schema = {
      "dev.arsfeld.stash-player.Legacy",
      SECRET_SCHEMA_DONT_MATCH_NAME,
      {
          {"application", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {"key", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING},
      }};
  return &schema;
}

// Reads the legacy key from the Secret Service over D-Bus: the key, null
// (with `error` unset) when there is none, or null with `error` set. The
// caller frees the result with g_free.
//
// Deliberately the D-Bus SecretService API, not secret_password_*: those
// go through libsecret's backend layer, which inside a Flatpak with the
// org.freedesktop.portal.Secret portal available picks the *file* backend
// (a per-app keyring under ~/.var/app/<id>/data/keyrings/), whatever
// --talk-name=org.freedesktop.secrets grants. The legacy GTK client wrote
// its key to the host Secret Service over D-Bus, so only this path finds it.
static gchar* lookup_legacy_api_key(GError** error) {
  g_autoptr(SecretService) service =
      secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, nullptr, error);
  if (service == nullptr) return nullptr;

  g_autoptr(GHashTable) attributes =
      g_hash_table_new(g_str_hash, g_str_equal);
  g_hash_table_insert(attributes, const_cast<gchar*>("application"),
                      const_cast<gchar*>("stash-player"));
  g_hash_table_insert(attributes, const_cast<gchar*>("key"),
                      const_cast<gchar*>("stash-api-key"));

  SecretValue* value = secret_service_lookup_sync(
      service, legacy_secret_schema(), attributes, nullptr, error);
  if (value == nullptr) return nullptr;
  const gchar* text = secret_value_get_text(value);
  gchar* result = text != nullptr ? g_strdup(text) : nullptr;
  if (text == nullptr) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                        "the legacy API key is not valid UTF-8");
  }
  secret_value_unref(value);
  return result;
}

// Handles `readApiKey` on `stash_player/legacy_secret`: the stored key, null
// when there is none, or a `lookup-failed` error. Synchronous because it
// runs at most once per install (see PlatformConnectionStore) and the
// connection screen can't render meaningfully before it answers anyway.
static void legacy_secret_method_cb(FlMethodChannel* channel,
                                    FlMethodCall* method_call,
                                    gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "readApiKey") == 0) {
    g_autoptr(GError) error = nullptr;
    g_autofree gchar* secret = lookup_legacy_api_key(&error);
    if (error != nullptr) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("lookup-failed", error->message, nullptr));
    } else {
      g_autoptr(FlValue) value = secret != nullptr ? fl_value_new_string(secret)
                                                   : fl_value_new_null();
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Stash Player");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Stash Player");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->legacy_secret_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "stash_player/legacy_secret", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->legacy_secret_channel, legacy_secret_method_cb, nullptr, nullptr);

  self->appearance_channel = appearance_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->legacy_secret_channel);
  g_clear_pointer(&self->appearance_channel, appearance_channel_free);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
