import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/channel_window_frame.dart';
import 'package:stash_player_flutter/ui/window/window_frame.dart';

const _channel = MethodChannel('stash_player/window');

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

  Future<void> deliver(String method, Object? args) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('sends each call with its argument', () async {
    final frame = ChannelWindowFrame();
    await frame.reset();
    await frame.setImmersive(true);
    await frame.setControlsVisible(false);
    await frame.startDrag();

    expect(sent.map((call) => '${call.method} ${call.arguments}'), [
      'reset null',
      'setImmersive true',
      'setControlsVisible false',
      'startDrag null',
    ]);
  });

  test('native events move the listenables', () async {
    final frame = ChannelWindowFrame();

    await deliver('insetsChanged', {'leading': 0, 'trailing': 96.5});
    await deliver('controlsHovered', true);

    expect(frame.insets.value, const WindowButtonInsets(trailing: 96.5));
    expect(frame.controlsHovered.value, isTrue);
  });

  test('a missing plugin turns every call into a no-op', () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final frame = ChannelWindowFrame();

    await frame.setImmersive(true);
    await frame.setControlsVisible(false);
    await frame.startDrag();

    expect(frame.insets.value, WindowButtonInsets.zero);
    expect(frame.controlsHovered.value, isFalse);
  });

  test('a platform error stops further sends and clears state', () async {
    final frame = ChannelWindowFrame();
    await deliver('insetsChanged', {'leading': 0.0, 'trailing': 96.0});
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      throw PlatformException(code: 'unavailable');
    });

    await frame.setImmersive(true);
    await frame.setImmersive(false);

    expect(sent, hasLength(1));
    expect(frame.insets.value, WindowButtonInsets.zero);
  });
}
