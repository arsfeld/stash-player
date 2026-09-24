# Settings Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-screen connection settings page with a modal dialog that is drawn in Flutter but shaped like each platform's own (an `AdwDialog`-style card with a header bar on Linux, a window sheet on macOS). It opens from the macOS app menu's "Settings…" (⌘,) and from a GNOME primary menu plus Ctrl+, on Linux.

**Architecture:** Whether settings is open becomes router state: `LibraryDestination.settingsOpen`, flipped by `AppController.openSettings()`/`closeSettings()`. `AppRouter` stacks an `AppDialogPage` over the library page while the flag is set. A new drawn `AppDialog` (`lib/ui/widgets/app_dialog.dart`) plus `AppPreferencesGroup`/`AppEntryRow` (`lib/ui/widgets/app_form.dart`) give the per-dialect shapes. The connection form's fields and load-seeding move into `ConnectionFields` and a `ConnectionForm` widget, which both the first-launch `ConnectionScreen` and the new `ConnectionSettingsDialog` use.

**Tech Stack:** Flutter 3 / Dart 3.11, Riverpod 2.6 (`Notifier`, `ChangeNotifierProvider`), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-24-settings-dialog-design.md`

## Global Constraints

- All code is under `apps/flutter/`. Run every command from `apps/flutter/` inside `nix develop .#flutter` (e.g. `nix develop .#flutter -c flutter test test/app/app_controller_test.dart`), or use `just flutter-check` from the repo root.
- `just flutter-check` (format + `flutter analyze --fatal-infos --fatal-warnings` + `flutter test`) must pass at the end of every task.
- Dialect comes from `PlatformDialect.of(context)` (`lib/ui/theme/platform_dialect.dart`), never `Platform.isMacOS`. `flutter_test` runs as Android, so tests get the **Adwaita** dialect unless they pin macOS with `TargetPlatformVariant.only(TargetPlatform.macOS)` or `buildAppTheme(Brightness.light, platform: TargetPlatform.macOS)`.
- `lib/ui/` must not import Riverpod or anything under `lib/app/`, `lib/features/`, `lib/services/`.
- No `Icons.*` in `lib/` (a test enforces this). Use `AppIcon`/`AppIconView`.
- The dialog is drawn, not native: no platform views, no new method channels.
- User-facing copy, exactly:
  - The dialog title is `Connection`, and its buttons are `Cancel` and `Save`.
  - The first-launch button is `Connect`.
  - The row labels are `Server URL`, `API key` and `SOCKS5 proxy`. The last two have the hint `Optional`.
  - The group titles are `Server` and `Network`.
  - The Network description is `Reach Stash through a SOCKS5 proxy, for a server only routable that way. Tailscale in userspace mode listens on 127.0.0.1:1055.`
  - The macOS menu item is `Settings…`, with the Unicode ellipsis.
  - The Linux menu button's tooltip is `Main Menu` and its semantics label is `Main menu`. Its one item is `Preferences`.
- Test keys stay `connection-server-url`, `connection-api-key` and `connection-socks-proxy`, on the `TextField`s.
- Comment style matches the surrounding code: explain *why*, in full sentences, no em dashes in new comments.
- If `flutter analyze` reports `unnecessary_import` or `unused_import` for an import listed here, drop it.
- Commit after each task with a conventional message (`feat(flutter): …`, `refactor(flutter): …`). Don't push.

## File Structure

| File | Responsibility |
|---|---|
| `lib/app/app_controller.dart` (modify) | `LibraryDestination.settingsOpen`, `openSettings()`, `closeSettings()` |
| `lib/ui/widgets/app_dialog.dart` (new) | `AppDialog`, `AppDialogAction`, `AppDialogPage` |
| `lib/ui/widgets/app_form.dart` (new) | `AppPreferencesGroup`, `AppEntryRow` |
| `lib/features/connection/connection_form.dart` (new) | `ConnectionFields` (text state and seeding), `ConnectionForm` (the grouped fields and errors) |
| `lib/features/connection/connection_settings_dialog.dart` (new) | `ConnectionSettingsDialog`: `AppDialog` + `ConnectionForm`, Save → `testAndSave` → `replaceConnection` |
| `lib/features/connection/connection_screen.dart` (rewrite) | The first-launch page only |
| `lib/app/app_router.dart` (modify) | Settings page from state, drops `_SettingsRoute`/`_LibraryRoute` |
| `lib/features/library/library_toolbar.dart` (modify) | The gear becomes the Linux main menu, and is hidden on macOS |
| `lib/features/library/library_screen.dart` (modify) | Drops `onOpenSettings`, adds the Ctrl+, handler |
| `lib/ui/icons/app_icons.dart`, `tool/fetch_icons.py`, `assets/icons/*` (modify) | `AppIcon.settings` → `AppIcon.mainMenu` |
| `lib/app/app_menu_bar.dart` (modify) | macOS "Settings…" ⌘, |
| `README.md`, `apps/flutter/README.md`, `CLAUDE.md` (modify) | Copy and architecture notes |

---

### Task 1: Settings as router state in `AppController`

**Files:**
- Modify: `lib/app/app_controller.dart`
- Test: `test/app/app_controller_test.dart`

