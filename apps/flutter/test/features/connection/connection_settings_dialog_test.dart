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

    // `enterText` only updates the field's `TextEditingController`; per
    // its own doc comment, the UI (here, Save's `onPressed`, which is
    // recomputed from `ConnectionFields.canSubmit`) needs an explicit
    // pump to pick that change up before the tap below can hit an
    // enabled button.
    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.pump();
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
    await tester.pump();
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
    await tester.pump();
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
