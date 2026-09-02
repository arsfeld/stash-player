import 'package:flutter/material.dart';

import '../../shared/formatters.dart';
import '../../ui/theme/app_tokens.dart';
import 'playback_state.dart';
import 'player_icon_button.dart';

// The three breakpoints below are all measured against the same fixed
// baseline: the mute button (28) plus the five-button transport cluster
// (four 8px gaps plus one filled play/pause button at 34 instead of 28,
// which never shrinks or drops at any width) is 206. Every width below
// comes from `tester.getSize` against the real rendered widgets, not a
// guess, using a representative two-digit O-count (e.g. "12") for the
// O-counter's own variable digit width: its bump button (icon, one 4px
// gap, the digits, and its own padding) is 59.5 alone, and 91.5 including
// the 4px gap plus its 28px reset button when that is also showing.
const double _playerBarBaseWidth = 206;

/// Width, in logical pixels available to the bar's bottom control row
/// (inside its own padding and border, so this is directly comparable to
/// the `LayoutBuilder` constraints in [_PlayerBarState.build]), at and
/// above which the volume slider renders alongside everything else.
///
/// Below it the slider drops and only the mute button remains, which
/// already covers the urgent case. [_playerBarBaseWidth] (206) + the
/// fixed 96px volume slider + 91.5 (a full O-counter, reset button
/// included) = 393.5.
const double _playerBarVolumeBreakpoint = _playerBarBaseWidth + 96 + 91.5;

/// Below [_playerBarVolumeBreakpoint] the volume slider is already gone.
/// Below this second, lower threshold the O-counter's reset button drops
/// too, leaving only its count and bump icon. [_playerBarBaseWidth] (206)
/// + 91.5 (O-counter with its reset button) = 297.5.
const double _playerBarResetBreakpoint = _playerBarBaseWidth + 91.5;

/// Below [_playerBarResetBreakpoint] the reset button is already gone.
/// Below this third, lowest threshold the O-counter's own digit count
/// drops too, leaving a bare icon-only bump button (measured at a fixed
/// 31: its padding plus one 15px icon, independent of the digit count
/// that no longer renders). [_playerBarBaseWidth] (206) + 59.5 (the bump
/// button alone, digits shown but no reset) = 265.5. This is the tier
/// the pre-existing 300px-wide drawer test (`scene_screen_test.dart`)
/// lands in: the bar's own padding takes 56 of that 300 (32 from the
/// panel's own `Padding`, 24 from the inner one; the `DecoratedBox`
/// border is paint-only and costs no layout width), leaving 244 of
/// content width, which fits the transport cluster plus the compact
/// O-counter (206 + 31 = 237) but not one still showing its digits
/// (206 + 59.5 = 265.5, over budget by 21.5).
const double _playerBarCountBreakpoint = _playerBarBaseWidth + 59.5;

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
              // A `LayoutBuilder` rather than a fixed row: at a narrow
              // window (the metadata drawer's own width tests go down to
              // 300px) the mute button, volume slider, transport cluster
              // and O-counter no longer fit their natural size together.
              // The transport cluster is the reason this bar exists and
              // never shrinks or drops; everything else yields, in
              // priority order, before it would ever overflow. See
              // [_playerBarVolumeBreakpoint] and its neighbours for the
              // measured widths this is built from.
              LayoutBuilder(
                builder: (context, constraints) {
                  final available = constraints.maxWidth;
                  final showVolume = available >= _playerBarVolumeBreakpoint;
                  final allowReset = available >= _playerBarResetBreakpoint;
                  final showCount = available >= _playerBarCountBreakpoint;
                  return Row(
                    children: [
                      PlayerIconButton(
                        icon: playback.muted
                            ? Icons.volume_off
                            : Icons.volume_up,
                        tooltip: playback.muted ? 'Unmute' : 'Mute',
                        onPressed: widget.onToggleMute,
                      ),
                      if (showVolume)
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
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
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
                      _OCounterGroup(
                        count: actions.oCount,
                        onIncrement: widget.onIncrementO,
                        onReset: widget.onResetO,
                        allowReset: allowReset,
                        showCount: showCount,
                      ),
                    ],
                  );
                },
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
///
/// [allowReset] and [showCount] are the bar's own narrow-width
/// concessions (see [_playerBarResetBreakpoint] and
/// [_playerBarCountBreakpoint]), applied on top of the data-driven
/// `count! > 0` check below: a reset only ever shows when both the width
/// allows it and there is something to reset, and the digit count itself
/// is the last thing dropped, leaving a bare icon-only bump button that
/// still works, just without a number on it.
class _OCounterGroup extends StatelessWidget {
  const _OCounterGroup({
    required this.count,
    required this.onIncrement,
    required this.onReset,
    required this.allowReset,
    required this.showCount,
  });

  final int? count;
  final VoidCallback onIncrement;
  final VoidCallback onReset;
  final bool allowReset;
  final bool showCount;

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
                      if (showCount) ...[
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (allowReset && enabled && count! > 0) ...[
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
