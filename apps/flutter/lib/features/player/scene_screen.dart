import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/notices.dart';
import '../../app/providers.dart';
import '../../domain/scene.dart';
import '../../services/external_url_launcher.dart';
import 'playback_controller.dart';
import 'playback_state.dart';
import 'player_bar.dart';
import 'player_shortcuts.dart';
import 'player_top_bar.dart';
import 'scene_controller.dart';
import 'scene_metadata_drawer.dart';
import 'video_surface.dart';

/// The video-first scene screen: a full-bleed `Stack` with the video
/// surface behind everything, an auto-hiding transport overlay docked to
/// the bottom, and a metadata drawer that slides in from the right — see
/// [_SceneScreenState._buildSceneStack] for the exact three-layer
/// composition the brief mandates. **Never** a `Row`, `NavigationRail`, or
/// resizing split pane: opening the drawer must never change the video
/// surface's measured size (see `scene_screen_test.dart`'s own "does not
/// resize the video" group).
///
/// Scene *metadata* loading (title, performers, files, ...) is owned by
/// [sceneControllerProvider] (`ScenePhase`); video *playback* is owned by
/// the already-shared `playbackControllerProvider` (`PlaybackPhase`).
/// These are deliberately independent: a scene whose metadata loaded fine
/// but whose video failed to open renders the video-first stack with a
/// small, non-blocking or blocking failure overlay depending on whether
/// the video ever played at all — see
/// [_SceneScreenState._shouldShowBlockingPlaybackFailure].
class SceneScreen extends ConsumerStatefulWidget {
  const SceneScreen({required this.sceneId, super.key});

  final String sceneId;

  @override
  ConsumerState<SceneScreen> createState() => _SceneScreenState();
}

class _SceneScreenState extends ConsumerState<SceneScreen> {
  static const _hideDelay = Duration(seconds: 3);
  static const _fadeDuration = Duration(milliseconds: 200);

  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _hoveringControls = false;
  bool _controlsFocused = false;
  bool _metadataOpen = false;

  // `PlaybackController` is a `ChangeNotifier` exposed through a
  // `ChangeNotifierProvider`, which always reports the *same* instance as
  // both `previous` and `next` in `ref.listen` (Riverpod's own
  // `ChangeNotifierProviderElement.updateShouldNotify` unconditionally
  // returns `true`, precisely so every `notifyListeners()` call is
  // observed — it doesn't diff values). That makes `previous?.state` and
  // `next.state` read the exact same, already-mutated `PlaybackState` by
  // the time any listener runs: comparing them can never detect a
  // transition. These three fields are this widget's own independently-
  // tracked "what was true last time the listener ran", updated only
  // inside that callback — see `build`'s own `ref.listen`.
  bool? _lastPlaying;
  bool? _lastBuffering;
  PlaybackPhase? _lastPhase;

  /// Same technique as [_lastPhase], applied to
  /// `PlaybackState.controlFailureSequence` (fix round 1, item 5): a
  /// control-command failure (play/pause/seek/volume/mute) no longer
  /// touches `phase`/`failure` at all, so it can only ever be *noticed*
  /// here by diffing this monotonically-increasing counter — comparing
  /// `PlaybackState.controlFailure` by string value would miss two
  /// consecutive failures with the identical message.
  int _lastControlFailureSequence = 0;

  @override
  void initState() {
    super.initState();
    // `SceneController.load` mutates state (and calls `notifyListeners()`)
    // synchronously before its first `await` — calling it directly here
    // would modify `sceneControllerProvider` while this very widget tree
    // is still building, which Riverpod forbids (the same reasoning
    // `LibraryScreen._scheduleLoadInitial` documents for its own
    // post-frame deferral).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(sceneControllerProvider).load(widget.sceneId);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // No explicit teardown of `sceneControllerProvider` here: Riverpod
    // forbids using `ref` at all once this element starts unmounting
    // (`ref.invalidate` throws "Cannot use 'ref' after the widget was
    // disposed" — caught empirically by this task's own widget tests), so
    // `sceneControllerProvider` is `.autoDispose` instead. Once this
    // widget's own `ref.watch` subscription in `build()` goes away (which
    // happens as part of this very unmount), Riverpod disposes the
    // `SceneController` on its own — which in turn releases the shared
    // `PlaybackController`/engine (see that provider's own doc). Without
    // that auto-dispose, popping back to the library would leave the
    // engine alive (and, if still playing, still audible) in the
    // background.
    super.dispose();
  }

