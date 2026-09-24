#ifndef RUNNER_NATIVE_MENU_CHANNEL_H_
#define RUNNER_NATIVE_MENU_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Shows the menus Dart describes on `stash_player/menu` as GtkMenu popups
// anchored in [view], and answers with the chosen item's id (null when
// dismissed). A GtkMenu opens as its own popup surface (an xdg_popup on
// Wayland), so it composes over the Flutter view.
//
// Errors: `bad-args` (the call was missing `anchor`/`items`), `no-window`
// (the view isn't realized yet), `popup-failed` (GTK couldn't open the
// popup, e.g. it lost the pointer/keyboard grab race).
typedef struct _NativeMenuChannel NativeMenuChannel;

NativeMenuChannel* native_menu_channel_new(FlView* view);
void native_menu_channel_free(NativeMenuChannel* self);

#endif  // RUNNER_NATIVE_MENU_CHANNEL_H_