**Interfaces:**
- Produces:
  - `LibraryDestination({bool settingsOpen = false})`, with `final bool settingsOpen` and value `==`/`hashCode`.
  - `void AppController.openSettings()`: acts only from `LibraryDestination`.
  - `void AppController.closeSettings()`: acts only from `LibraryDestination(settingsOpen: true)`.
  - `const AppDestination.library()` still means `settingsOpen: false`.

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/app/app_controller_test.dart`, after the last existing test. `buildContainer` is the helper already defined at the top of `main()`.

```dart
  group('settings dialog', () {
    test('opens over the library and closes back to it', () async {
      final container = buildContainer(
        saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
      ).container;
      final app = container.read(appControllerProvider.notifier);
      await app.bootstrap();

      app.openSettings();
      expect(
        container.read(appControllerProvider),
        const LibraryDestination(settingsOpen: true),
      );

      app.closeSettings();
      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
    });

    test('does nothing away from the library', () async {
      final container = buildContainer().container;
      final app = container.read(appControllerProvider.notifier);
      await app.bootstrap();

      app.openSettings();
      expect(
        container.read(appControllerProvider),
        const AppDestination.connection(),
      );

      app.openScene('1');
      app.openSettings();
      expect(
        container.read(appControllerProvider),
        const AppDestination.scene('1'),
      );
    });

    test('a successful replaceConnection closes it', () async {
      final container = buildContainer(
        saved: const ConnectionConfig(serverUrl: 'https://stash.test'),
      ).container;
      final app = container.read(appControllerProvider.notifier);
      await app.bootstrap();
      app.openSettings();

      await app.replaceConnection(
        const ConnectionConfig(serverUrl: 'https://new.test'),
      );

      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/app/app_controller_test.dart`
Expected: compile errors: `No named parameter with the name 'settingsOpen'` and `The method 'openSettings' isn't defined`.

- [ ] **Step 3: Implement**

In `lib/app/app_controller.dart`, replace the `LibraryDestination` class with:

```dart
final class LibraryDestination extends AppDestination {
  const LibraryDestination({this.settingsOpen = false});

  /// Whether the connection settings dialog is showing over the library.
  ///
  /// Part of the destination rather than an imperative dialog push so the
  /// three ways in (the Linux main menu, Ctrl+, and the macOS menu bar,
  /// which sits above the `Navigator` and has no context to push from)
  /// all go through one method, and so a successful reconnect, which
  /// already sets `library()`, closes the dialog without a separate pop.
  final bool settingsOpen;

  @override
  bool operator ==(Object other) =>
      other is LibraryDestination && other.settingsOpen == settingsOpen;

  @override
  int get hashCode => settingsOpen.hashCode;
}
```

In the same file, replace the `AppController` class doc comment's first paragraph with:

```dart
/// Owns which [AppDestination] is showing, and the shell-level intents
/// that change it: the app's initial bootstrap, opening and closing the
/// connection settings dialog, and replacing the active connection from
/// that dialog (or from the first-launch connection screen).
```

In `replaceConnection`'s doc comment, change "Used both by the first-launch connection screen and by the settings screen's success callback." to "Used both by the first-launch connection screen and by the settings dialog once its test succeeds." Also change the phrase `"Test connection" button` in the same comment to `"Connect" button`.

Add these methods to `AppController`, after `showLibrary()`:

```dart
  /// Shows the connection settings dialog over the library.
  ///
  /// Only the library has a way into settings, so this does nothing from
  /// any other destination: the macOS menu item is disabled there, and a
  /// stray call must not yank the player away mid-scene.
  void openSettings() {
    if (state is! LibraryDestination) return;
    state = const LibraryDestination(settingsOpen: true);
  }

  /// Closes the settings dialog without changing the connection.
  ///
  /// A no-op unless the dialog is open, because `AppRouter` also calls
  /// this when the dialog's page leaves the stack for any reason, including
  /// the successful reconnect that already reset the destination.
  void closeSettings() {
    if (state case LibraryDestination(settingsOpen: true)) {
      state = const AppDestination.library();
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/app/`
Expected: all pass, including the existing router and menu bar tests, which compare against `const AppDestination.library()`.

- [ ] **Step 5: Commit**

```bash
git add lib/app/app_controller.dart test/app/app_controller_test.dart
git commit -m "feat(flutter): track the settings dialog in AppController"
```

---

### Task 2: Drawn `AppDialog`, `AppDialogPage` and form rows

**Files:**
- Create: `lib/ui/widgets/app_dialog.dart`
- Create: `lib/ui/widgets/app_form.dart`
- Test: `test/ui/widgets/app_dialog_test.dart`
- Test: `test/ui/widgets/app_form_test.dart`

**Interfaces:**
- Consumes: `AppTokens.of(context)` (`radiusPanel`, `controlSurface`, spacing consts, `macOSStripHeight`), `PlatformDialect.of(context)`, `AppSpinner({double size})`.
- Produces:
  - `AppDialogAction({required String label, required VoidCallback? onPressed, bool busy = false})`.
  - `AppDialog({required String title, required AppDialogAction cancel, required AppDialogAction confirm, required Widget child})`, with `static const Key cancelKey` and `static const Key confirmKey`, and `static const double maxWidth = 460`.
  - `AppDialogPage<T>({required Widget child, LocalKey? key, String? name})`, a `Page<T>`.
  - `AppPreferencesGroup({required String title, required List<Widget> children, String? description})`.
  - `AppEntryRow({required String label, required TextEditingController controller, Key? fieldKey, FocusNode? focusNode, String? hint, String? errorText, bool enabled = true, bool obscureText = false, TextInputType? keyboardType, TextInputAction? textInputAction, ValueChanged<String>? onSubmitted, Widget? trailing})`, with `static const double macLabelWidth = 120`.

- [ ] **Step 1: Write the failing dialog tests**

Create `test/ui/widgets/app_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_dialog.dart';
import 'package:stash_player_flutter/ui/widgets/app_spinner.dart';

void main() {
  testWidgets('Adwaita: Cancel, title and Save share a header bar above the '
      'body', (tester) async {
    await _pump(tester, platform: TargetPlatform.linux);

    final cancel = tester.getCenter(find.text('Cancel'));
    final title = tester.getCenter(find.text('Connection'));
    final save = tester.getCenter(find.text('Save'));
    final body = tester.getCenter(find.byKey(_bodyKey));

    expect(cancel.dx, lessThan(title.dx));
    expect(title.dx, lessThan(save.dx));
    expect(cancel.dy, moreOrLessEquals(save.dy, epsilon: 1));
    expect(save.dy, lessThan(body.dy));
  });

  testWidgets('macOS: the title leads and Cancel, Save sit bottom-right '
      'below the body', (tester) async {
    await _pump(tester, platform: TargetPlatform.macOS);

    final title = tester.getCenter(find.text('Connection'));
    final cancel = tester.getCenter(find.text('Cancel'));
    final save = tester.getCenter(find.text('Save'));
    final body = tester.getCenter(find.byKey(_bodyKey));

    expect(title.dy, lessThan(body.dy));
    expect(cancel.dy, greaterThan(body.dy));
    expect(cancel.dx, lessThan(save.dx));
    // A sheet hangs from the titlebar, so it starts below the strip.
    final sheet = find
        .ancestor(of: find.text('Connection'), matching: find.byType(Material))
        .first;
    expect(tester.getTopLeft(sheet).dy, greaterThanOrEqualTo(52));
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform: Escape cancels and Enter confirms', (
      tester,
    ) async {
      var cancelled = 0;
      var confirmed = 0;
      await _pump(
        tester,
        platform: platform,
        onCancel: () => cancelled++,
        onConfirm: () => confirmed++,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(cancelled, 1);
      expect(confirmed, 1);
    });

    testWidgets('$platform: busy shows a spinner and Enter does nothing', (
      tester,
    ) async {
      var confirmed = 0;
      await _pump(
        tester,
        platform: platform,
        onConfirm: () => confirmed++,
        busy: true,
      );

      expect(find.byType(AppSpinner), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(confirmed, 0);
    });
  }

  testWidgets('Adwaita: clicking the dimmed window dismisses the dialog', (
    tester,
  ) async {
    final removed = await _pump(tester, platform: TargetPlatform.linux);

    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(removed, ['dialog']);
  });

  testWidgets('macOS: clicking outside a sheet does not dismiss it', (
    tester,
  ) async {
    final removed = await _pump(tester, platform: TargetPlatform.macOS);

    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(removed, isEmpty);
  });

  testWidgets('a disabled Cancel also blocks dismissal by the barrier', (
    tester,
  ) async {
    final removed = await _pump(
      tester,
      platform: TargetPlatform.linux,
      cancelEnabled: false,
    );

    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(removed, isEmpty);
  });
}

const _bodyKey = Key('body');

/// Pumps an [AppDialogPage] over a blank page and returns the names of
/// pages the navigator reports as removed.
Future<List<String?>> _pump(
  WidgetTester tester, {
  required TargetPlatform platform,
  VoidCallback? onCancel,
  VoidCallback? onConfirm,
  bool busy = false,
  bool cancelEnabled = true,
}) async {
  final removed = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light, platform: platform),
      home: Navigator(
        pages: [
          const MaterialPage<void>(name: 'home', child: SizedBox.expand()),
          AppDialogPage<void>(
            name: 'dialog',
            child: AppDialog(
              title: 'Connection',
              cancel: AppDialogAction(
                label: 'Cancel',
                onPressed: cancelEnabled ? (onCancel ?? () {}) : null,
              ),
              confirm: AppDialogAction(
                label: 'Save',
                onPressed: onConfirm ?? () {},
                busy: busy,
              ),
              child: const SizedBox(key: _bodyKey, height: 80),
            ),
          ),
        ],
        onDidRemovePage: (page) => removed.add(page.name),
      ),
    ),
  );
  await _settle(tester);
  return removed;
}

/// `pumpAndSettle` would never return while the busy spinner animates.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
```

- [ ] **Step 2: Write the failing form-row tests**

Create `test/ui/widgets/app_form_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_form.dart';

void main() {
  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform: a group shows its title, rows and description, '
        'and a row its error under the field', (tester) async {
      await _pump(tester, platform);

      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Only if needed.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_urlKey)).decoration!.errorText,
        'Bad URL',
      );
      expect(find.text('Bad URL'), findsOneWidget);
      expect(find.byKey(_trailingKey), findsOneWidget);
    });
  }

  testWidgets('Adwaita: the row label is the field label, like AdwEntryRow', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.linux);
    expect(
      tester.widget<TextField>(find.byKey(_urlKey)).decoration!.labelText,
      'Server URL',
    );
  });

  testWidgets('macOS: the label sits in its own column, left of the field', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.macOS);
    expect(
      tester.getCenter(find.text('Server URL:')).dx,
      lessThan(tester.getCenter(find.byKey(_urlKey)).dx),
    );
  });
}

const _urlKey = Key('url');
const _trailingKey = Key('trailing');

Future<void> _pump(WidgetTester tester, TargetPlatform platform) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, platform: platform),
        home: Scaffold(
          body: AppPreferencesGroup(
            title: 'Server',
            description: 'Only if needed.',
            children: [
              AppEntryRow(
                fieldKey: _urlKey,
                label: 'Server URL',
                controller: TextEditingController(),
                errorText: 'Bad URL',
              ),
              AppEntryRow(
                label: 'API key',
                hint: 'Optional',
                controller: TextEditingController(),
                trailing: const SizedBox(key: _trailingKey, width: 20),
              ),
            ],
          ),
        ),
      ),
    );
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/ui/widgets/app_dialog_test.dart test/ui/widgets/app_form_test.dart`
Expected: compile errors, because `app_dialog.dart` and `app_form.dart` don't exist yet.

- [ ] **Step 4: Implement `app_dialog.dart`**

Create `lib/ui/widgets/app_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';
import '../theme/platform_dialect.dart';
import 'app_spinner.dart';

/// One of an [AppDialog]'s two buttons. A null [onPressed] disables it.
@immutable
class AppDialogAction {
  const AppDialogAction({
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Shows a spinner in place of [label] and stops the button, and Enter,
  /// from firing. Only meaningful on the confirm action.
  final bool busy;
}

/// A modal dialog drawn in the platform's shape: libadwaita's dialog (a
/// card with a header bar holding Cancel, the title and the suggested
/// action) or an AppKit sheet (title, body, then Cancel and the default
/// button bottom-right).
///
/// Escape runs [cancel] and Enter runs [confirm] on both. While [cancel]
/// is disabled the dialog can't be dismissed at all, barrier included, so
/// a caller can hold it open while work it can't abandon is in flight.
///
/// Shown through an [AppDialogPage], which supplies the barrier and the
/// per-dialect transition.
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    required this.cancel,
    required this.confirm,
    required this.child,
    super.key,
  });

  static const Key cancelKey = Key('app-dialog-cancel');
  static const Key confirmKey = Key('app-dialog-confirm');
  static const double maxWidth = 460;

  final String title;
  final AppDialogAction cancel;
  final AppDialogAction confirm;
  final Widget child;

  void _confirm() {
    if (!confirm.busy) confirm.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    return PopScope(
      canPop: cancel.onPressed != null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              cancel.onPressed?.call(),
          const SingleActivator(LogicalKeyboardKey.enter): _confirm,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _confirm,
        },
        // Key events travel up from the focused node, and a freshly pushed
        // route focuses its own scope, which sits above these bindings.
        // Taking focus here puts them on the path from the start.
        child: Focus(
          autofocus: true,
          child: adwaita ? _adwaita(context) : _macos(context),
        ),
      ),
    );
  }

  Widget _adwaita(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: _surface(
            context,
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 46,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space2,
                    ),
                    // NavigationToolbar centres the title on the bar itself,
                    // not on the space the two buttons leave, which is how
                    // a GTK header bar lays out its title.
                    child: NavigationToolbar(
                      leading: TextButton(
                        key: cancelKey,
                        onPressed: cancel.onPressed,
                        child: Text(cancel.label),
                      ),
                      middle: _title(theme),
                      trailing: _confirmButton(),
                      middleSpacing: AppTokens.space3,
                    ),
                  ),
                ),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppTokens.space5),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _macos(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        // A sheet hangs from the bottom of the titlebar, which on macOS is
        // the app's own strip.
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space5,
          AppTokens.macOSStripHeight,
          AppTokens.space5,
          AppTokens.space5,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: _surface(
            context,
            Padding(
              padding: const EdgeInsets.all(AppTokens.space5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _title(theme),
                  const SizedBox(height: AppTokens.space4),
                  Flexible(child: SingleChildScrollView(child: child)),
                  const SizedBox(height: AppTokens.space5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        key: cancelKey,
                        onPressed: cancel.onPressed,
                        child: Text(cancel.label),
                      ),
                      const SizedBox(width: AppTokens.space2),
                      _confirmButton(),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _surface(BuildContext context, Widget content) => Material(
    color: Theme.of(context).colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: const Color(0x80000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.of(context).radiusPanel),
    ),
    clipBehavior: Clip.antiAlias,
    child: content,
  );

  Widget _title(ThemeData theme) => Text(
    title,
    textAlign: TextAlign.center,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
  );

  Widget _confirmButton() => FilledButton(
    key: confirmKey,
    onPressed: confirm.busy ? null : confirm.onPressed,
    child: confirm.busy ? const AppSpinner(size: 16) : Text(confirm.label),
  );
}

/// Shows an [AppDialog] as a page in a declarative `Navigator.pages` list.
///
/// Adwaita fades and slightly scales the card in, and clicking the dimmed
/// window dismisses it. macOS slides a sheet down from the titlebar, and
/// clicking outside does nothing, as with an AppKit sheet.
class AppDialogPage<T> extends Page<T> {
  const AppDialogPage({required this.child, super.key, super.name});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) {
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    return RawDialogRoute<T>(
      settings: this,
      barrierDismissible: adwaita,
      barrierColor: const Color(0x52000000),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => child,
      transitionBuilder: adwaita ? _fadeScale : _slideDown,
    );
  }
}

Widget _fadeScale(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.95, end: 1).animate(curved),
      child: child,
    ),
  );
}

Widget _slideDown(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) => SlideTransition(
  position: Tween<Offset>(
    begin: const Offset(0, -0.3),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
  child: FadeTransition(opacity: animation, child: child),
);
```

- [ ] **Step 5: Implement `app_form.dart`**

Create `lib/ui/widgets/app_form.dart`:

```dart
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../theme/platform_dialect.dart';

/// A titled group of form rows: libadwaita's `AdwPreferencesGroup` (rows
/// in one rounded boxed list, separated by hairlines) or an AppKit form
/// section (plain rows under a bold label).
class AppPreferencesGroup extends StatelessWidget {
  const AppPreferencesGroup({
    required this.title,
    required this.children,
    this.description,
    super.key,
  });

  final String title;
  final List<Widget> children;

  /// Dimmed text under the rows, for guidance that applies to the group.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTokens.of(context);
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;

    final Widget rows = adwaita
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.controlSurface,
              borderRadius: BorderRadius.circular(tokens.radiusPanel),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, row) in children.indexed) ...[
                  if (index > 0) const Divider(),
                  row,
                ],
              ],
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, row) in children.indexed) ...[
                if (index > 0) const SizedBox(height: AppTokens.space2),
                row,
              ],
            ],
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppTokens.space2),
        rows,
        if (description case final String text) ...[
          const SizedBox(height: AppTokens.space2),
          Padding(
            // On macOS the description lines up with the fields, not the
            // labels, as AppKit forms do.
            padding: EdgeInsetsDirectional.only(
              start: adwaita ? 0 : AppEntryRow.macLabelWidth + AppTokens.space2,
            ),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One labelled text field in an [AppPreferencesGroup].
///
/// On Adwaita it follows `AdwEntryRow`: a borderless field filling the
/// row, with the label inside it that moves up to a caption once the row
/// has focus or text, which is exactly a floating label. On macOS it is
/// an AppKit form row: a right-aligned "Label:" column beside a bordered
/// field, with the label and field merged into one semantics node so a
/// screen reader names the field. [errorText] is the field's own, so it
/// renders directly under the field on both.
class AppEntryRow extends StatelessWidget {
  const AppEntryRow({
    required this.label,
    required this.controller,
    this.fieldKey,
    this.focusNode,
    this.hint,
    this.errorText,
    this.enabled = true,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.trailing,
    super.key,
  });

  /// Width of the macOS label column: room for "SOCKS5 proxy:" at the
  /// default text size.
  static const double macLabelWidth = 120;

  final String label;
  final TextEditingController controller;

  /// Put on the [TextField] itself, so tests can reach it.
  final Key? fieldKey;
  final FocusNode? focusNode;
  final String? hint;
  final String? errorText;
  final bool enabled;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  /// A control after the field, such as a show/hide toggle. Kept out of
  /// the macOS merged semantics node so it stays its own button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) =>
      PlatformDialect.of(context) == PlatformDialect.adwaita
      ? _adwaita()
      : _macos();

  TextField _field(InputDecoration decoration) => TextField(
    key: fieldKey,
    controller: controller,
    focusNode: focusNode,
    enabled: enabled,
    obscureText: obscureText,
    keyboardType: keyboardType,
    textInputAction: textInputAction,
    onSubmitted: onSubmitted,
    decoration: decoration,
  );

  Widget _adwaita() => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppTokens.space3,
      vertical: AppTokens.space1,
    ),
    child: Row(
      children: [
        Expanded(
          child: _field(
            InputDecoration(
              labelText: label,
              hintText: hint,
              errorText: errorText,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _macos() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: macLabelWidth,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppTokens.space2),
                  child: Text('$label:', textAlign: TextAlign.end),
                ),
              ),
              const SizedBox(width: AppTokens.space2),
              Expanded(
                child: _field(
                  InputDecoration(hintText: hint, errorText: errorText),
                ),
              ),
            ],
          ),
        ),
      ),
      ?trailing,
    ],
  );
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/ui/widgets/app_dialog_test.dart test/ui/widgets/app_form_test.dart`
Expected: PASS.

- [ ] **Step 7: Run the full check and commit**

Run: `just flutter-check` (from the repo root)
Expected: PASS.

```bash
git add lib/ui/widgets/app_dialog.dart lib/ui/widgets/app_form.dart test/ui/widgets/app_dialog_test.dart test/ui/widgets/app_form_test.dart
git commit -m "feat(flutter): add a drawn, per-platform dialog and form rows"
```

---

### Task 3: `ConnectionFields`, `ConnectionForm` and `ConnectionSettingsDialog`

This task adds the shared form and the dialog. Nothing uses them yet: the router is wired in Task 4. `ConnectionScreen` is not touched here.

**Files:**
- Create: `lib/features/connection/connection_form.dart`
- Create: `lib/features/connection/connection_settings_dialog.dart`
- Test: `test/features/connection/connection_form_test.dart`
- Test: `test/features/connection/connection_settings_dialog_test.dart`

**Interfaces:**
- Consumes:
  - Task 1: `AppController.closeSettings()`, `AppController.replaceConnection(ConnectionConfig)`.
  - Task 2: `AppDialog`, `AppDialogAction`, `AppPreferencesGroup`, `AppEntryRow`.
  - Existing: `connectionControllerProvider` (`ChangeNotifierProvider<ConnectionController>`), `ConnectionController.load()`, `ConnectionController.testAndSave(ConnectionConfig)`, and `ConnectionState` with `phase`, `config`, `fieldError`, `proxyFieldError`, `failure` and `serverVersion`.
- Produces:
  - `class ConnectionFields`: `ConnectionFields([ConnectionConfig seed])`, the controllers `serverUrl`, `apiKey` and `socksProxy` (each a `TextEditingController`), `ConnectionConfig get current`, `bool get canSubmit`, `void applyLoaded(ConnectionConfig)` and `void dispose()`.
  - `ConnectionForm({required ConnectionFields fields, required bool loadOnMount})`.
  - `ConnectionSettingsDialog()`, a const `ConsumerStatefulWidget`.

- [ ] **Step 1: Write the failing form tests**

Create `test/features/connection/connection_form_test.dart`. The last five widget tests are moved from `connection_screen_test.dart`, which Task 4 rewrites.

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';
import 'package:stash_player_flutter/features/connection/connection_form.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

import '../../support/fakes.dart';

void main() {
  group('ConnectionFields', () {
    test('current reads all three fields', () {
      final fields = ConnectionFields(
        const ConnectionConfig(
          serverUrl: 'https://a.test',
          apiKey: 'k',
          socksProxy: '127.0.0.1:1055',
        ),
      );
      addTearDown(fields.dispose);

      expect(fields.current.serverUrl, 'https://a.test');
      expect(fields.current.apiKey, 'k');
      expect(fields.current.socksProxy, '127.0.0.1:1055');
    });

    test('canSubmit needs a non-blank URL', () {
      final fields = ConnectionFields();
      addTearDown(fields.dispose);

      expect(fields.canSubmit, isFalse);
      fields.serverUrl.text = '   ';
      expect(fields.canSubmit, isFalse);
      fields.serverUrl.text = 'https://a.test';
      expect(fields.canSubmit, isTrue);
    });

    test('applyLoaded fills untouched fields and keeps typed ones', () {
      final fields = ConnectionFields();
      addTearDown(fields.dispose);
      fields.serverUrl.text = 'https://typed.test';

      fields.applyLoaded(
        const ConnectionConfig(serverUrl: 'https://loaded.test', apiKey: 'k'),
      );

      expect(fields.serverUrl.text, 'https://typed.test');
      expect(fields.apiKey.text, 'k');
    });
  });

  testWidgets('labels the fields and masks the API key behind a toggle', (
    tester,
  ) async {
    await _pumpForm(tester, controller: _controller());

    expect(find.bySemanticsLabel('Server URL'), findsOneWidget);
    expect(find.bySemanticsLabel('API key'), findsOneWidget);
    expect(find.bySemanticsLabel('SOCKS5 proxy'), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);

    expect(tester.widget<TextField>(_apiKeyField).obscureText, isTrue);
    await tester.tap(find.byTooltip('Show API key'));
    await tester.pump();
    expect(tester.widget<TextField>(_apiKeyField).obscureText, isFalse);
  });

  testWidgets('moves focus from URL to API key with the keyboard', (
    tester,
  ) async {
    await _pumpForm(tester, controller: _controller());

    await tester.tap(_serverUrlField);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    expect(tester.widget<TextField>(_apiKeyField).focusNode!.hasFocus, isTrue);
  });

  testWidgets('shows each validation error under its own field', (
    tester,
  ) async {
    final controller = _controller();
    final fields = await _pumpForm(tester, controller: controller);

    fields.serverUrl.text = 'stash';
    await controller.testAndSave(fields.current);
    await tester.pump();
    expect(
      tester.widget<TextField>(_serverUrlField).decoration!.errorText,
      'Enter a valid http or https server URL.',
    );
    expect(
      tester.widget<TextField>(_socksProxyField).decoration!.errorText,
      isNull,
    );

    fields.serverUrl.text = 'https://stash.test';
    fields.socksProxy.text = 'not a proxy';
    await controller.testAndSave(fields.current);
    await tester.pump();
    expect(
      tester.widget<TextField>(_socksProxyField).decoration!.errorText,
      'Enter the proxy as host or host:port.',
    );
    expect(
      tester.widget<TextField>(_serverUrlField).decoration!.errorText,
      isNull,
    );
  });

  testWidgets('shows a connection failure below the groups', (tester) async {
    final controller = ConnectionController(
      store: FakeConnectionStore(),
      environment: const {},
      apiFactory: (_) =>
          FakeStashApi(versionFailure: const TransportFailure('unreachable')),
    );
    final fields = await _pumpForm(tester, controller: controller);

    fields.serverUrl.text = 'https://stash.test';
    await controller.testAndSave(fields.current);
    await tester.pump();

    expect(
      find.text(
        'Could not reach Stash. Check the server URL and network connection.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('loadOnMount fills the fields from the stored config', (
    tester,
  ) async {
    final controller = ConnectionController(
      store: FakeConnectionStore(
        saved: const ConnectionConfig(
          serverUrl: 'https://loaded.test',
          apiKey: 'loaded-key',
        ),
      ),
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    final fields = await _pumpForm(
      tester,
      controller: controller,
      loadOnMount: true,
    );
    await tester.pump();

    expect(fields.serverUrl.text, 'https://loaded.test');
    expect(fields.apiKey.text, 'loaded-key');
  });

  testWidgets('a late load does not clobber text already typed', (
    tester,
  ) async {
    final completer = Completer<ConnectionConfig>();
    final controller = ConnectionController(
      store: FakeConnectionStore(loadFuture: completer.future),
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    final fields = await _pumpForm(
      tester,
      controller: controller,
      loadOnMount: true,
    );
    await tester.enterText(_serverUrlField, 'https://typed-by-user.test');

    completer.complete(
      const ConnectionConfig(
        serverUrl: 'https://loaded.test',
        apiKey: 'loaded-key',
      ),
    );
    await tester.pump();

    expect(fields.serverUrl.text, 'https://typed-by-user.test');
    expect(fields.apiKey.text, 'loaded-key');
  });
}

ConnectionController _controller() => ConnectionController(
  store: FakeConnectionStore(),
  environment: const {},
  apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
);

/// Not disposed: the text fields still hold these controllers when the
/// test's tree is torn down, and disposing them first would throw.
Future<ConnectionFields> _pumpForm(
  WidgetTester tester, {
  required ConnectionController controller,
  bool loadOnMount = false,
}) async {
  final fields = ConnectionFields();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConnectionForm(fields: fields, loadOnMount: loadOnMount),
          ),
        ),
      ),
    ),
  );
  return fields;
}

final _serverUrlField = find.byKey(const Key('connection-server-url'));
final _socksProxyField = find.byKey(const Key('connection-socks-proxy'));
final _apiKeyField = find.byKey(const Key('connection-api-key'));
```

- [ ] **Step 2: Write the failing dialog tests**

Create `test/features/connection/connection_settings_dialog_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';
import 'package:stash_player_flutter/features/connection/connection_settings_dialog.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_dialog.dart';
import 'package:stash_player_flutter/ui/widgets/app_spinner.dart';

import '../../support/fakes.dart';

void main() {
  testWidgets('seeds the fields from the stored connection', (tester) async {
    await _pump(
      tester,
      store: FakeConnectionStore(
        saved: const ConnectionConfig(serverUrl: 'https://old.test'),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(_serverUrlField).controller!.text,
      'https://old.test',
    );
  });

  testWidgets('Save stays disabled until a URL is entered', (tester) async {
    await _pump(tester);

    expect(_button(tester, AppDialog.confirmKey).onPressed, isNull);
    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.pump();
    expect(_button(tester, AppDialog.confirmKey).onPressed, isNotNull);
  });

  testWidgets('a failed test keeps the dialog open with the error inline', (
    tester,
  ) async {
    final harness = await _pump(
      tester,
      api: FakeStashApi(versionFailure: const TransportFailure('down')),
    );

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(
      find.text(
        'Could not reach Stash. Check the server URL and network connection.',
      ),
      findsOneWidget,
    );
    expect(harness.app.replaced, isEmpty);
    expect(harness.app.closed, 0);
  });

  testWidgets('while testing, Save spins and Cancel, Escape are disabled', (
    tester,
  ) async {
    final completer = Completer<String>();
    final harness = await _pump(
      tester,
      api: FakeStashApi(versionFuture: completer.future),
    );

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.byType(AppSpinner), findsOneWidget);
    expect(_button(tester, AppDialog.cancelKey).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(harness.app.closed, 0);

    completer.complete('v0.31.0');
    await tester.pump();
  });

  testWidgets('a successful test hands the config to replaceConnection', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(harness.app.replaced.single.serverUrl, 'https://stash.test');
  });

  testWidgets('Cancel closes without testing or saving', (tester) async {
    final store = FakeConnectionStore();
    final harness = await _pump(tester, store: store);

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(harness.app.closed, 1);
    expect(store.saveCalls, isEmpty);
  });
}

class _Harness {
  _Harness(this.app);
  final _RecordingAppController app;
}

/// Stands in for the real controller, so the dialog can be tested without
/// the router or the rest of the provider graph.
class _RecordingAppController extends AppController {
  final replaced = <ConnectionConfig>[];
  var closed = 0;

  @override
  AppDestination build() => const LibraryDestination(settingsOpen: true);

  @override
  Future<void> replaceConnection(ConnectionConfig config) async {
    replaced.add(config);
  }

  @override
  void closeSettings() => closed++;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  FakeConnectionStore? store,
  FakeStashApi? api,
}) async {
  final app = _RecordingAppController();
  final controller = ConnectionController(
    store: store ?? FakeConnectionStore(),
    environment: const {},
    apiFactory: (_) => api ?? FakeStashApi(versionValue: 'v0.31.0'),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionControllerProvider.overrideWith((ref) => controller),
        appControllerProvider.overrideWith(() => app),
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: const ConnectionSettingsDialog(),
      ),
    ),
  );
  return _Harness(app);
}