  bool _suppressHide(PlaybackState playback) =>
      !playback.playing ||
      playback.buffering ||
      _hoveringControls ||
      _controlsFocused ||
      _metadataOpen;

  /// The single place every "the user is doing something" signal (pointer
  /// movement, a keyboard shortcut, hovering/focusing a control, opening
  /// metadata) and every "playback state that should suppress hiding"
  /// signal (pause, buffering) funnels through: reveals the controls if
  /// they were hidden, cancels any pending hide, and — only if nothing
  /// currently suppresses it — arms a fresh 3-second hide timer.
  void _registerActivity(PlaybackState playback) {
    if (!mounted) return;
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    if (!_suppressHide(playback)) {
      _hideTimer = Timer(_hideDelay, () {
        if (!mounted) return;
        setState(() => _controlsVisible = false);
      });
    }
  }

  void _setHovering(bool value, PlaybackState playback) {
    if (_hoveringControls == value) return;
    setState(() => _hoveringControls = value);
    _registerActivity(playback);
  }

  void _setControlsFocused(bool value, PlaybackState playback) {
    if (_controlsFocused == value) return;
    setState(() => _controlsFocused = value);
    _registerActivity(playback);
  }

  void _toggleMetadata(PlaybackState playback) {
    setState(() => _metadataOpen = !_metadataOpen);
    _registerActivity(playback);
  }

  Future<void> _openInStash(String sceneId) async {
    try {
      final config = await ref.read(effectiveConnectionProvider.future);
      final uri = resolveStashSceneUrl(config.serverUrl, sceneId);
      final launcher = ref.read(externalUrlLauncherProvider);
      final opened = await launcher.open(uri);
      if (!opened) throw StateError('launcher reported failure');
    } catch (_) {
      if (!mounted) return;
      ref
          .read(globalNoticeProvider.notifier)
          .show(
            AppNotice(
              message: 'Could not open Stash in a browser.',
              severity: AppNoticeSeverity.warning,
            ),
          );
    }
  }

  /// Whether the current `PlaybackPhase.failed` should take over the
  /// whole screen with a blocking Retry/Open-in-Stash overlay, versus
  /// being treated as a recoverable mid-stream break that leaves the
  /// video (and transport controls) exactly as they were.
  ///
  /// `PlaybackPhase.failed` today is reached only two ways —
  /// `PlaybackController.loadScene`'s own `catch` (the scene never became
  /// playable at all: no stream URL, a connection failure, or
  /// `_engine.open`/`seek`/`play` throwing before anything ever rendered)
  /// or an engine-reported `errors` stream event, which can fire *after*
  /// the video already played successfully for a while (a genuine
  /// mid-stream break, e.g. a network drop). Control-command failures
  /// (a failed volume nudge, mute, play/pause, or seek) never reach
  /// `phase` at all — `_runEngineCommand` routes those into the separate
  /// `PlaybackState.controlFailure`/`controlFailureSequence` channel
  /// instead (see that method's own doc for why conflating the two was a
  /// real, reported defect), so this method has nothing to do with them.
  ///
  /// `duration` is only ever set once the engine's own `duration` stream
  /// has fired at least once for the current scene (see
  /// `PlaybackState.duration`'s own doc — "no real media has a zero
  /// duration"), which only happens after a *successful* `open()`. So
  /// `duration > Duration.zero` is a reliable proxy for "this scene's
  /// video already loaded" — a `failed` phase reached *after* that point
  /// is treated as non-blocking: a one-shot warning notice (see the
  /// `ref.listen` in [build]) plus the persistent Retry banner, rather
  /// than a full-screen takeover, since the user is still looking at a
  /// video that did play. Only a `failed` phase reached *before* any
  /// duration was ever established — the scene never became playable at
  /// all — gets the blocking overlay.
  bool _shouldShowBlockingPlaybackFailure(PlaybackState playback) =>
      playback.phase == PlaybackPhase.failed &&
      playback.duration == Duration.zero;

