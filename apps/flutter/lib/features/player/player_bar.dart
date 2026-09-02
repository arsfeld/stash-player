import 'package:flutter/material.dart';

import '../../shared/formatters.dart';
import '../../ui/theme/app_tokens.dart';
import 'playback_state.dart';
import 'player_icon_button.dart';

/// The scene-level controls' state: what prev/next and the O-counter
/// should show, decided by whoever owns the scene and handed to this bar
/// already resolved.
///
/// [oCount] is nullable on purpose. `null` means no scene is loaded, or
/// one is mid-navigation, and the O-counter renders dead. A real `0`
/// means a loaded scene nobody has counted yet, which is a state the
/// user can act on. Collapsing the two would either offer to count a
/// scene that is not there, or hide a control that works.
class SceneActionState {
  const SceneActionState({
    this.canGoPrevious = false,
    this.canGoNext = false,
    this.oCount,
  });

  final bool canGoPrevious;
  final bool canGoNext;
  final int? oCount;
}

/// The scene screen's transport: one rounded translucent panel inset from
/// the video's bottom, left and right edges, so the picture's corners stay
/// clean.
///
/// Two lines. The upper one is elapsed time, the scrubber and duration.
/// The lower one is three groups in one row: volume leading, the
/// transport (prev, back 10, play/pause, forward 10, next) centred, and
/// the O-counter trailing.
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
    required this.onPrevious,
    required this.onNext,
    required this.onSkipBackward,
    required this.onSkipForward,
    required this.onIncrementO,
    required this.onResetO,
    this.actions = const SceneActionState(),
    super.key,
  });

  final PlaybackState playback;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final SceneActionState actions;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onSkipBackward;
  final VoidCallback onSkipForward;
  final VoidCallback onIncrementO;
  final VoidCallback onResetO;

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
    final actions = widget.actions;
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
                  Expanded(
                    // `FittedBox` rather than a bare centred `Row`: at a
                    // narrow window (the metadata drawer's own width
                    // tests go down to 300px) five buttons plus the
                    // volume control and O-counter no longer fit their
                    // natural size. Scaling the cluster down keeps it
                    // whole and centred instead of overflowing the panel.
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PlayerIconButton(
                              icon: Icons.skip_previous,
                              tooltip: 'Previous scene',
                              onPressed: actions.canGoPrevious
                                  ? widget.onPrevious
                                  : null,
                            ),
                            const SizedBox(width: AppTokens.space2),
                            PlayerIconButton(
                              icon: Icons.replay_10,
                              tooltip: 'Back 10 seconds',
                              onPressed: widget.onSkipBackward,
                            ),
                            const SizedBox(width: AppTokens.space2),
                            PlayerIconButton(
                              icon: playback.playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              tooltip: playback.playing ? 'Pause' : 'Play',
                              filled: true,
                              onPressed: widget.onTogglePlayPause,
                            ),
                            const SizedBox(width: AppTokens.space2),
                            PlayerIconButton(
                              icon: Icons.forward_10,
                              tooltip: 'Forward 10 seconds',
                              onPressed: widget.onSkipForward,
                            ),
                            const SizedBox(width: AppTokens.space2),
                            PlayerIconButton(
                              icon: Icons.skip_next,
                              tooltip: 'Next scene',
                              onPressed: actions.canGoNext
                                  ? widget.onNext
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _OCounterGroup(
                    count: actions.oCount,
                    onIncrement: widget.onIncrementO,
                    onReset: widget.onResetO,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The O-counter: a button showing the current count, and a reset button
/// that appears only once there is something to reset.
///
/// A `null` [count] renders the group dead rather than hiding it, so the
/// bar does not reflow every time a prev/next fetch is in flight.
class _OCounterGroup extends StatelessWidget {
  const _OCounterGroup({
    required this.count,
    required this.onIncrement,
    required this.onReset,
  });

  final int? count;
  final VoidCallback onIncrement;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final enabled = count != null;
    final glyph = AppTokens.playerText.withValues(alpha: enabled ? 1 : 0.38);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Bump O-counter',
          child: Semantics(
            button: true,
            label: 'Bump O-counter',
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: enabled ? onIncrement : null,
                borderRadius: BorderRadius.circular(AppTokens.radiusControl),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.space2,
                    vertical: AppTokens.space1,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.water_drop_outlined, size: 15, color: glyph),
                      const SizedBox(width: AppTokens.space1),
                      Text(
                        '${count ?? 0}',
                        style: TextStyle(
                          color: glyph,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (enabled && count! > 0) ...[
          const SizedBox(width: AppTokens.space1),
          PlayerIconButton(
            icon: Icons.backspace_outlined,
            tooltip: 'Reset O-counter to 0',
            onPressed: onReset,
          ),
        ],
      ],
    );
  }
}
