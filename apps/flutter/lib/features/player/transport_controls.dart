import 'package:flutter/material.dart';

import '../../shared/formatters.dart';
import 'playback_state.dart';

/// The bottom-docked chrome for the video-first scene screen: a top strip
/// (back, title, metadata toggle) and a transport strip (seek bar,
/// play/pause, volume/mute, fullscreen) beneath it — one composite layer
/// so `SceneScreen`'s auto-hide `Stack` entry can treat "the controls" as
/// a single unit (see that file's own doc for the layering).
///
/// Purely presentational: every field is an immutable [PlaybackState] (or
/// a plain value) plus callbacks — this widget never touches a
/// `PlaybackController` or any Riverpod provider directly, matching the
/// "widgets consume immutable typed state and forward intents only" rule.
///
/// Stateful only for the seek bar's local drag position (see
/// [_TransportControlsState._dragValueSeconds]) — everything else is still
/// driven straight from [playback].
class TransportControls extends StatefulWidget {
  const TransportControls({
    required this.playback,
    required this.title,
    required this.metadataOpen,
    required this.onBack,
    required this.onTogglePlayPause,
    required this.onSeek,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onToggleMetadata,
    super.key,
  });

  final PlaybackState playback;
  final String title;
  final bool metadataOpen;
  final VoidCallback onBack;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleMetadata;

  @override
  State<TransportControls> createState() => _TransportControlsState();
}

class _TransportControlsState extends State<TransportControls> {
  static const _textStyle = TextStyle(color: Colors.white);

  /// Seek-bar thumb position while a drag is in progress, in seconds.
  /// `null` when the user isn't dragging, in which case the slider tracks
  /// [PlaybackState.position] directly. Committing a `sceneSaveActivity`
  /// mutation on every `Slider.onChanged` sample turned a single drag
  /// gesture into dozens of GraphQL POSTs against the user's server (final
  /// review I2) — tracking the drag locally and calling [onSeek] only from
  /// `onChangeEnd` fires exactly one seek per gesture, and this local value
  /// also stops the thumb from snapping back to the stale pre-seek
  /// position between samples.
  double? _dragValueSeconds;

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final durationSeconds = playback.duration.inMilliseconds / 1000;
    final actualPositionSeconds = playback.position.inMilliseconds / 1000;
    final hasKnownDuration = playback.duration > Duration.zero;
    final sliderMax = hasKnownDuration ? durationSeconds : 1.0;
    final positionSeconds = (_dragValueSeconds ?? actualPositionSeconds).clamp(
      0.0,
      sliderMax,
    );
    final sliderValue = positionSeconds;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent, Colors.black87],
          stops: [0, 0.35, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Tooltip(
                  message: 'Back to library',
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: widget.onBack,
                  ),
                ),
                Expanded(
                  child: Text(
                    widget.title,
                    style: _textStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Tooltip(
                  message: widget.metadataOpen
                      ? 'Hide details'
                      : 'Show details',
                  child: IconButton(
                    icon: const Icon(Icons.info_outline, color: Colors.white),
                    onPressed: widget.onToggleMetadata,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 12),
                Semantics(
                  label: 'Elapsed time',
                  child: Text(
                    formatDuration(positionSeconds),
                    style: _textStyle,
                  ),
                ),
                Expanded(
                  child: Tooltip(
                    message: 'Seek',
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.white,
                        thumbColor: Colors.white,
                        inactiveTrackColor: Colors.white30,
                      ),
                      child: Slider(
                        key: const Key('scene-seek-bar'),
                        value: sliderValue,
                        max: sliderMax,
                        label: formatDuration(positionSeconds),
                        onChanged: hasKnownDuration
                            ? (value) => setState(() {
                                _dragValueSeconds = value;
                              })
                            : null,
                        onChangeEnd: hasKnownDuration
                            ? (value) {
                                widget.onSeek(
                                  Duration(
                                    milliseconds: (value * 1000).round(),
                                  ),
                                );
                                setState(() {
                                  _dragValueSeconds = null;
                                });
                              }
                            : null,
                      ),
                    ),
                  ),
                ),
                Semantics(
                  label: 'Duration',
                  child: Text(
                    formatDuration(durationSeconds),
                    style: _textStyle,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 4),
                Tooltip(
                  message: playback.playing ? 'Pause' : 'Play',
                  child: IconButton(
                    icon: Icon(
                      playback.playing ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: widget.onTogglePlayPause,
                  ),
                ),
                Tooltip(
                  message: playback.muted ? 'Unmute' : 'Mute',
                  child: IconButton(
                    icon: Icon(
                      playback.muted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white,
                    ),
                    onPressed: widget.onToggleMute,
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Tooltip(
                    message: 'Volume',
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.white,
                        thumbColor: Colors.white,
                        inactiveTrackColor: Colors.white30,
                      ),
                      child: Slider(
                        key: const Key('scene-volume-slider'),
                        value: playback.volume.clamp(0.0, 1.0),
                        onChanged: widget.onVolumeChanged,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                // Fullscreen has no real platform implementation on any
                // target yet (final review C4) — disabled rather than
                // shipping a control that flips its icon and claims a
                // window state the OS was never asked for. The `F`/Escape
                // shortcuts stay wired in `PlayerActionShortcuts`: they
                // route through `PlaybackController.setFullscreen`, whose
                // `FullscreenRequester` now reports failure, so those
                // bindings already no-op safely without special-casing
                // them here too.
                Tooltip(
                  message: 'Fullscreen (not yet implemented)',
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen, color: Colors.white38),
                    onPressed: null,
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
