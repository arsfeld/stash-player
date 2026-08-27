import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'services/platform_connection_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Platform storage needs async setup, so it's constructed here rather
  // than inside `connectionStoreProvider`'s body — see that provider's
  // doc comment.
  final connectionStore = await PlatformConnectionStore.create();

  runApp(
    ProviderScope(
      overrides: [
        connectionStoreProvider.overrideWithValue(connectionStore),
        connectionControllerOverride,
      ],
      child: const StashPlayerApp(),
    ),
  );
}
