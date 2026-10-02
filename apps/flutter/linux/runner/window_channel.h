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
