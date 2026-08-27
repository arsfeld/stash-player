import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';
import 'package:stash_player_flutter/features/connection/connection_screen.dart';

import '../../support/fakes.dart';

void main() {
  testWidgets('shows URL, optional API key, and a masked-key toggle', (
    tester,
  ) async {
    final controller = _controller();
    await _pump(tester, controller: controller);

    expect(find.bySemanticsLabel('Stash server URL'), findsOneWidget);
    expect(find.bySemanticsLabel('Stash API key (optional)'), findsOneWidget);
    expect(find.byTooltip('Show API key'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);

    final keyField = tester.widget<TextField>(_apiKeyField);
    expect(keyField.obscureText, isTrue);
    await tester.tap(find.byTooltip('Show API key'));
    await tester.pump();
    expect(tester.widget<TextField>(_apiKeyField).obscureText, isFalse);
  });

  testWidgets('moves focus from URL to API key with the keyboard', (
    tester,
  ) async {
    final controller = _controller();
    await _pump(tester, controller: controller);

    await tester.tap(_serverUrlField);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    expect(tester.widget<TextField>(_apiKeyField).focusNode!.hasFocus, isTrue);
  });

  testWidgets('shows validation only on the URL field', (tester) async {
    final controller = _controller();
    await _pump(tester, controller: controller);

    await tester.enterText(_serverUrlField, 'stash');
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(
      find.text('Enter a valid http or https server URL.'),
      findsOneWidget,
    );
    expect(find.text('Could not reach Stash.'), findsNothing);
  });

  testWidgets('shows server errors and finishes only after a success', (
    tester,
  ) async {
    var connected = 0;
    final failedController = _controller(
      failure: const TransportFailure('unreachable'),
    );
    await _pump(
      tester,
      controller: failedController,
      onConnected: () => connected++,
    );

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(
      find.text(
        'Could not reach Stash. Check the server URL and network connection.',
      ),
      findsOneWidget,
    );
    expect(connected, 0);

    final successController = _controller();
    await _pump(
      tester,
      controller: successController,
      onConnected: () => connected++,
    );
    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(find.text('Connected to Stash v0.31.0.'), findsOneWidget);
    expect(connected, 1);
  });

  testWidgets(
    'shows progress while testing and exposes Cancel in settings mode',
    (tester) async {
      final completer = Completer<String>();
      final controller = ConnectionController(
        store: FakeConnectionStore(),
        environment: const {},
        apiFactory: (_) => FakeStashApi(versionFuture: completer.future),
      );
      var cancelled = 0;
      await _pump(
        tester,
        controller: controller,
        settingsMode: true,
        onCancel: () => cancelled++,
      );

      await tester.enterText(_serverUrlField, 'https://stash.test');
      await tester.tap(find.text('Test connection'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(cancelled, 1);
      completer.complete('v0.31.0');
      await tester.pump();
    },
  );
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
  VoidCallback? onCancel,
  bool settingsMode = false,
}) => tester.pumpWidget(
  ProviderScope(
    key: ValueKey(controller),
    overrides: [connectionControllerProvider.overrideWith((ref) => controller)],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: false),
      home: ConnectionScreen(
        initialConfig: const ConnectionConfig(),
        onConnected: onConnected ?? () {},
        onCancel: onCancel,
        settingsMode: settingsMode,
      ),
    ),
  ),
);

final _serverUrlField = find.byKey(const Key('connection-server-url'));
final _apiKeyField = find.byKey(const Key('connection-api-key'));