ButtonStyleButton _button(WidgetTester tester, Key key) =>
    tester.widget<ButtonStyleButton>(find.byKey(key));

final _serverUrlField = find.byKey(const Key('connection-server-url'));
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/features/connection/connection_form_test.dart test/features/connection/connection_settings_dialog_test.dart`
Expected: compile errors, because `connection_form.dart` and `connection_settings_dialog.dart` don't exist yet.

- [ ] **Step 4: Implement `connection_form.dart`**

Create `lib/features/connection/connection_form.dart`:

```dart
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import '../../ui/icons/app_icons.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_form.dart';
import 'connection_controller.dart';

/// The connection form's text, owned by whichever screen hosts the form
/// (the first-launch page or the settings dialog) so that host can read
/// [current] and [canSubmit] for its own submit button.
class ConnectionFields {
  ConnectionFields([ConnectionConfig seed = const ConnectionConfig()])
    : _seed = seed,
      serverUrl = TextEditingController(text: seed.serverUrl),
      apiKey = TextEditingController(text: seed.apiKey),
      socksProxy = TextEditingController(text: seed.socksProxy);

  final TextEditingController serverUrl;
  final TextEditingController apiKey;
  final TextEditingController socksProxy;

  /// The config the fields were last filled from programmatically. A field
  /// whose text no longer matches it has been edited by the user, and
  /// [applyLoaded] leaves it alone.
  ConnectionConfig _seed;

