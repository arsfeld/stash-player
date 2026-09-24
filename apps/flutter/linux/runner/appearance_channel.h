#ifndef RUNNER_APPEARANCE_CHANNEL_H_
#define RUNNER_APPEARANCE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Streams the desktop's accent colour and UI font to Dart on
// `stash_player/appearance`, read from the XDG settings portal
// (org.freedesktop.appearance accent-color, org.gnome.desktop.interface
// font-name). The portal is reachable from inside the Flatpak sandbox
// without any extra permission.
typedef struct _AppearanceChannel AppearanceChannel;

AppearanceChannel* appearance_channel_new(FlBinaryMessenger* messenger);
void appearance_channel_free(AppearanceChannel* self);

#endif  // RUNNER_APPEARANCE_CHANNEL_H_
