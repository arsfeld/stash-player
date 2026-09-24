import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/features/connection/connection_sheet.dart';
import 'package:stash_player_flutter/services/channel_connection_sheet.dart';

const _channel = MethodChannel('stash_player/connection_sheet');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> sent;

  setUp(() {
    sent = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  const request = ConnectionSheetRequest(
    title: 'Connection',
    confirmLabel: 'Save',
    cancellable: true,
    values: ConnectionConfig(serverUrl: 'https://stash.test', apiKey: 'k'),
    proxyHint: 'hint',
  );

  Future<void> deliver(String method, [Object? args]) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('present sends the request', () async {
    await ChannelConnectionSheet().present(request, (_) {});

    expect(sent.single.method, 'present');
    expect(sent.single.arguments, {
      'title': 'Connection',
      'confirmLabel': 'Save',
      'cancellable': true,
      'serverUrl': 'https://stash.test',
      'apiKey': 'k',
      'socksProxy': '',
      'proxyHint': 'hint',
    });
  });

  test('update sends the state', () async {
    await ChannelConnectionSheet().update(
      const ConnectionSheetState(canSubmit: true, busy: false, urlError: 'bad'),
    );

    expect(sent.single.method, 'update');
    expect(sent.single.arguments, {
      'canSubmit': true,
      'busy': false,
      'urlError': 'bad',
      'proxyError': null,
      'failure': null,
    });
  });

  test('decodes events until dismissed', () async {
    final events = <ConnectionSheetEvent>[];
    final sheet = ChannelConnectionSheet();
    await sheet.present(request, events.add);

    const values = {'serverUrl': 'https://x', 'apiKey': '', 'socksProxy': ''};
    await deliver('changed', values);
    await deliver('submitted', values);
    await deliver('cancelled');
    await sheet.dismiss();
    await deliver('cancelled');

    expect(events, hasLength(3));
    expect((events[0] as ConnectionSheetChanged).values.serverUrl, 'https://x');
    expect(events[1], isA<ConnectionSheetSubmitted>());
    expect(events[2], isA<ConnectionSheetCancelled>());
    expect(sent.last.method, 'dismiss');
  });

  test('present throws when the plugin is missing', () async {
    messenger.setMockMethodCallHandler(_channel, null);

    await expectLater(
      ChannelConnectionSheet().present(request, (_) {}),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
