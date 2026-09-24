import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/channel_native_toolbar.dart';
import 'package:stash_player_flutter/ui/icons/app_icons.dart';
import 'package:stash_player_flutter/ui/toolbar/app_toolbar.dart';

const _channel = MethodChannel('stash_player/toolbar');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> sent;
  late List<String> events;

  setUp(() {
    sent = [];
    events = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  AppToolbar spec({bool badge = false, String text = ''}) => AppToolbar([
    AppToolbarGroup(
      id: 'filters',
      label: 'Filters',
      children: [
        AppToolbarMenu(
          id: 'sort',
          label: 'Sort by',
          options: const ['Date', 'Title'],
          selected: 1,
          onSelected: (index) => events.add('sort $index'),
        ),
        AppToolbarToggle(
          id: 'hide',
          label: 'Hide played',
          icon: AppIcon.eyeOff,
          selected: true,
          onPressed: () => events.add('hide'),
        ),
      ],
    ),
    const AppToolbarSpace(),
    AppToolbarSearch(
      id: 'search',
      label: 'Search',
      text: text,
      placeholder: 'Search scenes',
      onChanged: (value) => events.add('search $value'),
    ),
    AppToolbarAction(
      id: 'tasks',
      label: 'Background tasks',
      icon: AppIcon.tasks,
      badge: badge,
      onPressed: (anchor) => events.add('tasks $anchor'),
    ),
    const AppToolbarAction(
      id: 'scan',
      label: 'Scan',
      icon: AppIcon.scan,
      onPressed: null,
    ),
  ]);

  Future<void> deliver(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('serializes every item kind', () async {
    expect(await ChannelNativeToolbar().set(spec(badge: true)), isTrue);

    expect(sent.single.method, 'setItems');
    final items = (sent.single.arguments as List).cast<Map>();
    expect(items.map((item) => item['type']), [
      'group',
      'space',
      'search',
      'action',
      'action',
    ]);
    final children = (items[0]['children'] as List).cast<Map>();
    expect(children[0], {
      'type': 'menu',
      'id': 'sort',
      'label': 'Sort by',
      'tooltip': 'Sort by',
      'options': ['Date', 'Title'],
      'selected': 1,
    });
    expect(children[1], {
      'type': 'toggle',
      'id': 'hide',
      'label': 'Hide played',
      'tooltip': 'Hide played',
      'symbol': 'eye.slash',
      'selected': true,
    });
    expect(items[2], containsPair('placeholder', 'Search scenes'));
    expect(items[3], containsPair('badge', true));
    expect(items[3], containsPair('symbol', 'list.bullet.rectangle'));
    expect(items[4], containsPair('enabled', false));
  });

  test('drops a spec identical to the last one sent', () async {
    final toolbar = ChannelNativeToolbar();
    await toolbar.set(spec());
    await toolbar.set(spec());
    await toolbar.set(spec(badge: true));

    expect(sent, hasLength(2));
  });

  test(
    'resends a spec equal to the last one while another is in flight',
    () async {
      final toolbar = ChannelNativeToolbar();
      await toolbar.set(spec());
      // B is still in flight when A comes back: A must not be dropped as a
      // duplicate of the spec before B.
      final inFlight = toolbar.set(spec(badge: true));
      final again = toolbar.set(spec());
      await Future.wait([inFlight, again]);

      expect(sent.where((call) => call.method == 'setItems'), hasLength(3));
      final last = sent.last.arguments as List<Object?>;
      expect(last[3], containsPair('badge', false));
    },
  );

  test('routes native events to the current callbacks', () async {
    await ChannelNativeToolbar().set(spec());

    await deliver('menuSelected', {'id': 'sort', 'index': 0});
    await deliver('activated', {'id': 'hide'});
    await deliver('searchChanged', {'id': 'search', 'text': 'kyoto'});
    await deliver('activated', {
      'id': 'tasks',
      'rect': {'x': 10.0, 'y': 0.0, 'width': 28.0, 'height': 52.0},
    });
    await deliver('activated', {'id': 'tasks'});

    expect(events, [
      'sort 0',
      'hide',
      'search kyoto',
      'tasks ${const Rect.fromLTWH(10, 0, 28, 52)}',
      'tasks null',
    ]);
  });

  test('ignores unknown ids, disabled actions and bad indexes', () async {
    await ChannelNativeToolbar().set(spec());

    await deliver('activated', {'id': 'gone'});
    await deliver('activated', {'id': 'scan'});
    await deliver('menuSelected', {'id': 'sort', 'index': 7});

    expect(events, isEmpty);
  });

  test(
    'reports unavailable and stops sending when the plugin is missing',
    () async {
      messenger.setMockMethodCallHandler(_channel, null);
      final toolbar = ChannelNativeToolbar();

      expect(await toolbar.set(spec()), isFalse);
      expect(await toolbar.set(spec(badge: true)), isFalse);
    },
  );
}
