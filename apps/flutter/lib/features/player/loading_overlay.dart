import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/formatters.dart';
import 'load_diagnostics.dart';
import 'playback_state.dart';

/// How long a load has to run before the overlay shows itself at all.
///
/// Most loads finish inside this window, and a spinner that appears and
/// vanishes inside a fifth of a second is worse than no spinner: it reads
/// as a glitch rather than as feedback. Waiting means the overlay only
/// ever appears for a wait the viewer was going to notice anyway, which
/// is the only kind worth explaining.
const Duration loadingOverlayGrace = Duration(milliseconds: 400);

/// How long a wait has to run before the overlay starts reporting how
/// long it has been waiting.
///
/// Short enough that a genuinely slow load starts explaining itself
/// early, long enough that an ordinary one never flashes a stopwatch at
/// someone who was not kept waiting.
const Duration loadingElapsedThreshold = Duration(seconds: 3);

/// How long a wait has to run before the overlay adds what it knows about
/// *why*: how much has actually been cached. Reserved for waits that have
/// stopped looking normal, since it is the line that turns "still going"
/// into "still going, and here is whether it is winning".
const Duration loadingDetailThreshold = Duration(seconds: 10);

/// Identifies the scrim so a test can assert on the one thing about it
/// that matters: whether it is there at all.
const Key loadingScrimKey = Key('playback-loading-scrim');

/// Tells the viewer that the player is working, what it is working on,
/// and (once the wait stops looking ordinary) whether it is getting
/// anywhere.
///
/// Only ever mounted while there is genuinely something to report:
/// [PlaybackState.phase] is [PlaybackPhase.loading], or the engine is
/// [PlaybackState.buffering] mid-playback. Its caller decides that; this
/// widget assumes it and starts its own clock from the moment it is
/// mounted. That is deliberate, and the reason elapsed time is not a
/// field on [PlaybackState]: what the viewer is owed is how long *this*
/// wait has run, and a fresh stall is a fresh wait. It also keeps the
/// controller from having to notify once a second for a number only one
/// widget reads.
///
/// Deliberately independent of the transport controls' auto-hide. A load
/// that is still running must not be able to fade away and leave a black
/// rectangle with nothing on it, which is the whole complaint this
/// widget exists to answer, and the same principle already applied to
/// the persistent failure banner in `scene_screen.dart`.
class PlaybackLoadingOverlay extends StatefulWidget {
  const PlaybackLoadingOverlay({required this.state, super.key});

  final PlaybackState state;

  @override
  State<PlaybackLoadingOverlay> createState() => _PlaybackLoadingOverlayState();
}

class _PlaybackLoadingOverlayState extends State<PlaybackLoadingOverlay> {
  Timer? _graceTimer;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // Nothing is drawn, and no frame is scheduled, until the grace timer
    // fires: a load that finishes first unmounts this widget having cost
    // one pending timer and not one rebuild.
    _graceTimer = Timer(loadingOverlayGrace, () {
      if (!mounted) return;
      setState(() {
        _visible = true;
        _elapsed = loadingOverlayGrace;
      });
      // One tick a second, which is the resolution the label is written
      // to. Anything finer would rebuild more often than the text can
      // change. Started here rather than in `initState` so the grace
      // window really is free of rebuilds.
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    });
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final state = widget.state;
    final isInitialLoad = state.phase == PlaybackPhase.loading;
    final headline = _headline(state);
    final detail = _detail(state);

    final content = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              // The overlay sits on video, which can be any colour at
              // all, so the text carries its own contrast rather than
              // relying on the scrim (which a mid-playback stall does
              // not draw).
              shadows: [Shadow(blurRadius: 8)],
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                shadows: [Shadow(blurRadius: 8)],
              ),
            ),
          ],
        ],
      ),
    );

    final labelled = Semantics(
      liveRegion: true,
      label: detail == null ? headline : '$headline. $detail',
      excludeSemantics: true,
      child: content,
    );

    // The scrim is for the initial load only: there is nothing behind it
    // yet but black. A mid-playback stall has a real frame frozen on
    // screen, and dimming it every time the network hiccups would be
    // more disruptive than the stall.
    if (!isInitialLoad) return IgnorePointer(child: labelled);
    return IgnorePointer(
      child: ColoredBox(
        key: loadingScrimKey,
        color: Colors.black.withValues(alpha: 0.45),
        child: labelled,
      ),
    );
  }

  /// What the player is doing right now, in the viewer's terms.
  String _headline(PlaybackState state) {
    final stage = state.loadStage;
    if (stage == null) {
      return state.buffering ? 'Buffering' : 'Loading';
    }
    // Only while the switch is actually in flight. Once it is playing, a
    // later stall is just a stall, and repeating the switch wording would
    // suggest it is happening again.
    if (state.usingFallbackStream && stage == LoadStage.opening) {
      return 'Switching to a faster stream';
    }
    return switch (stage) {
      LoadStage.connecting => 'Connecting to Stash',
      LoadStage.opening => _openingLabel(state),
      LoadStage.starting => 'Starting playback',
    };
  }

  /// Naming the position makes the wait legible rather than mysterious:
  /// opening an hour into a file is slower than opening at the start,
  /// and saying where it is going explains why.
  ///
  /// Part of the opening label rather than a stage of its own: the
  /// resume position is handed to the engine as part of opening the
  /// file, so there is no separate seek to narrate.
  String _openingLabel(PlaybackState state) {
    final resume = state.scene?.effectiveResume;
    if (resume == null) return 'Opening video';
    return 'Opening video at ${formatDuration(resume)}';
  }

  /// The second line: silent for an ordinary wait, elapsed time once it
  /// drags, and what has actually been cached once it is long enough that
  /// "is this stuck?" is the real question.
  String? _detail(PlaybackState state) {
    if (_elapsed < loadingElapsedThreshold) return null;
    final elapsed = '${_elapsed.inSeconds}s';
    if (_elapsed < loadingDetailThreshold) return elapsed;

    final buffered = state.buffered;
    return buffered > Duration.zero
        ? '$elapsed, ${buffered.inSeconds}s cached'
        : '$elapsed, nothing cached yet';
  }
}
