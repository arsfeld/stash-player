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
    // enterText doesn't rebuild the tree, and Connect's enabled state is
    // rebuilt through a ListenableBuilder, so pump once before tapping or
    // this hits the still-disabled button.
    await tester.pump();
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
    // enterText doesn't rebuild the tree, and Connect's enabled state is
    // rebuilt through a ListenableBuilder, so pump once before tapping or
    // this hits the still-disabled button.
    await tester.pump();
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
    // enterText doesn't rebuild the tree, and Connect's enabled state is
    // rebuilt through a ListenableBuilder, so pump once before tapping or
    // this hits the still-disabled button.
    await tester.pump();
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
    // enterText doesn't rebuild the tree, and Connect's enabled state is
    // rebuilt through a ListenableBuilder, so pump once before tapping or
    // this hits the still-disabled button.
    await tester.pump();
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
    // enterText doesn't rebuild the tree, and Connect's enabled state is
    // rebuilt through a ListenableBuilder, so pump once before tapping or
    // this hits the still-disabled button.
    await tester.pump();
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
