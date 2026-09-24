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
