import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/app_menu_bar.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/features/player/playback_controller.dart';
import 'package:stash_player_flutter/features/player/playback_menu.dart';

import '../support/fake_playback_engine.dart';

void main() {
  test('the bar is app, Edit, Playback, Window, in that order', () {
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      onCheckForUpdates: () {},
      onOpenSettings: null,
    );
    expect(bar.cast<PlatformMenu>().map((m) => m.label), [
      'Stash Player',
      'Edit',
      'Playback',
      'Window',
    ]);
  });

  test('the app menu checks for updates', () {
    var checked = 0;
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      onCheckForUpdates: () => checked++,
      onOpenSettings: null,
    );
    final app = bar.first as PlatformMenu;
    final item = app.menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .whereType<PlatformMenuItem>()
        .singleWhere((item) => item.label == 'Check for Updates…');
    item.onSelected!();
    expect(checked, 1);
  });

  test('Edit carries the standard key equivalents', () {
    final bar = buildMacMenuBar(
      playback: playbackMenu(null, (_) {}),
      onCheckForUpdates: () {},
      onOpenSettings: null,
    );
    final edit = bar[1] as PlatformMenu;
    final shortcuts = edit.menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .cast<PlatformMenuItem>()
        .map((item) => (item.shortcut! as SingleActivator).trigger);
    expect(shortcuts, [
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyA,
    ]);
  });

  testWidgets('only macOS gets a PlatformMenuBar', (tester) async {
    final sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.menu, (call) async {
          sent.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, null),
    );

    await tester.pumpWidget(
      const ProviderScope(child: AppMenuBar(child: SizedBox())),
    );
    expect(find.byType(PlatformMenuBar), findsNothing);
    expect(sent.where((c) => c.method == 'Menu.setMenus'), isEmpty);

    // `addTearDown` alone isn't enough here: `TestWidgetsFlutterBinding`
    // asserts `debugDefaultTargetPlatformOverride == null` immediately
    // after the test body returns, which is *before* `addTearDown`
    // callbacks run (they fire from `package:test`'s own teardown, one
    // level further out) — verified empirically, the override has to be
    // back to null by the time this function returns, not merely by the
    // time the test finishes. `try`/`finally` guarantees that on every
    // path, including a failed `expect` below, the same protection
    // `addTearDown` is for (never leaking the override into the next
    // test) plus passing this test's own invariant check.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: AppMenuBar(child: SizedBox(key: Key('x'))),
        ),
      );
      expect(find.byType(PlatformMenuBar), findsOneWidget);
      expect(sent.where((c) => c.method == 'Menu.setMenus'), isNotEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'a position-only notification does not resend the menu bar, but a '
    'shown-state change does',
    (tester) async {
      final sent = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, (call) async {
            sent.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.menu, null),
      );
      int setMenusCount() =>
          sent.where((c) => c.method == 'Menu.setMenus').length;

      final engine = FakePlaybackEngine();
      final controller = PlaybackController(
        engine: engine,
        resolveConnection: () async =>
            const ConnectionConfig(serverUrl: 'https://stash.test'),
        setFullscreenPlatform: (value) async => true,
      );
      addTearDown(controller.dispose);
      await controller.loadScene(
        Scene(
          id: 's1',
          paths: const ScenePaths(stream: 'stream.mp4'),
        ),
      );

      final providerScope = ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(
            () => _FixedDestinationController(const AppDestination.scene('s1')),
          ),
          playbackControllerProvider.overrideWith((ref) => controller),
        ],
        child: const AppMenuBar(child: SizedBox()),
      );

      // `variant:` (rather than setting `debugDefaultTargetPlatformOverride`
      // directly) sets and resets it around this whole test body via a
      // `try`/`finally` of its own, one level in from `package:test`'s
      // `addTearDown` — see the "only macOS..." test above for why that
      // distinction matters here.
      await tester.pumpWidget(providerScope);
      final afterMount = setMenusCount();
      expect(afterMount, greaterThan(0));

      // Position/buffered events fire many times a second during real
      // playback; neither field the menu bar shows
      // (playing/muted) changes, so this must not resend the
      // menu bar to AppKit.
      engine.emitPosition(const Duration(seconds: 5));
      engine.emitBuffered(const Duration(seconds: 10));
      await tester.pump();
      expect(
        setMenusCount(),
        afterMount,
        reason: 'a position/buffered-only change must not resend the menu',
      );

      // Muted is one of the two shown fields, so toggling it must.
      await controller.toggleMute();
      await tester.pump();
      expect(
        setMenusCount(),
        greaterThan(afterMount),
        reason: 'a shown-state change must resend the menu',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  test('the app menu opens Settings… with ⌘,', () {
    var opened = 0;
    final item = _appMenuItem(
      buildMacMenuBar(
        playback: playbackMenu(null, (_) {}),
        onCheckForUpdates: () {},
        onOpenSettings: () => opened++,
      ),
      'Settings…',
    );

    final shortcut = item.shortcut! as SingleActivator;
    expect(shortcut.trigger, LogicalKeyboardKey.comma);
    expect(shortcut.meta, isTrue);
    item.onSelected!();
    expect(opened, 1);
  });

  testWidgets('Settings… is enabled on the library only, and not while its own '
      'dialog is already open (final review §5)', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.menu, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, null),
    );

    Future<PlatformMenuItem> settingsAt(AppDestination destination) async {
      // Pumping an unrelated widget first, before the real tree, forces
      // `finalizeTree()` to dispose any `PlatformMenuBar` left over from a
      // previous call in this test (its `State.dispose` only runs there,
      // never in the same `pumpWidget` call that deactivates it). Without
      // this, a second `PlatformMenuBar` mounting while the first is still
      // deactivated-but-undisposed trips its debug lock
      // (`debugLockDelegate`), since both would hold it at once.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            appControllerProvider.overrideWith(
              () => _FixedDestinationController(destination),
            ),
          ],
          child: const AppMenuBar(child: SizedBox()),
        ),
      );
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      return _appMenuItem(bar.menus, 'Settings…');
    }

    expect(
      (await settingsAt(const AppDestination.connection())).onSelected,
      isNull,
    );

    expect(
      (await settingsAt(
        const LibraryDestination(settingsOpen: true),
      )).onSelected,
      isNull,
    );

    final item = await settingsAt(const AppDestination.library());
    item.onSelected!();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppMenuBar)),
    );
    expect(
      container.read(appControllerProvider),
      const LibraryDestination(settingsOpen: true),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

/// A test-only `AppController` that always starts at whatever
/// [AppDestination] it is built with, matching `app_router_test.dart`'s
/// helper of the same name (private to each file, so not shared).
class _FixedDestinationController extends AppController {
  _FixedDestinationController(this._destination);

  final AppDestination _destination;

  @override
  AppDestination build() => _destination;
}

/// The app menu's item labelled [label].
PlatformMenuItem _appMenuItem(List<PlatformMenuItem> bar, String label) =>
    (bar.first as PlatformMenu).menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .singleWhere((item) => item.label == label);
