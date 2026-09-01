import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';
import 'package:stash_player_flutter/features/connection/connection_screen.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

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
    // `find.text` needs an exact match — the real copy is 'Could not
    // reach Stash. Check the server URL and network connection.', so a
    // truncated `find.text('Could not reach Stash.')` could never match
    // under any implementation and would pass even if URL validation
    // wrongly rendered the network-error copy (final review §3b).
    // `textContaining` actually rules that out.
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
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(store.saveCalls.single.socksProxy, '127.0.0.1:1055');
  });

  testWidgets('shows proxy validation under the proxy field', (tester) async {
    final controller = _controller();
    await _pump(tester, controller: controller);

    await tester.enterText(_serverUrlField, 'https://stash.test');
    await tester.enterText(_socksProxyField, 'not a proxy');
    await tester.tap(find.text('Test connection'));
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

  testWidgets('does not overflow in settings mode at a raised text scale and a '
      'short height', (tester) async {
    // 800 wide keeps `AppWindowChrome`'s own strip (back button, spacing,
    // title) clear of its own separate width limit at this text scale,
    // so this test isolates the form's vertical overflow protection
    // rather than the strip's horizontal one. Without the screen's
    // scroll wrapper, this exact size overflows the bottom by 248
    // pixels; a bare `SingleChildScrollView` alone is not enough to fix
    // that without also losing vertical centring at normal sizes, which
    // is why the screen builds it with a `LayoutBuilder` instead.
    final controller = _controller();
    await _pump(
      tester,
      controller: controller,
      settingsMode: true,
      onCancel: () {},
      size: const Size(800, 320),
      textScaler: const TextScaler.linear(1.3),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('mounts without initialConfig and fills fields from the loaded '
      'config', (tester) async {
    final store = FakeConnectionStore(
      saved: const ConnectionConfig(
        serverUrl: 'https://loaded.test',
        apiKey: 'loaded-key',
      ),
    );
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await _pump(tester, controller: controller, initialConfig: null);
    await tester.pump();

    expect(
      tester.widget<TextField>(_serverUrlField).controller!.text,
      'https://loaded.test',
    );
    expect(
      tester.widget<TextField>(_apiKeyField).controller!.text,
      'loaded-key',
    );
  });

  testWidgets('settings-mode mount pre-fills fields from the stored config', (
    tester,
  ) async {
    final store = FakeConnectionStore(
      saved: const ConnectionConfig(
        serverUrl: 'https://settings.test',
        apiKey: 'settings-key',
      ),
    );
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await _pump(
      tester,
      controller: controller,
      initialConfig: null,
      settingsMode: true,
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(_serverUrlField).controller!.text,
      'https://settings.test',
    );
    expect(
      tester.widget<TextField>(_apiKeyField).controller!.text,
      'settings-key',
    );
  });

  testWidgets('does not clobber text already typed once a late load '
      'resolves', (tester) async {
    final completer = Completer<ConnectionConfig>();
    final store = FakeConnectionStore(loadFuture: completer.future);
    final controller = ConnectionController(
      store: store,
      environment: const {},
      apiFactory: (_) => FakeStashApi(versionValue: 'v0.31.0'),
    );

    await _pump(tester, controller: controller, initialConfig: null);
    await tester.enterText(_serverUrlField, 'https://typed-by-user.test');

    completer.complete(
      const ConnectionConfig(
        serverUrl: 'https://loaded.test',
        apiKey: 'loaded-key',
      ),
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(_serverUrlField).controller!.text,
      'https://typed-by-user.test',
    );
    expect(
      tester.widget<TextField>(_apiKeyField).controller!.text,
      'loaded-key',
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
  VoidCallback? onCancel,
  bool settingsMode = false,
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
          onCancel: onCancel,
          settingsMode: settingsMode,
        ),
      ),
    ),
  );
}

final _serverUrlField = find.byKey(const Key('connection-server-url'));
final _socksProxyField = find.byKey(const Key('connection-socks-proxy'));
final _apiKeyField = find.byKey(const Key('connection-api-key'));