  @override
  Widget build(BuildContext context) {
    final sceneController = ref.watch(sceneControllerProvider);
    final sceneState = sceneController.state;
    final scene = sceneState.scene;

    // Correction (fix round 1, item 6): this used to claim
    // `playbackControllerProvider` "is not touched until a scene has
    // loaded" — that's false and was never true. `sceneControllerProvider`
    // is watched unconditionally just above, and its own builder
    // (`scene_controller.dart`) reads `playbackControllerProvider`
    // synchronously as part of constructing `SceneController` — so the
    // shared `PlaybackEngine` is already built the instant this screen
    // mounts, before any scene metadata has resolved. `app_router_test.dart`
    // documents this correctly. What *is* deferred by the `scene == null`
    // early return below is only this widget's own `ref.watch`/`ref.listen`
    // subscription to `playbackControllerProvider` — avoiding a rebuild
    // (and a `ref.listen` registration) on every position/duration tick
    // while there's no scene to render a video-first stack for yet, not
    // avoiding engine construction, which has already happened by the
    // time this line runs.
    if (scene == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _SceneUnavailableView(
          state: sceneState,
          onRetry: sceneController.retry,
          onOpenInStash: _openInStash,
        ),
      );
    }

    final playbackController = ref.watch(playbackControllerProvider);
    final playback = playbackController.state;

    ref.listen<PlaybackController>(playbackControllerProvider, (
      previous,
      next,
    ) {
      // Deliberately not comparing against `previous?.state` here — see
      // `_lastPlaying`'s own doc for why that can never detect a change
      // for a `ChangeNotifierProvider`-backed controller.
      final nextState = next.state;
      final playingOrBufferingChanged =
          _lastPlaying != nextState.playing ||
          _lastBuffering != nextState.buffering;
      final justFailedToLoad =
          nextState.phase == PlaybackPhase.failed &&
          _lastPhase != PlaybackPhase.failed;
      final controlFailureChanged =
          nextState.controlFailureSequence != _lastControlFailureSequence &&
          nextState.controlFailureSequence > 0;
      _lastPlaying = nextState.playing;
      _lastBuffering = nextState.buffering;
      _lastPhase = nextState.phase;
      _lastControlFailureSequence = nextState.controlFailureSequence;

      if (playingOrBufferingChanged) {
        _registerActivity(nextState);
      }

      if (justFailedToLoad && nextState.duration > Duration.zero) {
        // A genuine stream/load failure (from `loadScene`'s own catch or
        // the engine's `errors` stream) reached mid-scene, after the
        // video had already played — see `_shouldShowBlockingPlaybackFailure`'s
        // own doc for why this is surfaced non-modally (a one-shot
        // notice) rather than as a full error state. The persistent
        // `_TransientPlaybackFailureBanner` in `_buildSceneStack` (fix
        // round 1, item 5) is what actually gives the user a lasting way
        // out — this notice is just the attention-getter.
        ref
            .read(globalNoticeProvider.notifier)
            .show(
              AppNotice(
                message: nextState.failure ?? 'Playback ran into a problem.',
                severity: AppNoticeSeverity.warning,
              ),
            );
      }

      if (controlFailureChanged) {
        // A control command (play/pause/seek/volume/mute) failed — fix
        // round 1, item 5, scenario 2: this fires on *every* such
        // failure (via the sequence counter, not a phase transition or a
        // string comparison), so a second failure right after the first
        // is never silently swallowed the way it was when both routed
        // through the same terminal `phase`.
        ref
            .read(globalNoticeProvider.notifier)
            .show(
              AppNotice(
                message:
                    nextState.controlFailure ??
                    'A playback control action failed.',
                severity: AppNoticeSeverity.warning,
              ),
            );
      }
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: _buildSceneStack(scene, playback, playbackController),
    );
  }

