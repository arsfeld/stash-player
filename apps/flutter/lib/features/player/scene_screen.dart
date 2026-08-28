import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/notices.dart';
import '../../app/providers.dart';
import '../../domain/scene.dart';
import '../../services/external_url_launcher.dart';
import 'playback_controller.dart';
import 'playback_state.dart';
import 'player_shortcuts.dart';
import 'scene_controller.dart';
import 'scene_metadata_drawer.dart';
import 'transport_controls.dart';
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
  /// being treated as a transient control hiccup that leaves the video
  /// (and transport controls) exactly as they were.
  ///
  /// See hazard #3 in Task 11's brief: `PlaybackController._runEngineCommand`
  /// drives `setVolume`/`toggleMute`/`playPause`/`seekAbsolute` failures
  /// into the *same* terminal `PlaybackPhase.failed` a genuinely-unplayable
  /// scene reaches — and, once failed, nothing in that controller ever
  /// moves `phase` back to `ready` on a later successful command. Since
  /// `playback_controller.dart` is a committed interface this task
  /// consumes rather than modifies, the fix lives here: `duration` is
  /// only ever set once the engine's own `duration` stream has fired at
  /// least once for the current scene (see `PlaybackState.duration`'s own
  /// doc — "no real media has a zero duration"), which only happens after
  /// a *successful* `open()`. So `duration > Duration.zero` is a reliable
  /// proxy for "this scene's video already loaded" — a `failed` phase
  /// reached *after* that point (whether from a real mid-stream break or
  /// a merely-cosmetic failed volume nudge) is treated as non-blocking: a
  /// one-shot warning notice (see the `ref.listen` in [build]) rather than
  /// a full-screen takeover. This can't perfectly distinguish "a volume
  /// nudge failed" from "the stream broke five minutes in", but a
  /// still-rendering video is the right signal either way: the user is
  /// still watching something, and a full error screen over it would be
  /// wrong regardless of which of those two actually happened. Only a
  /// `failed` phase reached *before* any duration was ever established —
  /// the scene never became playable at all — gets the blocking overlay.
  bool _shouldShowBlockingPlaybackFailure(PlaybackState playback) =>
      playback.phase == PlaybackPhase.failed &&
      playback.duration == Duration.zero;

  @override
  Widget build(BuildContext context) {
    final sceneController = ref.watch(sceneControllerProvider);
    final sceneState = sceneController.state;
    final scene = sceneState.scene;

    // `playbackControllerProvider` is deliberately *not* touched at all
    // until a scene has actually loaded: watching it unconditionally
    // would build (and, in production, start) a real `PlaybackEngine`
    // the moment this screen mounts, even for a scene that never gets
    // past `ScenePhase.loading`/`notFound`/`failed` — e.g. every test
    // that mounts this screen without a scene ever resolving, and every
    // real visit to a scene whose metadata fetch itself fails.
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
      final justFailed =
          nextState.phase == PlaybackPhase.failed &&
          _lastPhase != PlaybackPhase.failed;
      _lastPlaying = nextState.playing;
      _lastBuffering = nextState.buffering;
      _lastPhase = nextState.phase;

      if (playingOrBufferingChanged) {
        _registerActivity(nextState);
      }

      if (justFailed && nextState.duration > Duration.zero) {
        // Transient control failure after the video already played — see
        // `_shouldShowBlockingPlaybackFailure`'s own doc. Surfaced
        // non-modally rather than as a full error state.
        ref
            .read(globalNoticeProvider.notifier)
            .show(
              AppNotice(
                message:
                    nextState.failure ?? 'A playback control action failed.',
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
    final effectiveVisible = _controlsVisible;

    return PlayerActionShortcuts(
      controller: playbackController,
      onActivity: () => _registerActivity(playback),
      child: Stack(
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
          // 2. Controls overlay, docked to the bottom, auto-hiding.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !effectiveVisible,
              child: AnimatedOpacity(
                key: const Key('scene-controls-overlay'),
                duration: _fadeDuration,
                opacity: effectiveVisible ? 1 : 0,
                child: MouseRegion(
                  onEnter: (_) => _setHovering(true, playback),
                  onExit: (_) => _setHovering(false, playback),
                  child: FocusScope(
                    onFocusChange: (value) =>
                        _setControlsFocused(value, playback),
                    child: TransportControls(
                      playback: playback,
                      title: scene.displayTitle,
                      metadataOpen: _metadataOpen,
                      onBack: () => Navigator.of(context).maybePop(),
                      onTogglePlayPause: playbackController.playPause,
                      onSeek: playbackController.seekAbsolute,
                      onVolumeChanged: playbackController.setVolume,
                      onToggleMute: playbackController.toggleMute,
                      onToggleFullscreen: () => playbackController
                          .setFullscreen(!playback.fullscreen),
                      onToggleMetadata: () => _toggleMetadata(playback),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 3. Metadata drawer, aligned right, capped at 420 logical
          // pixels, sliding over the video rather than reflowing it. A
          // `Positioned` (top/right/bottom pinned, explicit width) rather
          // than `Align` — `Align` only gives loose constraints, which
          // would shrink-wrap the drawer's height to its content instead
          // of spanning the full screen.
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: SceneMetadataDrawer.maxWidth,
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
        ],
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
/// title and metadata button enabled over the black surface") — but via
/// `TransportControls`, still rendered beneath this overlay (a failed,
/// non-playing scene never auto-hides — see `_suppressHide`), rather than
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

/// Builds the `Shortcuts`/`Actions` composition around `PlayerIntent` that
/// Task 9 deliberately deferred (there was no video region to attach it
/// to yet — see that task's own carried-forward ruling). [controller]'s
/// `handleAction` is the single place every dispatched [PlayerIntent]
/// ends up, exactly like `dispatchPlayerKeyEvent`'s own callers.
///
/// The key→[PlayerIntent] map is built directly from [playerKeyBindings]
/// — `player_shortcuts.dart`'s own doc comment names this as the required
/// single source of truth so this table and `dispatchPlayerKeyEvent`
/// (exercised independently by `player_shortcuts_test.dart`) can never
/// drift apart.
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
/// rather than by literal key is deliberate: [PlayerAction.togglePlayPause]
/// is bound to both `space` and `K`, and a text field must swallow neither
/// (space should insert a space character, not toggle playback) — see
/// `scene_screen_test.dart` for the empirical proof this covers `space`
/// correctly too, which is why [playerTextEntryConflictKeys] needed
/// widening (see that set's own updated doc comment).
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
