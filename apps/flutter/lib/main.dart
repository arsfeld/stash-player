import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'services/platform_connection_store.dart';
import 'services/socks_forward_proxy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Platform storage needs async setup, so it's constructed here rather
  // than inside `connectionStoreProvider`'s body — see that provider's
  // doc comment.
  final connectionStore = await PlatformConnectionStore.create();
  final socksProxy = await _bindSocksProxy();

  runApp(
    ProviderScope(
      overrides: [
        connectionStoreProvider.overrideWithValue(connectionStore),
        socksForwardProxyProvider.overrideWithValue(socksProxy),
        connectionControllerOverride,
      ],
      child: const StashPlayerApp(),
    ),
  );
}

/// Binds the loopback forward proxy every outbound request can be routed
/// through. Bound unconditionally and left idle when no SOCKS proxy is
/// configured, so that a later settings change needs no new listener and no
/// URL a player is already streaming from goes stale.
///
/// A failure here is not fatal: the app runs without a proxy, and
/// [AppController] surfaces a notice if the stored settings wanted one.
Future<SocksForwardProxy?> _bindSocksProxy() async {
  try {
    return await SocksForwardProxy.bind();
  } on Object catch (error) {
    debugPrint('Could not bind the loopback proxy: $error');
    return null;
  }
}
