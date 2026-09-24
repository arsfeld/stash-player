import 'dart:convert';

import 'package:flutter/services.dart';

import '../shared/diagnostics.dart';
import '../ui/toolbar/app_toolbar.dart';
import '../ui/toolbar/native_toolbar.dart';

/// Shows [AppToolbar]s as the window's `NSToolbar` over the
/// `stash_player/toolbar` channel (`NativeToolbarChannel.swift`).
///
/// Only ids, labels, symbols and state cross the channel. Callbacks stay
/// here in an id → item table that each [set] replaces, so an event for
/// an item that has since gone runs nothing. A spec identical to the last
/// one sent is dropped, which lets a caller publish after every build.
///
/// If the native side is missing or fails, [set] reports false from then
/// on and logs once, and the caller draws its own controls.
class ChannelNativeToolbar implements NativeToolbar {
  ChannelNativeToolbar({
    MethodChannel channel = const MethodChannel('stash_player/toolbar'),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  Map<String, AppToolbarItem> _items = const {};
  String? _lastSent;
  bool _unavailable = false;

  /// Asks the runner to drop whatever a previous isolate left in the
  /// toolbar (a hot restart). Failures are ignored: [set] reports them.
  Future<void> reset() async {
    try {
      await _channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // No runner support: nothing to reset.
    } on PlatformException {
      // Same.
    }
  }

  @override
  Future<bool> set(AppToolbar toolbar) async {
    if (_unavailable) return false;
    final items = <String, AppToolbarItem>{};
    final encoded = [for (final item in toolbar.items) _encode(item, items)];
    _items = items;
    final fingerprint = jsonEncode(encoded);
    if (fingerprint == _lastSent) return true;
    try {
      await _channel.invokeMethod<void>('setItems', encoded);
      _lastSent = fingerprint;
      return true;
    } on Object catch (error) {
      if (error is! MissingPluginException && error is! PlatformException) {
        rethrow;
      }
      _unavailable = true;
      logDiagnostic('toolbar', 'native toolbar unavailable, drawing: $error');
      return false;
    }
  }

  Map<String, Object?> _encode(
    AppToolbarItem item,
    Map<String, AppToolbarItem> index,
  ) {
    index[item.id] = item;
    final base = <String, Object?>{
      'id': item.id,
      'label': item.label,
      'tooltip': item.tooltip ?? item.label,
    };
    return switch (item) {
      AppToolbarMenu() => {
        'type': 'menu',
        ...base,
        'options': item.options,
        'selected': item.selected,
      },
      AppToolbarToggle() => {
        'type': 'toggle',
        ...base,
        'symbol': item.icon.sfSymbol,
        'selected': item.selected,
      },
      AppToolbarAction() => {
        'type': 'action',
        ...base,
        'symbol': item.icon.sfSymbol,
        'enabled': item.onPressed != null,
        'badge': item.badge,
      },
      AppToolbarSearch() => {
        'type': 'search',
        ...base,
        'text': item.text,
        'placeholder': item.placeholder,
      },
      AppToolbarGroup() => {
        'type': 'group',
        ...base,
        'children': [for (final child in item.children) _encode(child, index)],
      },
      AppToolbarSpace() => {'type': 'space', 'id': item.id},
    };
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final item = _items[args['id']];
    switch ((call.method, item)) {
      case ('activated', AppToolbarAction(:final onPressed?)):
        onPressed(_rect(args['rect']));
      case ('activated', AppToolbarToggle(:final onPressed)):
        onPressed();
      case ('menuSelected', AppToolbarMenu(:final options, :final onSelected)):
        final index = args['index'];
        if (index is int && index >= 0 && index < options.length) {
          onSelected(index);
        }
      case ('searchChanged', AppToolbarSearch(:final onChanged)):
        final text = args['text'];
        if (text is String) onChanged(text);
      default:
        break;
    }
    return null;
  }

  static Rect? _rect(Object? value) {
    if (value is! Map) return null;
    double at(String key) => (value[key] as num?)?.toDouble() ?? 0;
    return Rect.fromLTWH(at('x'), at('y'), at('width'), at('height'));
  }
}