  ConnectionConfig get current => ConnectionConfig(
    serverUrl: serverUrl.text,
    apiKey: apiKey.text,
    socksProxy: socksProxy.text,
  );

  /// Only a URL is required. Everything else is validated by
  /// `ConnectionController.testAndSave`, which reports under the field.
  bool get canSubmit => serverUrl.text.trim().isNotEmpty;

  /// Fills in [config], typically the stored connection once `load()`
  /// resolves, without overwriting anything typed since the last fill. The
  /// load runs in the background while the form is already usable, so it
  /// can land after the user has started typing.
  void applyLoaded(ConnectionConfig config) {
    if (serverUrl.text == _seed.serverUrl) serverUrl.text = config.serverUrl;
    if (apiKey.text == _seed.apiKey) apiKey.text = config.apiKey;
    if (socksProxy.text == _seed.socksProxy) {
      socksProxy.text = config.socksProxy;
    }
    _seed = config;
  }

  void dispose() {
    serverUrl.dispose();
    apiKey.dispose();
    socksProxy.dispose();
  }
}

/// The connection fields as two groups (Server, Network), with the
/// controller's validation and connection errors. It has no submit button:
/// the host supplies one, since the first-launch page and the settings
/// dialog place it differently.
class ConnectionForm extends ConsumerStatefulWidget {
  const ConnectionForm({
    required this.fields,
    required this.loadOnMount,
    super.key,
  });

