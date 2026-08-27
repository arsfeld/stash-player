import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_engine.dart';
import 'package:stash_player_flutter/features/player/playback_state.dart';
import 'package:stash_player_flutter/features/player/player_shortcuts.dart';

import '../../support/fake_playback_engine.dart';

/// The exact Step 2 keyboard mapping table, reproduced independently of
/// `playerKeyBindings` so this test is a genuine check against the spec
/// rather than the production map trivially matching itself.
// Not `const`: see `player_shortcuts.dart`'s own note on why maps/sets
// keyed by `LogicalKeyboardKey` can't be const.
final _expectedBindings = <LogicalKeyboardKey, PlayerAction>{
  LogicalKeyboardKey.space: PlayerAction.togglePlayPause,
  LogicalKeyboardKey.keyK: PlayerAction.togglePlayPause,
  LogicalKeyboardKey.arrowLeft: PlayerAction.seekBackward5,
  LogicalKeyboardKey.arrowRight: PlayerAction.seekForward5,
  LogicalKeyboardKey.keyJ: PlayerAction.seekBackward10,
  LogicalKeyboardKey.keyL: PlayerAction.seekForward10,
  LogicalKeyboardKey.arrowDown: PlayerAction.seekBackward60,
  LogicalKeyboardKey.arrowUp: PlayerAction.seekForward60,
  LogicalKeyboardKey.home: PlayerAction.seekToStart,
  LogicalKeyboardKey.end: PlayerAction.seekToEnd,
  LogicalKeyboardKey.digit9: PlayerAction.volumeDown,
  LogicalKeyboardKey.digit0: PlayerAction.volumeUp,
  LogicalKeyboardKey.keyM: PlayerAction.toggleMute,
  LogicalKeyboardKey.keyF: PlayerAction.toggleFullscreen,
  LogicalKeyboardKey.escape: PlayerAction.exitFullscreen,
};

const _config = ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'k');

KeyDownEvent _keyDown(LogicalKeyboardKey key) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

PlaybackController _buildController({
  required PlaybackEngine engine,
  Future<bool> Function(bool fullscreen)? setFullscreenPlatform,
}) => PlaybackController(
  engine: engine,
  resolveConnection: () async => _config,
  setFullscreenPlatform: setFullscreenPlatform ?? (value) async => true,
);

Scene _scene() => Scene(
  id: 's',
  paths: const ScenePaths(stream: 'stream.mp4'),
);

/// A [PlaybackEngine] wrapping a [FakePlaybackEngine] whose `play()`
/// always throws — used to prove (I6) that a shortcut dispatching a
/// command whose engine call fails never escapes as an unhandled zone
/// error, end to end through `dispatchPlayerKeyEvent`'s own
/// unawaited-but-`catchError`-guarded call.
class _AlwaysThrowsOnPlayEngine implements PlaybackEngine {
  _AlwaysThrowsOnPlayEngine(this._inner);

  final FakePlaybackEngine _inner;

  @override
  Stream<bool> get playing => _inner.playing;

  @override
  Stream<bool> get buffering => _inner.buffering;

  @override
  Stream<Duration> get position => _inner.position;

  @override
  Stream<Duration> get duration => _inner.duration;

  @override
  Stream<String> get errors => _inner.errors;

  @override
  Widget buildVideoSurface({Key? key}) => _inner.buildVideoSurface(key: key);

  @override
  Future<void> open(Uri uri, {bool play = false}) =>
      _inner.open(uri, play: play);

  @override
  Future<void> play() async => throw StateError('engine play() failed');

  @override
  Future<void> pause() => _inner.pause();

  @override
  Future<void> seek(Duration position) => _inner.seek(position);

  @override
  Future<void> setVolume(double zeroToOne) => _inner.setVolume(zeroToOne);

  @override
  Future<void> setMuted(bool muted) => _inner.setMuted(muted);

  @override
  Future<void> dispose() => _inner.dispose();
}

