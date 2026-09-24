import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../shared/formatters.dart';
import '../../ui/icons/app_icons.dart';
import '../../ui/theme/app_tokens.dart';
import 'playback_state.dart';
import 'player_icon_button.dart';

// The control row puts the transport at its true centre, between two
// equal side slots: volume on the left, the O-counter on the right. Each
// side therefore gets half of whatever the transport leaves, whatever the
// other side needs, and every narrow-width concession below is a side
// group measured against that one half.
//
// The transport itself (four 28px buttons, one 38px primary play/pause,
// four 8px gaps) never shrinks or drops at any width: 182.
const double _transportWidth =
    PlayerIconButton.size * 4 +
    PlayerIconButton.primarySize +
    AppTokens.space2 * 4;

/// The mute button plus the fixed 96px volume slider beside it.
const double _volumeGroupWidth = PlayerIconButton.size + 96;

// The O-counter's own bump button is not fixed-width: `oCount` is an
// unbounded `int?` straight from Stash's mutation, and its digits render
// with tabular figures, so every digit costs the same and the button's
// width is an exact linear function of the digit count rather than a
// single representative number. Measured via `tester.getSize` against
// the real rendered widget at 1, 2, 3, 4 and 5-digit counts ("0", "12",
// "123", "1000", "12345"): 47.25, 59.5, 71.75, 84.0, 96.25, each exactly
// 12.25 more than the last. `_oCounterFixedWidth` (35) is that series'
// own zero-digit intercept, and independently equals the padding (16)
// plus the icon (15) plus the one 4px gap before the digits: the parts
// of the button that do not depend on the count at all.
const double _oCounterPerDigitWidth = 12.25;
const double _oCounterFixedWidth = 35;

/// The O-counter bump button's own width at [digitCount] digits, with no
/// reset button attached.
double _oCounterBumpWidth(int digitCount) =>
    _oCounterFixedWidth + digitCount * _oCounterPerDigitWidth;

/// The reset button (28) plus the one 4px gap before it, added on top of
/// [_oCounterBumpWidth] when the reset button also shows. Digit-count
/// independent: the reset button itself never changes size.
const double _oCounterResetWidth = 32;

/// What the bottom control row shows on each side of the transport, for
/// a row [available] logical pixels wide (inside the frame's padding, so
/// directly the `LayoutBuilder` constraint in [_PlayerBarState.build])
/// and an O-counter showing [digitCount] digits.
///
/// Things drop in priority order, each only once its side no longer fits
/// it: the volume slider first (the mute button alone still covers the
/// urgent case), then the O-counter's reset button, then its digits,
/// leaving a bare icon-only bump button (a fixed 31: [_oCounterFixedWidth]
/// minus the 4px gap that only leads into digits, which is itself
/// conditional on `showCount` in [_OCounterGroup]).
///
/// The narrowest case is the pre-existing 300px-wide drawer test
/// (`scene_screen_test.dart`): the bar's padding takes 56 of that 300 (32
/// from its outer `Padding`, 24 from the frame's inner one), leaving 244,
/// so each side gets (244 - 182) / 2 = 31, exactly the icon-only bump
/// button at any digit count.
({bool showVolume, bool allowReset, bool showCount}) _controlRowLayout(
  double available,
  int digitCount,
) {
  final side = (available - _transportWidth) / 2;
  final bump = _oCounterBumpWidth(digitCount);
  final fullOCounter = bump + _oCounterResetWidth;
  return (
    showVolume: side >= _volumeGroupWidth && side >= fullOCounter,
    allowReset: side >= fullOCounter,
    showCount: side >= bump,
  );
}

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