  Widget _buildSceneStack(
    Scene scene,
    PlaybackState playback,
    PlaybackController playbackController,
  ) {
    final showBlockingFailure = _shouldShowBlockingPlaybackFailure(playback);
    // Fix round 1, item 5 (scenario 1): a `phase == failed` that isn't
    // blocking (the video already played — see
    // `_shouldShowBlockingPlaybackFailure`'s own doc) used to leave the
    // user with nothing but a one-shot, auto-dismissing `SnackBar` and no
    // lasting way to recover. This banner is the persistent affordance:
    // shown for as long as `phase` stays `failed` in the non-blocking
    // case, regardless of `_controlsVisible`'s own auto-hide state (an
    // error condition must not be able to fade away on its own).
    final showTransientFailureBanner =
        playback.phase == PlaybackPhase.failed && !showBlockingFailure;
    final effectiveVisible = _controlsVisible;

    return PlayerActionShortcuts(
      controller: playbackController,
      onActivity: () => _registerActivity(playback),
      // `LayoutBuilder` around the whole `Stack` — not just around the
      // drawer's own `Positioned` — so the drawer's max-width clamp (fix
      // round 1, item 2) has the *stack's* actual available width to
      // work with. A `Positioned(right: 0)` with no `left` and no
      // explicit `width` gives its child a genuinely *unconstrained*
      // (infinite) width per `RenderStack`'s own
      // `positionedChildConstraints` — measured empirically after an
      // earlier version of this fix tried exactly that and the drawer
      // came back 420px wide even in a 300px-wide test window. Capturing
      // `constraints.maxWidth` up here and passing an explicit,
      // pre-clamped `width:` into `Positioned` below is what actually
      // constrains it.
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            // 1. Black, full-size video surface.
            Positioned.fill(
              child: MouseRegion(
                onHover: (_) => _registerActivity(playback),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _registerActivity(playback),
                  child: VideoSurface(controller: playbackController),
                ),
              ),
            ),
            if (showBlockingFailure)
              _PlaybackFailureOverlay(
                title: scene.displayTitle,
                message: playback.failure ?? 'This video could not be played.',
                onRetry: () => ref.read(sceneControllerProvider).load(scene.id),
                onOpenInStash: () => _openInStash(scene.id),
              ),
            // 2. Controls overlay: a top bar pinned to the video's top edge
            // and a player bar pinned to its bottom edge. Fix round 1 of
            // this task's own review: the banner below shares the top
            // bar's `Column` (not a second, independently-`Positioned`
            // widget guessing a pixel offset) so the two can never
            // overlap: Flutter measures the top bar's real height and
            // lays the banner out directly beneath it, at any window
            // width or message length, with no hardcoded number anywhere.
            //
            // One shared `FocusScope` wraps both bars (not one each): a
            // `FocusScope` is not a hit-test participant, so splitting it
            // alongside the two `MouseRegion`s bought nothing but two
            // separate Tab rings for what are, visually, one control strip.
            //
            // The top bar and the player bar each keep their own
            // `IgnorePointer`/`AnimatedOpacity` pair, both driven by the
            // same `effectiveVisible`/`_fadeDuration` (so they still fade
            // in lockstep), rather than one shared instance wrapping both:
            // the banner must sit *outside* whichever fade wraps the top
            // bar (it must stay visible and tappable even while the
            // controls are faded), and Flutter's opacity only ever applies
            // to a widget's own descendants: a `Column` sibling of the top
            // bar's fade subtree is the only way for the banner to be laid
            // out relative to it without inheriting its opacity.
            Positioned.fill(
              child: FocusScope(
                onFocusChange: (value) => _setControlsFocused(value, playback),
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IgnorePointer(
                            ignoring: !effectiveVisible,
                            child: AnimatedOpacity(
                              key: const Key('scene-controls-overlay'),
                              duration: _fadeDuration,
                              opacity: effectiveVisible ? 1 : 0,
                              child: MouseRegion(
                                onEnter: (_) => _setHovering(true, playback),
                                onExit: (_) => _setHovering(false, playback),
                                child: PlayerTopBar(
                                  title: scene.displayTitle,
                                  metadataOpen: _metadataOpen,
                                  onBack: () =>
                                      Navigator.of(context).maybePop(),
                                  onToggleMetadata: () =>
                                      _toggleMetadata(playback),
                                ),
                              ),
                            ),
                          ),
                          if (showTransientFailureBanner)
                            _TransientPlaybackFailureBanner(
                              key: const Key('scene-transient-failure-banner'),
                              message:
                                  playback.failure ??
                                  'Playback ran into a problem.',
                              onRetry: () => ref
                                  .read(sceneControllerProvider)
                                  .load(scene.id),
                            ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        ignoring: !effectiveVisible,
                        child: AnimatedOpacity(
                          duration: _fadeDuration,
                          opacity: effectiveVisible ? 1 : 0,
                          child: MouseRegion(
                            onEnter: (_) => _setHovering(true, playback),
                            onExit: (_) => _setHovering(false, playback),
                            child: PlayerBar(
                              playback: playback,
                              onTogglePlayPause: playbackController.playPause,
                              onSeek: playbackController.seekAbsolute,
                              onVolumeChanged: playbackController.setVolume,
                              onToggleMute: playbackController.toggleMute,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 3. Metadata drawer, aligned right, capped at 420 logical
            // pixels, sliding over the video rather than reflowing it. A
            // `Positioned` (top/right/bottom pinned, explicit width) rather
            // than `Align` — `Align` only gives loose constraints, which
            // would shrink-wrap the drawer's height to its content instead
            // of spanning the full screen. Deliberate deviation from a
            // literal `Align(right)` (fix round 1, item 2's own review
            // note): the load-bearing property — the video surface's
            // measured size never changes when the drawer opens — is
            // genuinely measured by `scene_screen_test.dart`'s own "does
            // not resize the video" group at two window sizes.
            //
            // 3a. Scrim: dims everything behind the drawer while it's open
            // and closes it on tap-outside (fix round 1, item 1 — the
            // brief's Step 4 explicitly requires a scrim, which this
            // Stack's very first version omitted entirely). `IgnorePointer`
            // keeps it out of the hit-test tree — and so out of the way of
            // every other tap/hover in this Stack — whenever the drawer is
            // closed.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_metadataOpen,
                child: GestureDetector(
                  onTap: () => _toggleMetadata(playback),
                  child: AnimatedOpacity(
                    key: const Key('scene-metadata-scrim'),
                    duration: _fadeDuration,
                    opacity: _metadataOpen ? 1 : 0,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
            // 3b. The drawer itself, capped at [SceneMetadataDrawer.maxWidth]
            // logical pixels — a *maximum*, not a fixed width (fix round 1,
            // item 2: the original `width: SceneMetadataDrawer.maxWidth`
            // was unconditional, so a window narrower than 420px pushed the
            // drawer's left edge negative and clipped its content). Passing
            // an explicit, pre-clamped `width:` (from the outer
            // `LayoutBuilder`'s own `constraints.maxWidth` — the *stack's*
            // real available width) gives `Positioned` a tight constraint;
            // see this method's own top-level comment for why leaving
            // `width` unset here does not.
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: math.min(
                SceneMetadataDrawer.maxWidth,
                constraints.maxWidth,
              ),
              // `ClipRect`+`AnimatedSlide` only ever move the drawer
              // off-screen; the subtree stays mounted, hit-testable,
              // focusable, and in the accessibility tree the whole time
              // (final review I8). `ExcludeSemantics` keeps a screen
              // reader from describing a panel the user can't see, and
              // `descendantsAreFocusable: false` keeps Tab from ever
              // landing on the drawer's Close button at its offscreen
              // `Offset(1, 0)` while closed. Not `canRequestFocus`: on a
              // `FocusScopeNode`, `descendantsAreFocusable` is itself
              // defined as `_canRequestFocus && super.descendantsAreFocusable`
              // (`focus_manager.dart`), so `canRequestFocus: false` here
              // would disable descendants too — but only as a side effect
              // of also making the scope node itself unfocusable, which
              // `descendantsAreFocusable` doesn't do.
              child: ExcludeSemantics(
                key: const Key('scene-metadata-drawer-exclude-semantics'),
                excluding: !_metadataOpen,
                child: FocusScope(
                  key: const Key('scene-metadata-drawer-focus-scope'),
                  descendantsAreFocusable: _metadataOpen,
                  child: ClipRect(
                    child: AnimatedSlide(
                      duration: _fadeDuration,
                      offset: _metadataOpen ? Offset.zero : const Offset(1, 0),
                      child: SceneMetadataDrawer(
                        scene: scene,
                        onClose: () => _toggleMetadata(playback),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rendered instead of the video-first stack whenever `sceneState.scene`
/// is still `null` — either the scene's own metadata is loading for the
/// first time, or it never loaded at all ([ScenePhase.notFound] /
/// [ScenePhase.failed]). Distinct from [_PlaybackFailureOverlay], which
/// renders *over* an already-loaded scene's video when the video itself
/// (not the metadata) fails.
class _SceneUnavailableView extends StatelessWidget {
  const _SceneUnavailableView({
    required this.state,
    required this.onRetry,
    required this.onOpenInStash,
  });

  final SceneState state;
  final VoidCallback onRetry;
  final Future<void> Function(String sceneId) onOpenInStash;

  @override
  Widget build(BuildContext context) {
    if (state.phase == ScenePhase.initial ||
        state.phase == ScenePhase.loading) {
      return Center(
        child: Semantics(
          label: 'Loading scene',
          child: const CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final message =
        state.failure?.userMessage ?? 'This scene could not be loaded.';
    final sceneId = state.sceneId;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
                if (sceneId != null)
                  OutlinedButton(
                    onPressed: () => onOpenInStash(sceneId),
                    child: const Text('Open in Stash'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Overlay shown over the black video surface when
/// `_shouldShowBlockingPlaybackFailure` is true: the scene's own title and
/// metadata toggle stay reachable, per the brief's Step 6 ("leave scene
/// title and metadata button enabled over the black surface"), but via
/// `PlayerTopBar`, still rendered beneath this overlay (a failed,
/// non-playing scene never auto-hides, see `_suppressHide`), rather than
/// a second, duplicate button here.
class _PlaybackFailureOverlay extends StatelessWidget {
  const _PlaybackFailureOverlay({
    required this.title,
    required this.message,
    required this.onRetry,
    required this.onOpenInStash,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenInStash;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 40),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
              OutlinedButton(
                onPressed: onOpenInStash,
                child: const Text('Open in Stash'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Persistent, non-blocking "playback ran into a problem" affordance —
/// fix round 1, item 5 — shown at the top of the stack for as long as
/// `PlaybackPhase.failed` holds in the *non-blocking* case (the video
/// already played once — see `_shouldShowBlockingPlaybackFailure`'s own
/// doc). Unlike the one-shot `SnackBar` this class's own caller also
/// fires, this stays on screen until the user acts (or the scene
/// recovers on its own), so a mid-stream failure is never a dead end
/// with nothing left to press.
class _TransientPlaybackFailureBanner extends StatelessWidget {
  const _TransientPlaybackFailureBanner({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No `Positioned` here (fix round 1 of this task's own review): this is
    // now placed as a `Column` child, immediately below `PlayerTopBar`, by
    // its caller in `_buildSceneStack`; see that call site's own doc for
    // why. A `Positioned` is only valid directly under a `Stack`.
    return SafeArea(
      bottom: false,
      child: Material(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.error_outline,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds the `Shortcuts`/`Actions` composition around `PlayerIntent` that
/// Task 9 deliberately deferred (there was no video region to attach it
/// to yet — see that task's own carried-forward ruling). [controller]'s
/// `handleAction` is the single place every dispatched [PlayerIntent]
/// ends up — `_PlayerCallbackAction.invoke` below calls it directly for
/// every intent this `Shortcuts`/`Actions` composition resolves; there is
/// no other production dispatch path.
///
/// The key→[PlayerIntent] map is built directly from [playerKeyBindings]
/// — `player_shortcuts.dart`'s own doc comment names this as the required
/// single source of truth, so this table can never drift from the
/// mapping `player_shortcuts_test.dart` pins against the Step 2 spec.
/// This class's own dispatch and gating behavior is covered separately,
/// by `scene_screen_test.dart`.
///
/// Text-entry safety (Task 9 finding I7, settled empirically by this
/// task — see `scene_screen_test.dart`'s "text-entry propagation" group):
/// [_PlayerCallbackAction.isEnabled] disables any [PlayerIntent] whose
/// action is bound to a key in [playerTextEntryConflictKeys] while a text
/// field has focus. A disabled action makes `ShortcutManager.handleKeypress`
/// return `KeyEventResult.ignored` rather than `handled` (see
/// `Action.isEnabled`'s own doc in the Flutter SDK), which lets the key
/// event keep bubbling past this `Shortcuts` widget to
/// `DefaultTextEditingShortcuts` (mounted by `WidgetsApp`, above every
/// screen) — exactly the fallback needed for normal typing/cursor
/// movement in a nested text field to keep working. Gating by *action*
/// rather than by literal key here means [PlayerAction.togglePlayPause]
/// — bound to both `space` and `K` — is already disabled while a text
/// field has focus purely because `K` is in [playerTextEntryConflictKeys];
/// `space` being *also* listed there doesn't change this class's own
/// behavior (`scene_screen_test.dart`'s "space does not toggle
/// play/pause" test passes identically either way — this is *not* the
/// reason `space` needed adding). `space`'s membership in
/// [playerTextEntryConflictKeys] is kept for the reason that set's own
/// doc comment gives: `space` has no bound alias the way `K` does, so —
/// independent of `togglePlayPause` already being gated here incidentally
/// via `K` — `space` needs its own entry rather than relying on that
/// alias.
class PlayerActionShortcuts extends StatelessWidget {
  const PlayerActionShortcuts({
    required this.controller,
    required this.child,
    this.onActivity,
    super.key,
  });

  final PlaybackController controller;
  final Widget child;
  final VoidCallback? onActivity;

  static final Map<ShortcutActivator, Intent> _shortcuts = {
    for (final entry in playerKeyBindings.entries)
      LogicalKeySet(entry.key): PlayerIntent(entry.value),
  };

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: _shortcuts,
    child: Actions(
      actions: <Type, Action<Intent>>{
        PlayerIntent: _PlayerCallbackAction(controller, onActivity),
      },
      child: Focus(autofocus: true, child: child),
    ),
  );
}

/// The set of [PlayerAction]s that must yield to normal text editing
/// while a text field has focus — derived from
/// [playerTextEntryConflictKeys] so the two can never drift apart. A key
/// bound to more than one action (there are none today) or an action
/// bound to more than one key (`togglePlayPause`: `space` and `K`) is
/// handled correctly either way, since this operates on the *action*,
/// not the literal key that happened to trigger it.
final Set<PlayerAction> _textEntryConflictActions = {
  for (final key in playerTextEntryConflictKeys) playerKeyBindings[key]!,
};

class _PlayerCallbackAction extends Action<PlayerIntent> {
  _PlayerCallbackAction(this._controller, this._onActivity);

  final PlaybackController _controller;
  final VoidCallback? _onActivity;

  @override
  Object? invoke(PlayerIntent intent) {
    _onActivity?.call();
    unawaited(
      _controller
          .handleAction(intent.action)
          .catchError((Object _, StackTrace _) {}),
    );
    return null;
  }

  @override
  bool isEnabled(PlayerIntent intent) {
    if (intent.action == PlayerAction.exitFullscreen &&
        !_controller.state.fullscreen) {
      return false;
    }
    if (_textEntryConflictActions.contains(intent.action) &&
        _isTextEditingTarget()) {
      return false;
    }
    return true;
  }

  static bool _isTextEditingTarget() {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) return false;
    return focusedContext.findAncestorStateOfType<EditableTextState>() != null;
  }
}
