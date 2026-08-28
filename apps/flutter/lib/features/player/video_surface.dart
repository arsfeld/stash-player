import 'package:flutter/material.dart';

import 'playback_controller.dart';

/// Renders the shared `PlaybackEngine`'s own video output, wrapped in a
/// black background so any letterboxing (a video whose aspect ratio
/// doesn't match the available space) reads as intentional, not a
/// rendering gap.
///
/// Deliberately ignorant of `package:media_kit`: [controller] hands back
/// whatever `PlaybackEngine.buildVideoSurface` (`playback_engine.dart`)
/// built, which for the real `MediaKitPlaybackEngine` is a `Video` widget
/// constructed entirely inside `lib/services/media_kit_playback_engine.dart`
/// — the only file (besides its own test) allowed to import that
/// package. This widget, `scene_screen.dart`, and `transport_controls.dart`
/// stay package-independent.
class VideoSurface extends StatelessWidget {
  const VideoSurface({required this.controller, super.key});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: controller.buildVideoSurface(key: const Key('player-video')),
  );
}
