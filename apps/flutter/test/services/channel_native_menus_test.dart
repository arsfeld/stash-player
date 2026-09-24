import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/channel_native_menus.dart';
import 'package:stash_player_flutter/ui/menu/app_menu.dart';

import '../support/recording_menus.dart';

const _channel = MethodChannel('stash_player/menu');

void main() {
  late List<String> picked;
  late AppMenu menu;
  late BuildContext context;

  setUp(() {
    picked = [];
    menu = AppMenu([
      AppMenuAction(
        label: 'One',
        checked: true,
        onSelected: () => picked.add('One'),
      ),
      const AppMenuSeparator(),
      AppMenuAction(
        label: 'Two',
        enabled: false,
        onSelected: () => picked.add('Two'),
      ),
    ]);
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  void answer(Object? Function(MethodCall call) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => handler(call));

  Future<void> pumpContext(WidgetTester tester) => tester.pumpWidget(
    Builder(
      builder: (c) {
        context = c;
        return const SizedBox();
      },
    ),
  );

  testWidgets('sends the spec and the anchor', (tester) async {
    await pumpContext(tester);
    MethodCall? sent;
    answer((call) {
      sent = call;
      return null;
    });

    await ChannelNativeMenus().show(
      context,
      menu,
      const Rect.fromLTWH(10, 20, 30, 40),
    );

    expect(sent?.method, 'show');
    expect(sent?.arguments, {
      'anchor': {'x': 10.0, 'y': 20.0, 'width': 30.0, 'height': 40.0},
      'items': [
        {
          'type': 'action',
          'id': 0,
          'label': 'One',
          'enabled': true,
          'checked': true,
        },
        {'type': 'separator'},
        {
          'type': 'action',
          'id': 1,
          'label': 'Two',
          'enabled': false,
          'checked': null,
        },
      ],
    });
    expect(picked, isEmpty);
  });

  testWidgets('runs the action whose id comes back', (tester) async {
    await pumpContext(tester);
    answer((_) => 0);
    await ChannelNativeMenus().show(context, menu, Rect.zero);
    expect(picked, ['One']);
  });

  testWidgets('an unknown id runs nothing', (tester) async {
    await pumpContext(tester);
    answer((_) => 7);
    await ChannelNativeMenus().show(context, menu, Rect.zero);
    expect(picked, isEmpty);
  });

  testWidgets('with no native side, falls back to the drawn renderer', (
    tester,
  ) async {
    await pumpContext(tester);
    // Leaving the channel with no mock handler at all (rather than one
    // that throws) doesn't simulate "no native side" here: on this
    // project's resolved Flutter SDK (3.41.6 stable),
    // `TestDefaultBinaryMessenger.send` falls through to the real
    // `flutter_tester` engine for a channel with no handler registered,
    // and that call never completes inside a test's `FakeAsync` zone, so
    // the test hangs to its 10-minute timeout instead of failing fast.
    // Registering a handler that throws `MissingPluginException` is what
    // a genuinely absent platform side looks like on the wire (the
    // channel's codec turns it into a null reply, which is what
    // `MethodChannel.invokeMethod` treats as "no plugin"), so this
    // reproduces the real case deterministically.
    answer((_) => throw MissingPluginException());
    final fallback = RecordingMenus(choose: 'One');
    await ChannelNativeMenus(fallback: fallback).show(context, menu, Rect.zero);
    expect(fallback.shown, hasLength(1));
    expect(picked, ['One']);
  });

  testWidgets('a native error also falls back', (tester) async {
    await pumpContext(tester);
    answer((_) => throw PlatformException(code: 'no-window'));
    final fallback = RecordingMenus();
    await ChannelNativeMenus(fallback: fallback).show(context, menu, Rect.zero);
    expect(fallback.shown, hasLength(1));
  });
}