/// The scene screen's transport: a compact frosted frame floating above
/// the video's bottom edge. It stretches with the window up to
/// [AppTokens.playerBarMaxWidth] and no further, so on a wide window it
/// sits centred instead of spanning the picture. The caller centres it;
/// this widget only caps its own width.
///
/// Two lines. The upper one is elapsed time, the scrubber and duration.
/// The lower one is three groups in one row: volume leading, the
/// transport (prev, back 10, play/pause, forward 10, next) centred, and
/// the O-counter trailing.
///
/// Purely presentational: every field is an immutable [PlaybackState] or a
/// callback. This widget never touches a controller or a provider.
///
/// Stateful for the scrubber's local drag position, and for which slider
/// the pointer is over. Committing a seek on every `onChanged` sample
/// turns one drag gesture into dozens of GraphQL writes, so the thumb is
/// tracked here and [PlayerBar.onSeek] fires exactly once, from
/// `onChangeEnd`. Tracking it locally also stops the thumb snapping back
/// to the stale pre-seek position between samples. The hover flags let
/// both sliders rest as a thin bare track and only grow a thumb when the
/// pointer is on them.
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

  bool _seekHovered = false;
  bool _volumeHovered = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTokens.space4,
      0,
      AppTokens.space4,
      AppTokens.space5,
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppTokens.playerBarMaxWidth),
      child: _FrostedFrame(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space3,
            vertical: AppTokens.space2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildScrubberRow(),
              // A `LayoutBuilder` rather than a fixed row: at a narrow
              // window (the metadata drawer's own width tests go down to
              // 300px) the mute button, volume slider, transport cluster
              // and O-counter no longer fit their natural size together.
              // The transport cluster is the reason this bar exists and
              // never shrinks or drops; everything else yields, in
              // priority order, before it would ever overflow. See
              // [_controlRowLayout] for the measured widths this is
              // built from.
              LayoutBuilder(
                builder: (context, constraints) =>
                    _buildControlRow(constraints.maxWidth),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildScrubberRow() {
    final playback = widget.playback;
    final durationSeconds = playback.duration.inMilliseconds / 1000;
    final actualPositionSeconds = playback.position.inMilliseconds / 1000;
    final hasKnownDuration = playback.duration > Duration.zero;
    final sliderMax = hasKnownDuration ? durationSeconds : 1.0;
    final positionSeconds = (_dragValueSeconds ?? actualPositionSeconds).clamp(
      0.0,
      sliderMax,
    );
    // media_kit reports libmpv's `demuxer-cache-time`, the timestamp the
    // cache runs up to, so it is already a position on this track.
    final bufferedSeconds = (playback.buffered.inMilliseconds / 1000).clamp(
      0.0,
      sliderMax,
    );

    return Row(
      children: [
        Semantics(
          label: 'Elapsed time',
          child: Text(formatDuration(positionSeconds), style: _timeStyle),
        ),
        Expanded(
          // A label rather than a tooltip: a hover popup would sit over
          // the transport right under the pointer, and the thumb that
          // grows on hover already says this is the scrubber.
          child: Semantics(
            label: 'Seek',
            child: _PlayerSlider(
              active: _seekHovered || _dragValueSeconds != null,
              onHoverChanged: (hovered) =>
                  setState(() => _seekHovered = hovered),
              slider: Slider(
                key: const Key('scene-seek-bar'),
                value: positionSeconds,
                max: sliderMax,
                secondaryTrackValue: hasKnownDuration ? bufferedSeconds : null,
                label: formatDuration(positionSeconds),
                onChanged: hasKnownDuration
                    ? (value) => setState(() {
                        _dragValueSeconds = value;
                      })
                    : null,
                onChangeEnd: hasKnownDuration
                    ? (value) {
                        widget.onSeek(
                          Duration(milliseconds: (value * 1000).round()),
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
            style: _timeStyle.copyWith(color: AppTokens.playerTextDim),
          ),
        ),
      ],
    );
  }

  Widget _buildControlRow(double available) {
    final playback = widget.playback;
    final actions = widget.actions;
    // The O-counter's own width (and so every breakpoint downstream of
    // it) depends on how many digits it is about to render, not on a
    // fixed representative count: `oCount` is an unbounded `int?`
    // straight from Stash's mutation, and a wider count that a
    // fixed-width budget did not see coming is exactly what would
    // otherwise overflow this row.
    final digitCount = (actions.oCount ?? 0).toString().length;
    final layout = _controlRowLayout(available, digitCount);
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              PlayerIconButton(
                icon: playback.muted ? AppIcon.volumeMuted : AppIcon.volumeHigh,
                tooltip: playback.muted ? 'Unmute' : 'Mute',
                variant: PlayerIconButtonVariant.subdued,
                onPressed: widget.onToggleMute,
              ),
              if (layout.showVolume)
                SizedBox(
                  width: 96,
                  child: Semantics(
                    label: 'Volume',
                    child: _PlayerSlider(
                      active: _volumeHovered,
                      onHoverChanged: (hovered) =>
                          setState(() => _volumeHovered = hovered),
                      slider: Slider(
                        key: const Key('scene-volume-slider'),
                        value: playback.volume.clamp(0.0, 1.0),
                        onChanged: widget.onVolumeChanged,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _buildTransport(),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _OCounterGroup(
              count: actions.oCount,
              onIncrement: widget.onIncrementO,
              onReset: widget.onResetO,
              allowReset: layout.allowReset,
              showCount: layout.showCount,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransport() {
    final playing = widget.playback.playing;
    final actions = widget.actions;
    const gap = SizedBox(width: AppTokens.space2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerIconButton(
          icon: AppIcon.skipPrevious,
          tooltip: 'Previous scene',
          variant: PlayerIconButtonVariant.bare,
          onPressed: actions.canGoPrevious ? widget.onPrevious : null,
        ),
        gap,
        PlayerIconButton(
          icon: AppIcon.seekBack10,
          tooltip: 'Back 10 seconds',
          variant: PlayerIconButtonVariant.subdued,
          onPressed: widget.onSkipBackward,
        ),
        gap,
        PlayerIconButton(
          icon: playing ? AppIcon.pause : AppIcon.play,
          tooltip: playing ? 'Pause' : 'Play',
          variant: PlayerIconButtonVariant.primary,
          onPressed: widget.onTogglePlayPause,
        ),
        gap,
        PlayerIconButton(
          icon: AppIcon.seekForward10,
          tooltip: 'Forward 10 seconds',
          variant: PlayerIconButtonVariant.subdued,
          onPressed: widget.onSkipForward,
        ),
        gap,
        PlayerIconButton(
          icon: AppIcon.skipNext,
          tooltip: 'Next scene',
          variant: PlayerIconButtonVariant.bare,
          onPressed: actions.canGoNext ? widget.onNext : null,
        ),
      ],
    );
  }
}

/// The bar's surface: a blur of the video behind it under a light tint,
/// with a soft shadow in place of a border, so the frame reads as glass
/// over the picture rather than a slab on top of it.
class _FrostedFrame extends StatelessWidget {
  const _FrostedFrame({required this.child});

  final Widget child;

  static const _radius = BorderRadius.all(
    Radius.circular(AppTokens.radiusPlayerBar),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('scene-player-bar-frame'),
    decoration: const BoxDecoration(
      borderRadius: _radius,
      boxShadow: [
        BoxShadow(
          color: Color(0x4D000000),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: _radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: ColoredBox(color: AppTokens.playerBarFill, child: child),
      ),
    ),
  );
}

/// A player slider that rests as a thin bare track and eases into a
/// thicker one with a thumb while [active].
///
/// [active] is decided by the caller, not by this widget's own hover,
/// because the seek bar also stays active for the length of a drag even
/// if the pointer wanders off it mid-gesture.
class _PlayerSlider extends StatelessWidget {
  const _PlayerSlider({
    required this.active,
    required this.onHoverChanged,
    required this.slider,
  });

  final bool active;
  final ValueChanged<bool> onHoverChanged;
  final Slider slider;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => onHoverChanged(true),
    onExit: (_) => onHoverChanged(false),
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: active ? 1 : 0),
      duration: AppTokens.hoverDuration,
      curve: Curves.easeOut,
      builder: (context, t, child) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3 + 2 * t,
          activeTrackColor: AppTokens.playerText,
          inactiveTrackColor: AppTokens.playerTrack,
          secondaryActiveTrackColor: AppTokens.playerBufferedTrack,
          thumbColor: AppTokens.playerText,
          overlayColor: AppTokens.playerText.withValues(alpha: 0.12),
          // Explicit shapes so the look does not drift with the
          // framework's own Material 3 slider defaults. A 12px overlay
          // radius keeps the row 24px tall rather than the stock 48.
          trackShape: const RoundedRectSliderTrackShape(),
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: 6 * t,
            elevation: 0,
            pressedElevation: 0,
          ),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: child!,
      ),
      child: slider,
    ),
  );
}

/// The O-counter: a button showing the current count, and a reset button
/// that appears only once there is something to reset.
///
/// A `null` [count] renders the group dead rather than hiding it, so the
/// bar does not reflow every time a prev/next fetch is in flight.
///
/// [allowReset] and [showCount] are the bar's own narrow-width
/// concessions (see [_controlRowLayout]), applied on top of the data-driven
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
    // Subdued like the bar's other secondary controls, so it does not
    // pull the eye away from the transport.
    final glyph = enabled
        ? AppTokens.playerGlyphSubdued
        : AppTokens.playerText.withValues(alpha: 0.38);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Bump O-counter',
          child: Semantics(
            button: true,
            enabled: enabled,
            label: 'Bump O-counter',
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: enabled ? onIncrement : null,
                // Same wash `PlayerIconButton` uses, for the same reason
                // (see that widget's own comment): the panel is always
                // dark, so the theme's own hover/highlight/splash colours
                // (which follow app brightness) would be dark-on-dark in
                // the light theme. This is the one player control that
                // isn't built from `PlayerIconButton` itself.
                hoverColor: AppTokens.playerText.withValues(alpha: 0.1),
                highlightColor: AppTokens.playerText.withValues(alpha: 0.18),
                splashColor: AppTokens.playerText.withValues(alpha: 0.18),
                // A pill, matching the round washes of the bar's bare
                // icon buttons.
                borderRadius: BorderRadius.circular(PlayerIconButton.size / 2),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.space2,
                    vertical: AppTokens.space1,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIconView(AppIcon.oCounter, size: 15, color: glyph),
                      if (showCount) ...[
                        const SizedBox(width: AppTokens.space1),
                        Text(
                          // A dimmed "0" would assert a count the server
                          // never reported: `count` is `null` for every
                          // prev/next fetch and the initial load, not
                          // just "zero and uncounted". A single narrow
                          // placeholder glyph keeps the width budget
                          // honest too: the reflow above derives
                          // `digitCount` from `oCount ?? 0`, i.e. one
                          // digit, so whatever renders here must not be
                          // wider than that.
                          count == null ? '-' : '$count',
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
            icon: AppIcon.reset,
            tooltip: 'Reset O-counter to 0',
            variant: PlayerIconButtonVariant.subdued,
            onPressed: onReset,
          ),
        ],
      ],
    );
  }
}
