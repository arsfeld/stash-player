import 'package:flutter/material.dart';

import '../../shared/formatters.dart';
import '../../ui/theme/app_tokens.dart';
import 'playback_state.dart';
import 'player_icon_button.dart';

/// The scene screen's transport: one rounded translucent panel inset from
/// the video's bottom, left and right edges, so the picture's corners stay
/// clean.
///
/// Two lines. The upper one is elapsed time, the scrubber and duration.
/// The lower one is play/pause as a filled circle, then volume. Prev/next
/// would flank play/pause and rating and the O-counter would sit at the
/// trailing edge; none of them exist in this client, so today they render
/// nothing and take no space.
///
/// Purely presentational: every field is an immutable [PlaybackState] or a
/// callback. This widget never touches a controller or a provider.
///
/// Stateful only for the scrubber's local drag position: committing a
/// seek on every `onChanged` sample turns one drag gesture into dozens of
/// GraphQL writes, so the thumb is tracked here and [PlayerBar.onSeek]
/// fires exactly once, from `onChangeEnd`. Tracking it locally also stops
/// the thumb snapping back to the stale pre-seek position between samples.
class PlayerBar extends StatefulWidget {
  const PlayerBar({
    required this.playback,
    required this.onTogglePlayPause,
    required this.onSeek,
    required this.onVolumeChanged,
    required this.onToggleMute,
    super.key,
  });

  final PlaybackState playback;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  static const _timeStyle = TextStyle(
    color: AppTokens.playerText,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Thumb position while a drag is in progress, in seconds. `null` when
  /// the user is not dragging, in which case the slider tracks
  /// [PlaybackState.position] directly.
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

    return Padding(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTokens.playerPanel,
          borderRadius: BorderRadius.circular(AppTokens.radiusPlayerBar),
          border: Border.all(color: AppTokens.playerHairline),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space3,
            AppTokens.space3,
            AppTokens.space3,
            AppTokens.space2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Semantics(
                    label: 'Elapsed time',
                    child: Text(
                      formatDuration(positionSeconds),
                      style: _timeStyle,
                    ),
                  ),
                  Expanded(
                    child: Tooltip(
                      message: 'Seek',
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppTokens.playerText,
                          thumbColor: AppTokens.playerText,
                          inactiveTrackColor: AppTokens.playerTrack,
                        ),
                        child: Slider(
                          key: const Key('scene-seek-bar'),
                          value: positionSeconds,
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
                      style: _timeStyle.copyWith(
                        color: AppTokens.playerTextDim,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.space2),
              Row(
                children: [
                  PlayerIconButton(
                    icon: playback.playing ? Icons.pause : Icons.play_arrow,
                    tooltip: playback.playing ? 'Pause' : 'Play',
                    filled: true,
                    onPressed: widget.onTogglePlayPause,
                  ),
                  const SizedBox(width: AppTokens.space3),
                  PlayerIconButton(
                    icon: playback.muted ? Icons.volume_off : Icons.volume_up,
                    tooltip: playback.muted ? 'Unmute' : 'Mute',
                    onPressed: widget.onToggleMute,
                  ),
                  SizedBox(
                    width: 96,
                    child: Tooltip(
                      message: 'Volume',
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppTokens.playerText,
                          thumbColor: AppTokens.playerText,
                          inactiveTrackColor: AppTokens.playerTrack,
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
