import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet_host.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';

import '../../support/fake_connection_sheet.dart';
import '../../support/fakes.dart';

void main() {
  testWidgets('open presents the sheet and still renders the child', (
    tester,
  ) async {
    final sheet = FakeConnectionSheet();
    await _pump(tester, sheet: sheet, open: ValueNotifier(true));
    await tester.pump();

    final presented = sheet.presented!;
    expect(presented.title, 'Connection');
    expect(presented.confirmLabel, 'Save');
    expect(presented.cancellable, isTrue);
    expect(sheet.isOpen, isTrue);
    expect(find.text('child'), findsOneWidget);
  });

  testWidgets('closing the host dismisses the sheet', (tester) async {
    final sheet = FakeConnectionSheet();
    final open = ValueNotifier(true);
    await _pump(tester, sheet: sheet, open: open);
    await tester.pump();
    expect(sheet.isOpen, isTrue);

    open.value = false;
    await tester.pump();

    expect(sheet.dismissed, isTrue);
  });

  testWidgets('Cancel in the sheet calls onCancelled', (tester) async {
    final sheet = FakeConnectionSheet();
    final harness = await _pump(
      tester,
      sheet: sheet,
      open: ValueNotifier(true),
    );
    await tester.pump();

    sheet.send(const ConnectionSheetCancelled());

    expect(harness.cancelled, 1);
  });

  testWidgets('a successful submit calls onConnected with the config', (
    tester,
  ) async {
    final sheet = FakeConnectionSheet();
    final harness = await _pump(
      tester,
      sheet: sheet,
      open: ValueNotifier(true),
    );
    await tester.pump();

    sheet.send(
      const ConnectionSheetSubmitted(
        ConnectionConfig(serverUrl: 'https://stash.test'),
      ),
    );
    await tester.pump();

    expect(harness.connected.single.serverUrl, 'https://stash.test');
    expect(sheet.dismissed, isTrue);
  });

  testWidgets('a sheet that fails to open disables the provider', (
    tester,
  ) async {
    final sheet = FakeConnectionSheet(failPresent: true);
    await _pump(tester, sheet: sheet, open: ValueNotifier(true));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.text('child')),
    );
    expect(container.read(connectionSheetProvider), isNull);
    expect(find.text('child'), findsOneWidget);
  });

  testWidgets('with no sheet, nothing is presented and the child renders', (
    tester,
  ) async {
    final harness = await _pump(tester, sheet: null, open: ValueNotifier(true));
    await tester.pump();

    expect(find.text('child'), findsOneWidget);
    expect(harness.connected, isEmpty);
    expect(harness.cancelled, 0);
  });
}

class _Harness {
  final connected = <ConnectionConfig>[];
  var cancelled = 0;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required ConnectionSheet? sheet,
  required ValueNotifier<bool> open,
}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionSheetProvider.overrideWith(
          () => FakeConnectionSheetNotifier(sheet),
        ),
        connectionStoreProvider.overrideWithValue(FakeConnectionStore()),
        environmentProvider.overrideWithValue(const {}),
        stashApiFactoryProvider.overrideWithValue(
          (_) => FakeStashApi(versionValue: 'v0.31.0'),
        ),
        connectionControllerOverride,
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ValueListenableBuilder<bool>(
          valueListenable: open,
          builder: (context, isOpen, _) => ConnectionSheetHost(
            open: isOpen,
            title: 'Connection',
            confirmLabel: 'Save',
            cancellable: true,
            onConnected: harness.connected.add,
            onCancelled: () => harness.cancelled++,
            child: const Text('child'),
          ),
        ),
      ),
    ),
  );
  return harness;
}
