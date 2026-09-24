import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/system_appearance.dart';
import 'package:stash_player_flutter/features/library/library_screen.dart';
import 'package:stash_player_flutter/ui/theme/app_tokens.dart';
import 'package:stash_player_flutter/ui/widgets/app_toast.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('uses the app title and Material 3', (tester) async {
    await _pumpApp(tester);
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Stash Player');
    // A context *inside* MaterialApp's subtree — MaterialApp's own element
    // sits above the Theme it builds, so Theme.of there would silently
    // fall back to Flutter's default ThemeData instead of this app's.
    expect(
      Theme.of(tester.element(find.text('Connect to Stash'))).useMaterial3,
      isTrue,
    );
  });

  testWidgets(
    'an unconfigured connection bootstraps to the connection screen',
    (tester) async {
      await _pumpApp(tester);
      await tester.pump();

      expect(find.text('Connect to Stash'), findsOneWidget);
    },
  );

  testWidgets('a saved connection bootstraps straight to the library', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
    );
    await tester.pump();

    // The library screen no longer renders a title anywhere (the
    // redesign dropped its `AppBar`), so the widget type is what proves
    // we landed there, not a word it used to show.
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets(
    'renders the same destination at 1000x700 in both light and dark',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 700);

      for (final brightness in [Brightness.light, Brightness.dark]) {
        // Fully unmount before the next pump — MaterialApp otherwise
        // updates its existing element in place and doesn't react to a
        // brightness change that happened between two `pumpWidget` calls
        // on the same tree.
        await tester.pumpWidget(const SizedBox.shrink());
        tester.platformDispatcher.platformBrightnessTestValue = brightness;

        await _pumpApp(
          tester,
          saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
        );
        await tester.pump();

        // The library screen no longer renders a title anywhere (the
        // redesign dropped its `AppBar`), so the widget type is what
        // proves we landed there, not a word it used to show. It also
        // still gives us a context inside the app's live subtree, which
        // is all the checks below actually need.
        expect(find.byType(LibraryScreen), findsOneWidget);
        final context = tester.element(find.byType(LibraryScreen));
        expect(Theme.of(context).brightness, brightness);
        expect(MediaQuery.platformBrightnessOf(context), brightness);
      }
    },
  );
  testWidgets(
    'a bootstrap-failure notice toast resolves the app theme, not the '
    'Material fallback',
    (tester) async {
      await _pumpApp(
        tester,
        loadFuture: Future<ConnectionConfig>.delayed(
          Duration.zero,
          () => throw Exception('disk error'),
        ),
      );
      // One pump to let bootstrap's error path run and the notice/toast
      // appear, a second to let the toast's entrance animation start
      // (short of pumpAndSettle, which would fast-forward through its
      // auto-dismiss timer and remove it from the tree again).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Connect to Stash'), findsOneWidget);
      final toast = tester.widget<AppToast>(find.byType(AppToast));
      final themeContext = tester.element(find.byType(AppToast));
      expect(toast.background, Theme.of(themeContext).colorScheme.error);
      // AppTokens is only registered by this app's real theme, never by
      // the Material fallback ThemeData(), so its presence proves the
      // toast resolved through the app's own Theme, not a default one.
      expect(Theme.of(themeContext).extension<AppTokens>(), isNotNull);
    },
  );

  testWidgets('the OS accent recolours the theme', (tester) async {
    await _pumpApp(
      tester,
      extraOverrides: [
        systemAppearanceProvider.overrideWith(
          (ref) =>
              Stream.value(const SystemAppearance(accent: Color(0xFFE66100))),
        ),
      ],
    );
    await tester.pump();
    // MaterialApp wraps its child in an AnimatedTheme (200ms default), so
    // the new accent only reaches Theme.of() once that transition settles:
    // a bare zero-duration pump leaves Theme.of() reporting the old colour
    // mid-animation.
    await tester.pump(const Duration(milliseconds: 200));

    final theme = Theme.of(tester.element(find.text('Connect to Stash')));
    expect(theme.colorScheme.primary, const Color(0xFFE66100));
  });
}

Future<void> _pumpApp(
  WidgetTester tester, {
  ConnectionConfig saved = const ConnectionConfig(),
  Future<ConnectionConfig>? loadFuture,
  List<Override> extraOverrides = const [],
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      connectionStoreProvider.overrideWithValue(
        FakeConnectionStore(saved: saved, loadFuture: loadFuture),
      ),
      environmentProvider.overrideWithValue(const {}),
      stashApiFactoryProvider.overrideWithValue(
        // No `pages` ever queued: the library's `loadInitial()` is meant
        // to park forever on an unresolved `findScenes` here (see this
        // file's own tests, which only pump a bounded number of frames
        // rather than `pumpAndSettle`) — `allowManualCompletion` opts out
        // of `FakeStashApi`'s drain-safety default so that's still a
        // deliberate hang, not a `StateError`.
        (config) =>
            FakeStashApi(versionValue: 'v0.31.0')..allowManualCompletion = true,
      ),
      connectionControllerOverride,
      ...extraOverrides,
    ],
    child: const StashPlayerApp(),
  ),
);
