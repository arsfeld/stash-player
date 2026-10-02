import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../shared/diagnostics.dart';
import '../ui/window/window_frame.dart';

/// Drives the Linux runner's window chrome over `stash_player/window`
/// (`window_channel.cc`).
///
/// If the native side is missing or answers with an error (it answers
/// `unavailable` when the window manager draws the title bar), every
/// later call is a no-op, [insets] stays zero, and it logs once.
class ChannelWindowFrame implements WindowFrame {
  ChannelWindowFrame({
    MethodChannel channel = const MethodChannel('stash_player/window'),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final _insets = ValueNotifier(WindowButtonInsets.zero);
  final _controlsHovered = ValueNotifier(false);
  bool _unavailable = false;

  @override
  ValueListenable<WindowButtonInsets> get insets => _insets;

  @override
  ValueListenable<bool> get controlsHovered => _controlsHovered;

  /// Asks the runner to drop whatever a previous isolate left behind (a
  /// hot restart while a scene was open).
  Future<void> reset() => _invoke('reset');

  @override
  Future<void> setImmersive(bool immersive) =>
      _invoke('setImmersive', immersive);

  @override
  Future<void> setControlsVisible(bool visible) =>
      _invoke('setControlsVisible', visible);

  @override
  Future<void> startDrag() => _invoke('startDrag');

  Future<void> _invoke(String method, [Object? argument]) async {
    if (_unavailable) return;
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on MissingPluginException catch (error) {
      _disable(error);
    } on PlatformException catch (error) {
      _disable(error);
    }
  }

  void _disable(Object error) {
    if (_unavailable) return;
    _unavailable = true;
    _insets.value = WindowButtonInsets.zero;
    _controlsHovered.value = false;
    logDiagnostic('window', 'native window frame unavailable: $error');
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_unavailable) return null;
    final args = call.arguments;
    switch (call.method) {
      case 'insetsChanged' when args is Map:
        _insets.value = WindowButtonInsets(
          leading: (args['leading'] as num?)?.toDouble() ?? 0,
          trailing: (args['trailing'] as num?)?.toDouble() ?? 0,
        );
      case 'controlsHovered' when args is bool:
        _controlsHovered.value = args;
    }
    return null;
  }
}
