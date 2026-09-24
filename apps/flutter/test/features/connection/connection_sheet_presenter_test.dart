import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';
import 'package:stash_player_flutter/features/connection/connection_form.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet_presenter.dart';

import '../../support/fake_connection_sheet.dart';
import '../../support/fakes.dart';

/// Builds a [ConnectionController] the way
/// `connection_controller_test.dart` does. Defaults [api] to a
/// [FakeStashApi] with a configured version: its bare default's
/// `version()` (no `versionValue`/`versionFailure`/`versionFuture` set)
/// throws a null-check error rather than succeeding, which would fail
/// every test here that expects `testAndSave` to actually succeed.
ConnectionController _controller({
  ConnectionConfig? saved,
  FakeStashApi? api,
}) => ConnectionController(
  store: FakeConnectionStore(saved: saved ?? const ConnectionConfig()),
  environment: const {},
  apiFactory: (_) => api ?? FakeStashApi(versionValue: 'v0.31.0'),
);

void main() {
  late FakeConnectionSheet sheet;
  late List<ConnectionConfig> connected;
  late int cancelled;

  ConnectionSheetPresenter presenter(ConnectionController controller) =>
      ConnectionSheetPresenter(
        sheet: sheet,
        controller: controller,
        onConnected: connected.add,
        onCancelled: () => cancelled++,
      );

  setUp(() {
    sheet = FakeConnectionSheet();
    connected = [];
    cancelled = 0;
  });

  test('loads the stored connection before presenting', () async {
    final controller = _controller(
      saved: const ConnectionConfig(serverUrl: 'https://old.test'),
    );
    await presenter(
      controller,
    ).open(title: 'Connection', confirmLabel: 'Save', cancellable: true);

    expect(sheet.presented!.values.serverUrl, 'https://old.test');
    expect(sheet.presented!.proxyHint, connectionProxyHint);
    expect(sheet.updates.last.canSubmit, isTrue);
  });

  test('canSubmit follows the URL field', () async {
    final controller = _controller();
    await presenter(controller).open(
      title: 'Connect to Stash',
      confirmLabel: 'Connect',
      cancellable: false,
    );
    expect(sheet.updates.last.canSubmit, isFalse);

    sheet.send(
      const ConnectionSheetChanged(
        ConnectionConfig(serverUrl: 'https://stash.test'),
      ),
    );
    expect(sheet.updates.last.canSubmit, isTrue);

    sheet.send(const ConnectionSheetChanged(ConnectionConfig(serverUrl: '  ')));
    expect(sheet.updates.last.canSubmit, isFalse);
  });

  test('a failed test shows busy, then the error, and stays open', () async {
    final controller = _controller(
      api: FakeStashApi(versionFailure: const TransportFailure('down')),
    );
    await presenter(
      controller,
    ).open(title: 'Connection', confirmLabel: 'Save', cancellable: true);

    sheet.send(
      const ConnectionSheetSubmitted(
        ConnectionConfig(serverUrl: 'https://stash.test'),
      ),
    );
    await pumpEventQueue();

    expect(sheet.updates.any((s) => s.busy), isTrue);
    expect(sheet.updates.last.busy, isFalse);
    expect(
      sheet.updates.last.failure ?? sheet.updates.last.urlError,
      isNotNull,
    );
    expect(sheet.dismissed, isFalse);
    expect(connected, isEmpty);
  });

  test('a bad proxy lands under the proxy field', () async {
    final controller = _controller();
    await presenter(
      controller,
    ).open(title: 'Connection', confirmLabel: 'Save', cancellable: true);

    sheet.send(
      const ConnectionSheetSubmitted(
        ConnectionConfig(serverUrl: 'https://stash.test', socksProxy: 'a:b:c'),
      ),
    );
    await pumpEventQueue();

    expect(sheet.updates.last.proxyError, isNotNull);
  });

  test('success dismisses and reports the config', () async {
    final controller = _controller();
    await presenter(
      controller,
    ).open(title: 'Connection', confirmLabel: 'Save', cancellable: true);

    sheet.send(
      const ConnectionSheetSubmitted(
        ConnectionConfig(serverUrl: 'https://stash.test'),
      ),
    );
    await pumpEventQueue();

    expect(sheet.dismissed, isTrue);
    expect(connected.single.serverUrl, 'https://stash.test');
  });

  test('cancel is reported and does not dismiss by itself', () async {
    final controller = _controller();
    await presenter(
      controller,
    ).open(title: 'Connection', confirmLabel: 'Save', cancellable: true);

    sheet.send(const ConnectionSheetCancelled());

    expect(cancelled, 1);
  });

  test('open rethrows when the sheet cannot be shown', () async {
    sheet.failPresent = true;
    await expectLater(
      presenter(
        _controller(),
      ).open(title: 'Connection', confirmLabel: 'Save', cancellable: true),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
