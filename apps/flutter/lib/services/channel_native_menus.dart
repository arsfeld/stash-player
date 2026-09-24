import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../shared/diagnostics.dart';
import '../ui/menu/app_menu.dart';
import '../ui/menu/drawn_menus.dart';
import '../ui/menu/native_menus.dart';

/// Shows [AppMenu]s as the platform's own popup menus over the
/// `stash_player/menu` channel: an `NSMenu` on macOS
/// (`NativeMenuChannel` in `MainFlutterWindow.swift`) and a `GtkMenu` on
/// Linux (`native_menu_channel.cc`).
///
/// Only labels and state cross the channel. Each action gets an id that
/// is local to one [show] call, and its callback stays here, so a late or
/// stale reply can never run an action from a different menu.
///
/// If the native side is missing or fails, the menu is shown by
/// [fallback] instead and the failure is logged once per session.
class ChannelNativeMenus implements NativeMenus {
  ChannelNativeMenus({
    MethodChannel channel = const MethodChannel('stash_player/menu'),
    NativeMenus fallback = const DrawnMenus(),
  }) : _channel = channel,
       _fallback = fallback;

  final MethodChannel _channel;
  final NativeMenus _fallback;
  bool _loggedFallback = false;

  @override
  Future<void> show(BuildContext context, AppMenu menu, Rect anchor) async {
    final actions = <int, AppMenuAction>{};
    final items = <Map<String, Object?>>[];
    for (final entry in menu.entries) {
      switch (entry) {
        case AppMenuSeparator():
          items.add({'type': 'separator'});
        case AppMenuAction():
          final id = actions.length;
          actions[id] = entry;
          items.add({
            'type': 'action',
            'id': id,
            'label': entry.label,
            'enabled': entry.enabled,
            'checked': entry.checked,
          });
      }
    }

    final int? chosen;
    try {
      chosen = await _channel.invokeMethod<int>('show', {
        'anchor': {
          'x': anchor.left,
          'y': anchor.top,
          'width': anchor.width,
          'height': anchor.height,
        },
        'items': items,
      });
    } on Object catch (error) {
      if (error is! MissingPluginException && error is! PlatformException) {
        rethrow;
      }
      if (!_loggedFallback) {
        _loggedFallback = true;
        logDiagnostic('menus', 'native menus unavailable, drawing: $error');
      }
      if (!context.mounted) return;
      return _fallback.show(context, menu, anchor);
    }
    if (chosen != null) actions[chosen]?.onSelected();
  }
}
