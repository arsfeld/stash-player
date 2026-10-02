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
