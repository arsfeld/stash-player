import 'package:flutter/foundation.dart';
import 'package:stash_player_flutter/ui/window/window_frame.dart';

/// A [WindowFrame] that records every call as `'<method> <argument>'`
/// and lets a test move [insets] and [controlsHovered] by hand.
class RecordingWindowFrame implements WindowFrame {
  final List<String> calls = [];

  @override
  final ValueNotifier<WindowButtonInsets> insets = ValueNotifier(
    WindowButtonInsets.zero,
  );

  @override
  final ValueNotifier<bool> controlsHovered = ValueNotifier(false);

  @override
  Future<void> setImmersive(bool immersive) async =>
      calls.add('setImmersive $immersive');

  @override
  Future<void> setControlsVisible(bool visible) async =>
      calls.add('setControlsVisible $visible');

  @override
  Future<void> startDrag() async => calls.add('startDrag');
}
