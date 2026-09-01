import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stash_player_flutter/main.dart' as app;

/// Task 12's connection-to-scene smoke test: boots the *real* app (the
/// same `main()` production runs, not a hand-wired `ProviderScope`)
/// against the repository mock Stash server, and walks connection →
/// library → search filter → scene navigation → a recoverable playback
/// failure.
///
/// This is deliberately not a playback test: `tools/mock-stash/server.py`
/// keeps `/stream` a documented 404 by design (see its own docstring), so
/// the scene screen's blocking failure overlay — with its "Retry"
/// affordance — is the *expected* outcome here, not a bug. Real hardware
/// decode/audio/seek validation lives in `docs/flutter-runtime-validation.md`
/// against a real Stash instance; this test only proves the wiring
/// between the connection flow, the library, and the scene screen works
/// end-to-end against a real (if video-less) GraphQL backend.
///
/// Requires, per `apps/flutter/README.md`'s "Run the integration smoke
/// test" section:
///   - `tools/mock-stash/server.py` already running and reachable at
///     `STASH_URL` (started, health-checked, and torn down by the
///     caller — see that doc and `.github/workflows/flutter.yml` for the
///     exact shape). Note that a real Stash instance commonly occupies
///     port 9999 on a dev machine — see that same README section for
///     running both the mock and this test on an alternate port.
///   - `STASH_URL=http://127.0.0.1:9999` and an explicitly empty
///     `STASH_API_KEY` in the test process's environment — both read
///     directly from `Platform.environment` by `environmentProvider` and
///     overlaid onto (and overriding) whatever this machine has
///     persisted, per `overlayEnvironment`'s documented precedence. An
///     empty `STASH_API_KEY` is a deliberate, valid override for an
///     unauthenticated dev server — it is never persisted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'connects over the mock server, filters the library, opens a scene, '
    'and surfaces a recoverable playback failure',
    (tester) async {
      // Boots the app exactly the way `flutter run` does: GStreamer/
      // media_kit native init, real platform connection store (Secret
      // Service on Linux / Keychain on macOS), real `HttpStashApi` — no
      // fakes, no provider overrides. `STASH_URL`/`STASH_API_KEY` from
      // the process environment take the app straight to the library,
      // skipping the first-launch connection screen (see
      // `AppController.bootstrap`).
      await app.main();
      await tester.pumpAndSettle();

      expect(find.text('Aurora Over Tromsø'), findsOneWidget);

      // Stable widget key (Task 7), not a text lookup — the search field
      // has no visible label text that would work as a finder.
      await tester.enterText(find.byKey(const Key('library-search')), 'Kyoto');
      // `LibraryToolbar` debounces search input by 250ms before it
      // forwards the query — see `_LibraryToolbarState._onSearchChanged`.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('Kyoto Cherry Blossoms'), findsOneWidget);
      await tester.tap(find.text('Kyoto Cherry Blossoms'));

      // Deliberately NOT `pumpAndSettle()` here — see `_pumpUntilFound`'s
      // own doc for why. This is a durable characteristic of *any*
      // integration test that reaches the scene screen with the real
      // playback engine, not a one-off for this test: the same note
      // lives in `apps/flutter/README.md`'s troubleshooting section for
      // whoever writes the next one.
      //
      // The mock's `/stream` 404s before any duration is ever
      // established, which `SceneScreen` treats as a full failure to
      // load (never-played) rather than a transient in-scene hiccup —
      // see `_SceneScreenState._shouldShowBlockingPlaybackFailure` — so
      // exactly one blocking "Retry" affordance lands on screen, not the
      // separate persistent non-blocking banner Task 11 also added.
      await _pumpUntilFound(tester, find.text('Retry'));
      expect(find.text('Retry'), findsOneWidget);

      // The metadata-drawer toggle in the top bar overlay — present
      // regardless of the blocking failure overlay above, since it lives
      // in its own layer of the scene screen's stack. Found by tooltip
      // because the icon button carries no visible text label and has no
      // dedicated `Key` of its own to prefer instead (see
      // `player_top_bar.dart`). Deviation from this task's brief, which
      // named the tooltip text as "Show scene information": that string
      // does not exist anywhere in this codebase or its history — Task
      // 11 shipped "Show details"/"Hide details" (`player_top_bar.dart`),
      // and `scene_screen_test.dart` already asserts that exact string.
      // Fixed here rather than in the widget: `player_top_bar.dart`
      // isn't in this task's file list, and the shipped string is a
      // legitimate, already-tested finder.
      expect(find.byTooltip('Show details'), findsOneWidget);
    },
  );
}

/// Pumps in bounded steps until [finder] resolves to at least one widget,
/// or [timeout] elapses — whichever comes first. Fails the test (via
/// [fail], not a fall-through assertion) if [timeout] is reached without
/// [finder] ever matching.
///
/// Exists because `WidgetTester.pumpAndSettle()` cannot be used once the
/// scene screen is on screen: the instant it mounts, the real
/// `MediaKitPlaybackEngine` opens a `package:media_kit` `Player` against
/// the scene's (here, 404ing) stream URL, which allocates a live native
/// video texture immediately — independent of whether the stream ever
/// actually starts playing (confirmed via this test's own development:
/// the log shows `NativeVideoController: Texture ID: ...` printed right
/// after the tap, before any failure is reported). A live `Texture`
/// widget continuously requests new frames on this platform, so
/// `SchedulerBinding` never reports "no frame scheduled" —
/// `pumpAndSettle()` doesn't fail fast, it runs to its full default
/// 10-minute timeout and then throws. This reproduced as a clean,
/// consistent hang (not a flake) while writing this test. Every future
/// integration test that navigates into the scene screen needs the same
/// treatment; see the matching note in `apps/flutter/README.md`'s
/// troubleshooting section.
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(
    'Timed out after $timeout waiting for '
    '${finder.describeMatch(Plurality.many)} to appear.',
  );
}