void main() {
  test('playerKeyBindings matches the exact Step 2 table', () {
    expect(playerKeyBindings, _expectedBindings);
  });

  group('exact keyboard mapping table dispatches the right action', () {
    for (final entry in _expectedBindings.entries) {
      test('${entry.key.debugName} -> ${entry.value.name}', () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_scene());
        engine.emitDuration(const Duration(seconds: 1000));
        await controller.seekAbsolute(const Duration(seconds: 100));
        await controller.setVolume(0.5);
        if (entry.value == PlayerAction.exitFullscreen) {
          await controller.setFullscreen(true);
        }
        engine.commands.clear();

        final result = dispatchPlayerKeyEvent(
          _keyDown(entry.key),
          controller: controller,
          isModifierPressed: () => false,
        );
        expect(result, KeyEventResult.handled);
        // dispatchPlayerKeyEvent fires handleAction without awaiting it
        // (matching how a real onKeyEvent callback must return
        // synchronously) — let its async work settle before asserting.
        await pumpEventQueue();

        switch (entry.value) {
          case PlayerAction.togglePlayPause:
            expect(engine.commands.whereType<PlayCommand>(), hasLength(1));
          case PlayerAction.seekBackward5:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 95),
            );
          case PlayerAction.seekForward5:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 105),
            );
          case PlayerAction.seekBackward10:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 90),
            );
          case PlayerAction.seekForward10:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 110),
            );
          case PlayerAction.seekBackward60:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 40),
            );
          case PlayerAction.seekForward60:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 160),
            );
          case PlayerAction.seekToStart:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              Duration.zero,
            );
          case PlayerAction.seekToEnd:
            expect(
              engine.commands.whereType<SeekCommand>().single.position,
              const Duration(seconds: 1000),
            );
          case PlayerAction.volumeDown:
            expect(controller.state.volume, closeTo(0.45, 1e-9));
          case PlayerAction.volumeUp:
            expect(controller.state.volume, closeTo(0.55, 1e-9));
          case PlayerAction.toggleMute:
            expect(
              engine.commands.whereType<SetMutedCommand>().single.muted,
              isTrue,
            );
          case PlayerAction.toggleFullscreen:
            expect(controller.state.fullscreen, isTrue);
          case PlayerAction.exitFullscreen:
            expect(controller.state.fullscreen, isFalse);
        }
      });
    }
  });

  group('non-matching input is ignored', () {
    test('a key-up event is ignored', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_scene());

      final event = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyK,
        logicalKey: LogicalKeyboardKey.keyK,
        timeStamp: Duration.zero,
      );
      final result = dispatchPlayerKeyEvent(
        event,
        controller: controller,
        isModifierPressed: () => false,
      );

      expect(result, KeyEventResult.ignored);
    });

    test('a modified keystroke is ignored even for a bound key', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_scene());
      engine.commands.clear();

      final result = dispatchPlayerKeyEvent(
        _keyDown(LogicalKeyboardKey.keyK),
        controller: controller,
        isModifierPressed: () => true,
      );

      expect(result, KeyEventResult.ignored);
      await pumpEventQueue();
      expect(engine.commands, isEmpty);
    });

    test('an unbound key is ignored', () async {
      final engine = FakePlaybackEngine();
      final controller = _buildController(engine: engine);
      await controller.loadScene(_scene());
      engine.commands.clear();

      final result = dispatchPlayerKeyEvent(
        _keyDown(LogicalKeyboardKey.keyZ),
        controller: controller,
        isModifierPressed: () => false,
      );

      expect(result, KeyEventResult.ignored);
      await pumpEventQueue();
      expect(engine.commands, isEmpty);
    });
  });

  group('exitFullscreen outside fullscreen', () {
    test(
      'Escape does nothing, and is reported ignored, when not fullscreen',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_scene());
        engine.commands.clear();

        final result = dispatchPlayerKeyEvent(
          _keyDown(LogicalKeyboardKey.escape),
          controller: controller,
          isModifierPressed: () => false,
        );

        expect(result, KeyEventResult.ignored);
        await pumpEventQueue();
        expect(controller.state.fullscreen, isFalse);
      },
    );
  });

  group('text-entry escape hatch', () {
    for (final key in playerTextEntryConflictKeys) {
      test(
        '${key.debugName} is ignored while an editable field has focus',
        () async {
          final engine = FakePlaybackEngine();
          final controller = _buildController(engine: engine);
          await controller.loadScene(_scene());
          engine.commands.clear();

          final result = dispatchPlayerKeyEvent(
            _keyDown(key),
            controller: controller,
            isTextEditingTarget: true,
            isModifierPressed: () => false,
          );

          expect(result, KeyEventResult.ignored);
          await pumpEventQueue();
          expect(engine.commands, isEmpty);
        },
      );
    }

    test(
      'keys outside the conflict set still fire while editing text',
      () async {
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_scene());
        engine.emitDuration(const Duration(seconds: 1000));
        engine.commands.clear();

        final result = dispatchPlayerKeyEvent(
          _keyDown(LogicalKeyboardKey.arrowLeft),
          controller: controller,
          isTextEditingTarget: true,
          isModifierPressed: () => false,
        );

        expect(result, KeyEventResult.handled);
        await pumpEventQueue();
        expect(engine.commands.whereType<SeekCommand>(), isNotEmpty);
      },
    );

    test('the conflict set is exactly J/K/L/M/F', () {
      expect(playerTextEntryConflictKeys, {
        LogicalKeyboardKey.keyJ,
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyM,
        LogicalKeyboardKey.keyF,
      });
    });
  });

  group(
    'default modifier detection reads the ambient HardwareKeyboard state',
    () {
      // Exercises the *default* `isModifierPressed` argument (every other
      // test in this file passes an explicit override). Plain `test()`,
      // not `testWidgets()`: an earlier version of this group drove a
      // full widget tree through `tester.sendKeyDownEvent`/
      // `sendKeyUpEvent` inside `testWidgets`, which hung for the entire
      // 10-minute test timeout. This dispatcher is a synchronous pure
      // function with no `Actions`/`Focus`/`Shortcuts` tree anywhere, so
      // there was nothing for a widget pump to matter to in the first
      // place — `pumpEventQueue()` inside `testWidgets`'s fake-async zone
      // never completes unless `tester.pump()` advances the fake clock,
      // which is almost certainly what actually hung.
      // `TestWidgetsFlutterBinding.ensureInitialized()` alone is enough
      // to give `HardwareKeyboard.instance` a live binding to read,
      // without any of that machinery.
      tearDown(() => HardwareKeyboard.instance.clearState());

      test('no modifiers held: a bound key is handled', () {
        TestWidgetsFlutterBinding.ensureInitialized();
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);

        final result = dispatchPlayerKeyEvent(
          _keyDown(LogicalKeyboardKey.keyK),
          controller: controller,
        );

        expect(result, KeyEventResult.handled);
      });

      test('a real Ctrl held via HardwareKeyboard is detected as modified '
          '(I3: proves the *detection*, not just the injected-boolean '
          'branch — emptying _modifierKeys, or swapping it for just '
          '{shift}, would still pass every other test in this file but '
          'must fail this one)', () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final engine = FakePlaybackEngine();
        final controller = _buildController(engine: engine);
        await controller.loadScene(_scene());
        engine.commands.clear();

        await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
        final whileHeld = dispatchPlayerKeyEvent(
          _keyDown(LogicalKeyboardKey.keyK),
          controller: controller,
        );
        expect(whileHeld, KeyEventResult.ignored);
        expect(engine.commands, isEmpty);

        await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // Once released, the same key dispatches normally again —
        // confirming the ignore above was really about Ctrl still
        // being held, not some other reason.
        final afterRelease = dispatchPlayerKeyEvent(
          _keyDown(LogicalKeyboardKey.keyK),
          controller: controller,
        );
        expect(afterRelease, KeyEventResult.handled);
      });
    },
  );

  group('engine command failures do not escape as unhandled errors (I6)', () {
    test('a shortcut whose engine command throws is caught, not left '
        'unhandled by the dispatch site\'s catchError', () async {
      final inner = FakePlaybackEngine();
      final engine = _AlwaysThrowsOnPlayEngine(inner);
      final controller = _buildController(engine: engine);
      await controller.loadScene(_scene());

      Object? uncaught;
      await runZonedGuarded(() async {
        final result = dispatchPlayerKeyEvent(
          _keyDown(LogicalKeyboardKey.keyK),
          controller: controller,
          isModifierPressed: () => false,
        );
        expect(result, KeyEventResult.handled);
        await pumpEventQueue();
      }, (error, stackTrace) => uncaught = error);

      expect(uncaught, isNull);
      expect(controller.state.phase, PlaybackPhase.failed);
    });
  });
}