  final ConnectionFields fields;

  /// Whether to read the stored connection on mount and fill [fields] from
  /// it. False only when the host has pinned its own seed.
  final bool loadOnMount;

  @override
  ConsumerState<ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends ConsumerState<ConnectionForm> {
  final _apiKeyFocusNode = FocusNode();
  var _showApiKey = false;

  @override
  void initState() {
    super.initState();
    if (widget.loadOnMount) {
      // Fire-and-forget: `load()` never touches provider state before its
      // first `await` (the controller's loading phase is reserved for
      // `testAndSave`, not this background fetch; see its doc comment),
      // so calling it here never trips Riverpod's "don't modify a provider
      // while the tree is building" guard.
      ref.read(connectionControllerProvider).load();
    }
  }

  @override
  void dispose() {
    _apiKeyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loadOnMount) {
      ref.listen<ConnectionState>(
        connectionControllerProvider.select((value) => value.state),
        (previous, next) => widget.fields.applyLoaded(next.config),
      );
    }
    final state = ref.watch(
      connectionControllerProvider.select((value) => value.state),
    );
    final enabled = state.phase != ConnectionPhase.loading;
    final fields = widget.fields;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppPreferencesGroup(
          title: 'Server',
          children: [
            AppEntryRow(
              fieldKey: const Key('connection-server-url'),
              label: 'Server URL',
              controller: fields.serverUrl,
              enabled: enabled,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _apiKeyFocusNode.requestFocus(),
              errorText: state.fieldError,
            ),
            AppEntryRow(
              fieldKey: const Key('connection-api-key'),
              label: 'API key',
              hint: 'Optional',
              controller: fields.apiKey,
              focusNode: _apiKeyFocusNode,
              enabled: enabled,
              obscureText: !_showApiKey,
              textInputAction: TextInputAction.done,
              trailing: Tooltip(
                message: _showApiKey ? 'Hide API key' : 'Show API key',
                child: IconButton(
                  onPressed: () => setState(() => _showApiKey = !_showApiKey),
                  icon: AppIconView(
                    _showApiKey ? AppIcon.eyeOff : AppIcon.eye,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space5),
        AppPreferencesGroup(
          title: 'Network',
          description:
              'Reach Stash through a SOCKS5 proxy, for a server only '
              'routable that way. Tailscale in userspace mode listens on '
              '127.0.0.1:1055.',
          children: [
            AppEntryRow(
              fieldKey: const Key('connection-socks-proxy'),
              label: 'SOCKS5 proxy',
              hint: 'Optional',
              controller: fields.socksProxy,
              enabled: enabled,
              textInputAction: TextInputAction.done,
              errorText: state.proxyFieldError,
            ),
          ],
        ),
        if (state.failure case final String failure) ...[
          const SizedBox(height: AppTokens.space4),
          Text(
            failure,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}
```

- [ ] **Step 5: Implement `connection_settings_dialog.dart`**

Create `lib/features/connection/connection_settings_dialog.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../ui/widgets/app_dialog.dart';
import 'connection_controller.dart';
import 'connection_form.dart';

/// Changing the active connection, as a dialog over the library.
///
/// Save runs the same test-and-save as the first-launch page. On success
/// it hands the config to [AppController.replaceConnection], whose switch
/// back to `library()` takes this dialog's page off the stack. On failure
/// the dialog stays open with the error under the relevant field.
///
/// Cancel, Escape and the barrier are disabled while a test runs:
/// `testAndSave` stores the config the moment Stash answers, so closing
/// mid-test would leave a new connection saved but not in use until the
/// next launch. `HttpStashApi`'s request timeout bounds the wait.
class ConnectionSettingsDialog extends ConsumerStatefulWidget {
  const ConnectionSettingsDialog({super.key});

  @override
  ConsumerState<ConnectionSettingsDialog> createState() =>
      _ConnectionSettingsDialogState();
}

class _ConnectionSettingsDialogState
    extends ConsumerState<ConnectionSettingsDialog> {
  final _fields = ConnectionFields();

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectionPhase>(
      connectionControllerProvider.select((value) => value.state.phase),
      (previous, next) {
        if (previous != ConnectionPhase.ready &&
            next == ConnectionPhase.ready) {
          final config = ref.read(connectionControllerProvider).state.config;
          unawaited(
            ref.read(appControllerProvider.notifier).replaceConnection(config),
          );
        }
      },
    );
    final controller = ref.read(connectionControllerProvider);
    final loading = ref.watch(
      connectionControllerProvider.select(
        (value) => value.state.phase == ConnectionPhase.loading,
      ),
    );

    return ListenableBuilder(
      listenable: _fields.serverUrl,
      builder: (context, _) => AppDialog(
        title: 'Connection',
        cancel: AppDialogAction(
          label: 'Cancel',
          onPressed: loading
              ? null
              : ref.read(appControllerProvider.notifier).closeSettings,
        ),
        confirm: AppDialogAction(
          label: 'Save',
          busy: loading,
          onPressed: _fields.canSubmit
              ? () => controller.testAndSave(_fields.current)
              : null,
        ),
        child: ConnectionForm(fields: _fields, loadOnMount: true),
      ),
    );
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/features/connection/`
Expected: PASS. The old `connection_screen_test.dart` still passes too, because `ConnectionScreen` is unchanged.

- [ ] **Step 7: Run the full check and commit**

Run: `just flutter-check`
Expected: PASS.

```bash
git add lib/features/connection/connection_form.dart lib/features/connection/connection_settings_dialog.dart test/features/connection/connection_form_test.dart test/features/connection/connection_settings_dialog_test.dart
git commit -m "feat(flutter): add a shared connection form and the settings dialog"
```

---

### Task 4: Route settings through the dialog; slim `ConnectionScreen` to first launch

**Files:**
- Modify: `lib/app/app_router.dart`
- Rewrite: `lib/features/connection/connection_screen.dart`
- Rewrite: `test/features/connection/connection_screen_test.dart`
- Modify: `test/app/app_router_test.dart`

**Interfaces:**
- Consumes:
  - Task 1: `LibraryDestination.settingsOpen`, `openSettings()`, `closeSettings()`.
  - Task 2: `AppDialogPage`.
  - Task 3: `ConnectionFields`, `ConnectionForm`, `ConnectionSettingsDialog`.
- Produces: `ConnectionScreen({required VoidCallback onConnected, ConnectionConfig? initialConfig})`. `settingsMode` and `onCancel` are removed. `LibraryScreen.onOpenSettings` is still required, and is wired to `openSettings()` until Task 5 removes it.

- [ ] **Step 1: Update the router tests (failing)**

In `test/app/app_router_test.dart`, add `import 'package:flutter/services.dart';` and `import 'package:stash_player_flutter/features/connection/connection_settings_dialog.dart';`. In the first-launch test, change `find.text('Test connection')` to `find.text('Connect')`. Replace the whole `'settings: a successful reconnect dismisses the modal…'` test with these two:

```dart
  testWidgets(
    'settings: a successful save closes the dialog and reconnects the '
    'library',
    (tester) async {
      final container = _container(
        saved: const ConnectionConfig(serverUrl: 'https://old.test'),
      );
      addTearDown(container.dispose);
      await container.read(appControllerProvider.notifier).bootstrap();

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      container.read(appControllerProvider.notifier).openSettings();
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionSettingsDialog), findsOneWidget);
      // The dialog floats over the library rather than replacing it.
      expect(find.byType(LibraryScreen), findsOneWidget);

      final generationBefore = container.read(connectionGenerationProvider);

      await tester.enterText(
        find.byKey(const Key('connection-server-url')),
        'https://new.test',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(ConnectionSettingsDialog), findsNothing);
      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
      expect(
        container.read(connectionGenerationProvider),
        generationBefore + 1,
      );
    },
  );

  testWidgets('settings: Escape closes the dialog without reconnecting', (
    tester,
  ) async {
    final container = _container(
      saved: const ConnectionConfig(serverUrl: 'https://old.test'),
    );
    addTearDown(container.dispose);
    await container.read(appControllerProvider.notifier).bootstrap();

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    container.read(appControllerProvider.notifier).openSettings();
    await tester.pumpAndSettle();
    final generationBefore = container.read(connectionGenerationProvider);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionSettingsDialog), findsNothing);
    expect(
      container.read(appControllerProvider),
      const AppDestination.library(),
    );
    expect(container.read(connectionGenerationProvider), generationBefore);
  });
```

- [ ] **Step 2: Rewrite the screen tests (failing)**

Replace the whole of `test/features/connection/connection_screen_test.dart` with:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';
import 'package:stash_player_flutter/features/connection/connection_screen.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_spinner.dart';

import '../../support/fakes.dart';

void main() {
  testWidgets('Connect stays disabled until a URL is entered', (tester) async {
    await _pump(tester, controller: _controller());

    expect(_connectButton(tester).onPressed, isNull);
    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.pump();
    expect(_connectButton(tester).onPressed, isNotNull);
  });

  testWidgets('shows validation only on the URL field', (tester) async {
    await _pump(tester, controller: _controller());

    await tester.enterText(_serverUrlField, 'stash');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(
      find.text('Enter a valid http or https server URL.'),
      findsOneWidget,
    );
    // `textContaining`, not an exact `find.text`: the real copy is longer
    // than "Could not reach Stash.", so an exact match could never find it
    // and this would pass even if validation wrongly showed the network
    // error.
    expect(find.textContaining('Could not reach Stash'), findsNothing);
  });

  testWidgets('submits the SOCKS proxy that was typed', (tester) async {
    final store = FakeConnectionStore();
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );
    await _pump(tester, controller: controller);

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.enterText(_socksProxyField, '127.0.0.1:1055');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(store.saveCalls.single.socksProxy, '127.0.0.1:1055');
  });

  testWidgets('shows server errors and finishes only after a success', (
    tester,
  ) async {
    var connected = 0;
    await _pump(
      tester,
      controller: _controller(failure: const TransportFailure('unreachable')),
      onConnected: () => connected++,
    );

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(
      find.text(
        'Could not reach Stash. Check the server URL and network connection.',
      ),
      findsOneWidget,
    );
    expect(connected, 0);

    await _pump(
      tester,
      controller: _controller(),
      onConnected: () => connected++,
    );
    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.text('Connected to Stash v0.31.0.'), findsOneWidget);
    expect(connected, 1);
  });

  testWidgets('shows progress while testing', (tester) async {
    final completer = Completer<String>();
    final controller = ConnectionController(
      store: FakeConnectionStore(),
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionFuture: completer.future),
    );
    await _pump(tester, controller: controller);

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.byType(AppSpinner), findsOneWidget);
    completer.complete('v0.31.0');
    await tester.pump();
  });

  testWidgets('does not overflow at a raised text scale and a short height', (
    tester,
  ) async {
    // Without the screen's LayoutBuilder + scroll wrapper this size
    // overflows the bottom. A bare SingleChildScrollView alone would fix
    // that only by giving up vertical centring at normal sizes.
    await _pump(
      tester,
      controller: _controller(),
      size: const Size(800, 320),
      textScaler: const TextScaler.linear(1.3),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('mounts without initialConfig and fills fields from the loaded '
      'config', (tester) async {
    final controller = ConnectionController(
      store: FakeConnectionStore(
        saved: const ConnectionConfig(
          serverUrl: 'https://loaded.test',
          apiKey: 'loaded-key',
        ),
      ),
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await _pump(tester, controller: controller, initialConfig: null);
    await tester.pump();

    expect(
      tester.widget<TextField>(_serverUrlField).controller!.text,
      'https://loaded.test',
    );
  });
}

ConnectionController _controller({Failure? failure}) => ConnectionController(
  store: FakeConnectionStore(),
  environment: const {},
  apiFactory: (_) => FakeStashApi(
    versionValue: failure == null ? 'v0.31.0' : null,
    versionFailure: failure,
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required ConnectionController controller,
  VoidCallback? onConnected,
  ConnectionConfig? initialConfig = const ConnectionConfig(),
  Size? size,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (size != null) {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }
  return tester.pumpWidget(
    ProviderScope(
      key: ValueKey(controller),
      overrides: [
        connectionControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: ConnectionScreen(
          initialConfig: initialConfig,
          onConnected: onConnected ?? () {},
        ),
      ),
    ),
  );
}

FilledButton _connectButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'));

final _serverUrlField = find.byKey(const Key('connection-server-url'));
final _socksProxyField = find.byKey(const Key('connection-socks-proxy'));
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/features/connection/connection_screen_test.dart test/app/app_router_test.dart`
Expected: the screen tests fail because they can't find `Connect`. The router tests fail because `openSettings()` doesn't show `ConnectionSettingsDialog` yet.

- [ ] **Step 4: Rewrite `connection_screen.dart`**

Replace the whole of `lib/features/connection/connection_screen.dart` with:

```dart
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_spinner.dart';
import 'connection_controller.dart';
import 'connection_form.dart';

/// The first-launch page, shown full-screen while no connection is saved.
/// Changing an existing connection happens in `ConnectionSettingsDialog`,
/// over the library, instead.
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({
    required this.onConnected,
    this.initialConfig,
    super.key,
  });

  final VoidCallback onConnected;

  /// Seeds the form fields directly, bypassing the controller's `load()`.
  ///
  /// Pass `null` (the normal case) to have the form call `load()` on mount
  /// and fill the fields from the effective config once it resolves. Pass
  /// an explicit config only to pin the seed; the form then never fetches.
  final ConnectionConfig? initialConfig;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final _fields = ConnectionFields(
    widget.initialConfig ?? const ConnectionConfig(),
  );

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectionPhase>(
      connectionControllerProvider.select((value) => value.state.phase),
      (previous, next) {
        if (previous != ConnectionPhase.ready &&
            next == ConnectionPhase.ready) {
          widget.onConnected();
        }
      },
    );
    final controller = ref.read(connectionControllerProvider);
    final state = ref.watch(
      connectionControllerProvider.select((value) => value.state),
    );
    final loading = state.phase == ConnectionPhase.loading;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.space5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Connect to Stash',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppTokens.space5),
                      ConnectionForm(
                        fields: _fields,
                        loadOnMount: widget.initialConfig == null,
                      ),
                      if (state.serverVersion case final String version) ...[
                        const SizedBox(height: AppTokens.space4),
                        Text('Connected to Stash $version.'),
                      ],
                      const SizedBox(height: AppTokens.space5),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: ListenableBuilder(
                          listenable: _fields.serverUrl,
                          builder: (context, _) => Tooltip(
                            message:
                                'Test this connection and save it if Stash '
                                'responds.',
                            child: FilledButton(
                              onPressed: loading || !_fields.canSubmit
                                  ? null
                                  : () => controller.testAndSave(
                                      _fields.current,
                                    ),
                              child: loading
                                  ? const AppSpinner(size: 18)
                                  : const Text('Connect'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Wire the router**

In `lib/app/app_router.dart`:

1. Add the imports `import '../features/connection/connection_settings_dialog.dart';` and `import '../ui/widgets/app_dialog.dart';`.
2. Replace the `onDidRemovePage` callback with:

```dart
      onDidRemovePage: (page) {
        final app = ref.read(appControllerProvider.notifier);
        switch (page.name) {
          case _scenePageName:
            app.showLibrary();
          case _settingsPageName:
            // Also runs when the page leaves because the destination already
            // changed (a successful save). closeSettings is a no-op then.
            app.closeSettings();
        }
      },
```

3. Replace the `LibraryDestination()` arm of `_pagesFor` with:

```dart
        LibraryDestination(:final settingsOpen) => [
          _libraryPage,
          if (settingsOpen) _settingsPage,
        ],
```

4. Next to the other page-name constants, add:

```dart
const _settingsPageName = 'settings';

const _settingsPage = AppDialogPage<void>(
  key: ValueKey('settings'),
  name: _settingsPageName,
  child: ConnectionSettingsDialog(),
);
```

5. In `_ConnectionDestinationScreen.build`, drop the `settingsMode: false,` argument.
6. Replace `_LibraryRoute` and delete `_SettingsRoute` entirely:

```dart
/// Renders the library, wiring its "open settings" intent to
/// [AppController.openSettings]. Task 5 moves that call into the library
/// feature itself and deletes this wrapper.
class _LibraryRoute extends ConsumerWidget {
  const _LibraryRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) => LibraryScreen(
    onOpenSettings: () =>
        ref.read(appControllerProvider.notifier).openSettings(),
  );
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/features/connection/ test/app/`
Expected: PASS.

- [ ] **Step 7: Run the full check and commit**

Run: `just flutter-check`
Expected: PASS. The library toolbar keeps its gear (now calling `openSettings()`) until Task 5, so `library_screen_test.dart` is untouched here.

```bash
git add lib/app/app_router.dart lib/features/connection/connection_screen.dart test/features/connection/connection_screen_test.dart test/app/app_router_test.dart
git commit -m "feat(flutter): open connection settings as a dialog over the library"
```

---

### Task 5: Linux main menu and Ctrl+,

**Files:**
- Modify: `lib/ui/icons/app_icons.dart`
- Modify: `tool/fetch_icons.py`
- Modify: `assets/icons/gnome/`, `assets/icons/lucide/` (regenerated)
- Modify: `lib/features/library/library_toolbar.dart`
- Modify: `lib/features/library/library_screen.dart`
- Modify: `lib/app/app_router.dart`
- Test: `test/features/library/library_screen_test.dart`

**Interfaces:**
- Consumes:
  - Task 1: `AppController.openSettings()`, `LibraryDestination(settingsOpen: true)`.
  - Existing: `NativeMenusScope.of(context).show(context, AppMenu, Rect)`, `globalRectOf(context)`, `AppMenu`, `AppMenuAction(label:, onSelected:)`, and `RecordingMenus(choose:)` in `test/support/recording_menus.dart`.
- Produces:
  - `AppIcon.mainMenu` (GNOME `open-menu`, Lucide `menu`), replacing `AppIcon.settings`.
  - `LibraryScreen()` with no parameters.
  - `LibraryToolbar.onOpenSettings` is kept, and now feeds the menu's Preferences item.
  - Toolbar focus node debug label `library-main-menu`.

- [ ] **Step 1: Swap the icon**

In `lib/ui/icons/app_icons.dart`, replace `settings('cogged-wheel', 'settings'),` with:

```dart
  mainMenu('open-menu', 'menu'),
```

In `tool/fetch_icons.py`, in `GNOME`, replace `"cogged-wheel"` with `"open-menu"`. In `LUCIDE`, replace `"settings"` with `"menu"`. Then regenerate the assets (this needs network access, and pins the same GNOME commit and Lucide version, so existing files come back byte-identical):

Run: `python3 tool/fetch_icons.py && git status --short assets/icons`
Expected: `D assets/icons/gnome/cogged-wheel.svg`, `D assets/icons/lucide/settings.svg`, `?? assets/icons/gnome/open-menu.svg` and `?? assets/icons/lucide/menu.svg`, and nothing else.

- [ ] **Step 2: Write the failing library tests**

In `test/features/library/library_screen_test.dart`:

1. Add the imports:

```dart
import 'package:stash_player_flutter/ui/menu/app_menu.dart';
import 'package:stash_player_flutter/ui/menu/native_menus.dart';

import '../../support/recording_menus.dart';
```

The file already imports `app_controller.dart` (it expects `AppDestination.connection()`). If not, add `import 'package:stash_player_flutter/app/app_controller.dart';`.

2. Change `_pumpLibrary`'s signature and body. Replace the `VoidCallback? onOpenSettings,` parameter with `NativeMenus? menus, List<Override> overrides = const [],`. Append `...overrides,` to the end of the `ProviderContainer` `overrides:` list. Replace the `home:` line with:

```dart
        home: menus == null
            ? const LibraryScreen()
            : NativeMenusScope(menus: menus, child: const LibraryScreen()),
```

3. At the end of the file, add:

```dart
/// Starts on the library, so `openSettings` has somewhere to act. The
/// default `AppController` starts on the connection destination.
class _LibraryAppController extends AppController {
  @override
  AppDestination build() => const AppDestination.library();
}
```

4. In `'every strip control carries a tooltip'`, replace `('Connection settings', 'Connection settings'),` with `('Main Menu', 'Main menu'),`. In `'every icon-only control has a descriptive tooltip'`, replace `find.byTooltip('Connection settings')` with `find.byTooltip('Main Menu')`.
5. In both Tab-order tests, replace `'library-settings'` with `'library-main-menu'`. In their descriptions, replace the word `settings` with `the main menu`.
6. Add a new group inside `main()`:

```dart
  group('settings entry points', () {
    testWidgets('the main menu offers Preferences, which opens settings', (
      tester,
    ) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      final menus = RecordingMenus(choose: 'Preferences');
      final harness = await _pumpLibrary(
        tester,
        api: api,
        menus: menus,
        overrides: [appControllerProvider.overrideWith(_LibraryAppController.new)],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Main Menu'));
      await tester.pump();

      expect(
        menus.shown.single.entries.whereType<AppMenuAction>().map(
          (action) => action.label,
        ),
        ['Preferences'],
      );
      expect(
        harness.container.read(appControllerProvider),
        const LibraryDestination(settingsOpen: true),
      );
    });

    testWidgets('Ctrl+, opens settings from the library', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      final harness = await _pumpLibrary(
        tester,
        api: api,
        overrides: [appControllerProvider.overrideWith(_LibraryAppController.new)],
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(
        harness.container.read(appControllerProvider),
        const LibraryDestination(settingsOpen: true),
      );
    });

    testWidgets('a bare comma does not open settings', (tester) async {
      final api = FakeStashApi()
        ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
      final harness = await _pumpLibrary(
        tester,
        api: api,
        overrides: [appControllerProvider.overrideWith(_LibraryAppController.new)],
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.comma);

      expect(
        harness.container.read(appControllerProvider),
        const AppDestination.library(),
      );
    });
  });
```

`_Harness` exposes `container` (see its fields: `container`, `controller`, `api`).

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/features/library/library_screen_test.dart`
Expected: a compile error, because `LibraryScreen` still requires `onOpenSettings`.

- [ ] **Step 4: Implement the toolbar's main menu**

In `lib/features/library/library_toolbar.dart`:

1. Add the imports `import '../../ui/menu/app_menu.dart';` and `import '../../ui/menu/native_menus.dart';`. `dart:async` is already imported for `Timer`.
2. Give the `onOpenSettings` field this doc comment:

```dart
  /// Opens connection settings. Offered as Preferences in GNOME's main
  /// menu at the end of the strip.
  final VoidCallback onOpenSettings;
```

3. Rename `_settingsFocusNode` to `_mainMenuFocusNode` with `debugLabel: 'library-main-menu'` (declaration and `dispose`).
4. In `_wideControls()` and `_narrowControls()`, replace `_settingsButton()` with `_mainMenuButton()`, keeping the same `_ordered` numbers.
5. In the `_wideControls` doc comment, change "then Scan, Tasks and settings" to "then Scan, Tasks and the main menu". Do the same in the class doc comment near line 13, where "settings" becomes "the main menu".
6. Replace `_settingsButton()` with:

```dart
  /// GNOME's primary menu. It holds only Preferences for now. An About
  /// item would join it once the app has an About dialog on Linux.
  Widget _mainMenuButton() => Builder(
    builder: (anchor) => AppIconAction(
      focusNode: _mainMenuFocusNode,
      icon: AppIcon.mainMenu,
      tooltip: 'Main Menu',
      semanticLabel: 'Main menu',
      onPressed: () => unawaited(
        NativeMenusScope.of(anchor).show(
          anchor,
          AppMenu([
            AppMenuAction(
              label: 'Preferences',
              onSelected: widget.onOpenSettings,
            ),
          ]),
          globalRectOf(anchor),
        ),
      ),
    ),
  );
```

- [ ] **Step 5: Implement the screen changes**

In `lib/features/library/library_screen.dart`:

1. Add the imports `import 'package:flutter/services.dart';` and `import '../../ui/theme/platform_dialect.dart';`.
2. Replace the constructor, the `onOpenSettings` field and the part of the class doc comment about settings ("Settings has no such owner … instead.") with:

```dart
/// Consumes [AppController.openScene] and [AppController.openSettings]
/// directly (via [ref]), since both destinations are owned by
/// [AppController] itself.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
```

Keep the doc comment's first paragraph as it is.

3. In `_LibraryScreenState`, change `initState` and add `dispose` and the key handler:

```dart
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    _scheduleLoadInitial();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  /// Ctrl+, opens Preferences, GNOME's shortcut for it.
  ///
  /// A global handler rather than a `Shortcuts` widget, so it works
  /// whatever has focus, including nothing. It acts only while the library
  /// is the top route, so the player (which keeps this screen mounted
  /// underneath) and the open dialog ignore it. macOS gets ⌘, from its
  /// menu bar item instead.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.comma) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return false;
    }
    if (!mounted ||
        PlatformDialect.of(context) == PlatformDialect.macos ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return false;
    }
    ref.read(appControllerProvider.notifier).openSettings();
    return true;
  }
```

4. In `build`, change the toolbar argument to:

```dart
            onOpenSettings: () =>
                ref.read(appControllerProvider.notifier).openSettings(),
```

- [ ] **Step 6: Drop the router wrapper**

In `lib/app/app_router.dart`, delete `_LibraryRoute`. Change `_libraryPage`'s child to `child: LibraryScreen(),` (it's already inside a `const`). Remove any imports the analyzer then reports as unused.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `flutter test test/features/library/ test/app/ test/ui/`
Expected: PASS, including `app_icons_test.dart`, which checks that every `AppIcon` asset exists and paints.

- [ ] **Step 8: Run the full check and commit**

Run: `just flutter-check`
Expected: PASS.

```bash
git add lib/ui/icons/app_icons.dart tool/fetch_icons.py assets/icons lib/features/library/library_toolbar.dart lib/features/library/library_screen.dart lib/app/app_router.dart test/features/library/library_screen_test.dart
git commit -m "feat(flutter): open settings from a GNOME main menu and Ctrl+,"
```

---

### Task 6: macOS "Settings…" (⌘,), no toolbar entry, and docs

**Files:**
- Modify: `lib/features/library/library_toolbar.dart`
- Modify: `lib/app/app_menu_bar.dart`
- Test: `test/app/app_menu_bar_test.dart`
- Test: `test/features/library/library_screen_test.dart`
- Modify: `README.md` (repo root), `apps/flutter/README.md`, `CLAUDE.md` (repo root)

**Interfaces:**
- Consumes: Task 1's `LibraryDestination` and `openSettings()`, and Task 5's `_mainMenuButton()`.
- Produces: `buildMacMenuBar({required AppMenu playback, required VoidCallback onCheckForUpdates, required VoidCallback? onOpenSettings})`.

- [ ] **Step 1: Write the failing menu bar tests**

In `test/app/app_menu_bar_test.dart`:

1. Add `onOpenSettings: null,` to the three existing `buildMacMenuBar(...)` calls.
2. Add this helper at the bottom of the file:

```dart
/// The app menu's item labelled [label].
PlatformMenuItem _appMenuItem(List<PlatformMenuItem> bar, String label) =>
    (bar.first as PlatformMenu).menus
        .cast<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .singleWhere((item) => item.label == label);
```

3. Add these tests inside `main()`:

```dart
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

  testWidgets(
    'Settings… is enabled on the library only',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, (call) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.menu, null),
      );

      Future<PlatformMenuItem> settingsAt(AppDestination destination) async {
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
        final bar = tester.widget<PlatformMenuBar>(
          find.byType(PlatformMenuBar),
        );
        return _appMenuItem(bar.menus, 'Settings…');
      }

      expect(
        (await settingsAt(const AppDestination.connection())).onSelected,
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
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
```

- [ ] **Step 2: Write the failing toolbar test**

In `test/features/library/library_screen_test.dart`, inside the `'settings entry points'` group, add:

```dart
    testWidgets(
      'macOS has no main menu in the toolbar',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        await _pumpLibrary(tester, api: api);
        await tester.pumpAndSettle();

        expect(find.byTooltip('Main Menu'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'Ctrl+, does nothing on macOS, where ⌘, is the menu bar\'s',
      (tester) async {
        final api = FakeStashApi()
          ..pages.add(ScenePage(total: 1, scenes: _scenes(1)));
        final harness = await _pumpLibrary(
          tester,
          api: api,
          overrides: [
            appControllerProvider.overrideWith(_LibraryAppController.new),
          ],
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        expect(
          harness.container.read(appControllerProvider),
          const AppDestination.library(),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
```

The second test already passes, thanks to Task 5's handler. It stays as a guard.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/app/app_menu_bar_test.dart test/features/library/library_screen_test.dart`
Expected: a compile error (`No named parameter with the name 'onOpenSettings'`) and a toolbar failure (the main menu is found on macOS).

- [ ] **Step 4: Hide the main menu on macOS**

In `lib/features/library/library_toolbar.dart`, add `import '../../ui/theme/platform_dialect.dart';`, and add this getter to `_LibraryToolbarState`:

```dart
  /// GNOME apps keep Preferences in a primary menu in the header bar.
  /// macOS apps have no such button: Settings… lives in the app menu, which
  /// `AppMenuBar` provides.
  bool get _showsMainMenu =>
      PlatformDialect.of(context) == PlatformDialect.adwaita;
```

Change the last two entries of `_wideControls()` from `const SizedBox(width: AppTokens.space2), _ordered(10, _mainMenuButton()),` to:

```dart
    if (_showsMainMenu) ...[
      const SizedBox(width: AppTokens.space2),
      _ordered(10, _mainMenuButton()),
    ],
```

and the last two entries of `_narrowControls()` the same way, with `_ordered(11, _mainMenuButton())`.

- [ ] **Step 5: Add Settings… to the menu bar**

In `lib/app/app_menu_bar.dart`:

1. In `AppMenuBar.build`, replace `final onScene = ref.watch(appControllerProvider) is SceneDestination;` with:

```dart
    final destination = ref.watch(appControllerProvider);
    final onScene = destination is SceneDestination;
```

and add to the `buildMacMenuBar(` call:

```dart
        onOpenSettings: destination is LibraryDestination
            ? ref.read(appControllerProvider.notifier).openSettings
            : null,
```

2. Change `buildMacMenuBar`'s signature to:

```dart
List<PlatformMenuItem> buildMacMenuBar({
  required AppMenu playback,
  required VoidCallback onCheckForUpdates,
  required VoidCallback? onOpenSettings,
}) => [
```

and add to its doc comment: "`onOpenSettings` is null wherever settings can't open (anywhere but the library), which AppKit shows as a disabled Settings… item."

3. In the `Stash Player` menu, insert a new group directly after the group holding About and "Check for Updates…":

```dart
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Settings…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.comma,
              meta: true,
            ),
            onSelected: onOpenSettings,
          ),
        ],
      ),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/app/ test/features/library/`
Expected: PASS.

- [ ] **Step 7: Update the docs**

- In the repo-root `README.md`, replace "Click **Test connection**. Once it connects, your library opens, and next time the app goes straight there. To change servers later, use the gear icon in the library toolbar." with:

```markdown
Click **Connect**. Once it connects, your library opens, and next time the
app goes straight there. To change servers later, open **Stash Player →
Settings…** (⌘,) on macOS, or **Preferences** in the main menu (Ctrl+,) on
Linux.
```

- In `apps/flutter/README.md`, change `then "Test connection".` to `then "Connect".`
- In the repo-root `CLAUDE.md`, under **`lib/app/`**, change `` `AppController` (the `AppDestination` union — connection / library / scene — plus bootstrap) `` to `` `AppController` (the `AppDestination` union — connection / library / scene, where library carries `settingsOpen` for the connection settings dialog — plus bootstrap) ``. Under **`lib/ui/`**, change `` `widgets/` (strip controls, spinner, toast, tile) `` to `` `widgets/` (strip controls, spinner, toast, tile, `AppDialog`/`AppDialogPage`, and the `AppPreferencesGroup`/`AppEntryRow` form rows) ``. Under **`lib/features/…`**, change `` `connection/` (the connection screen) `` to `` `connection/` (the first-launch screen, the settings dialog, and the `ConnectionForm` they share) ``.

- [ ] **Step 8: Run the full check and commit**

Run: `just flutter-check`
Expected: PASS.

```bash
git add lib/features/library/library_toolbar.dart lib/app/app_menu_bar.dart test/app/app_menu_bar_test.dart test/features/library/library_screen_test.dart
git add ../../README.md README.md ../../CLAUDE.md
git commit -m "feat(flutter): open settings from the macOS app menu with ⌘,"
```

---

## Manual checks (after Task 6)

Run `just flutter-run` on each platform:

- [ ] Linux: the ☰ button opens a native GTK menu, Preferences opens the dialog, and Ctrl+, opens it from the library but not from the player.
- [ ] Linux: a wrong URL keeps the dialog open with the error under the URL row. A good URL closes it and shows the "Connected to …" toast.
- [ ] Linux: clicking the dimmed window closes the dialog.
- [ ] macOS: Stash Player → Settings… and ⌘, open the sheet under the titlebar. The item is disabled while a scene plays, and Return saves.
- [ ] Both: during a slow test (point it at an unroutable address), Cancel and Esc stay disabled until it ends.
- [ ] Both: the first-launch page shows the grouped form and a Connect button.
