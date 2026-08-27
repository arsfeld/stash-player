import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';

import '../support/fakes.dart';

void main() {
  ProviderContainer buildContainer({
    ConnectionConfig saved = const ConnectionConfig(),
    Future<ConnectionConfig>? loadFuture,
    Map<String, String> environment = const {},
  }) {
    final container = ProviderContainer(
      overrides: [
        connectionStoreProvider.overrideWithValue(
          FakeConnectionStore(saved: saved, loadFuture: loadFuture),
        ),
        environmentProvider.overrideWithValue(environment),
        stashApiFactoryProvider.overrideWithValue(
          (config) => FakeStashApi(versionValue: 'v0.31.0'),
        ),
        connectionControllerOverride,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'no saved URL selects the connection destination, with no notice',
    () async {
      final container = buildContainer();

      await container.read(appControllerProvider.notifier).bootstrap();

      expect(
        container.read(appControllerProvider),
        const AppDestination.connection(),
      );
      expect(container.read(globalNoticeProvider), isNull);
    },
  );

  test(
    'a valid stored/effective connection selects the library destination',
    () async {
      final container = buildContainer(
        saved: const ConnectionConfig(
          serverUrl: 'https://stash.test',
          apiKey: 'key',
        ),
      );

      await container.read(appControllerProvider.notifier).bootstrap();

      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
    },
  );

  test('a bootstrap failure stays on the connection destination and reports '
      'the error as a notice, not a stored-config failure', () async {
    final container = buildContainer(
      loadFuture: Future<ConnectionConfig>.error(Exception('disk error')),
    );

    await container.read(appControllerProvider.notifier).bootstrap();

    expect(
      container.read(appControllerProvider),
      const AppDestination.connection(),
    );
    final notice = container.read(globalNoticeProvider);
    expect(notice, isNotNull);
    expect(notice!.severity, AppNoticeSeverity.error);
    expect(notice.message, 'Could not load saved connection settings.');
  });

  test(
    'successful settings replacement creates a new API instance, bumps the '
    'generation, returns to the library, and emits a Connected notice',
    () async {
      final container = buildContainer(
        saved: const ConnectionConfig(
          serverUrl: 'https://old.test',
          apiKey: 'old-key',
        ),
      );
      final notifier = container.read(appControllerProvider.notifier);
      await notifier.bootstrap();
      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );

      final firstApi = await container.read(stashApiProvider.future);
      final firstApiAgain = await container.read(stashApiProvider.future);
      expect(identical(firstApi, firstApiAgain), isTrue);
      final generationBefore = container.read(connectionGenerationProvider);

      await notifier.replaceConnection(
        const ConnectionConfig(
          serverUrl: 'https://new.test',
          apiKey: 'new-key',
        ),
      );

      expect(
        container.read(appControllerProvider),
        const AppDestination.library(),
      );
      expect(
        container.read(connectionGenerationProvider),
        generationBefore + 1,
      );

      final secondApi = await container.read(stashApiProvider.future);
      expect(identical(firstApi, secondApi), isFalse);

      final notice = container.read(globalNoticeProvider);
      expect(notice, isNotNull);
      expect(notice!.message, 'Connected to v0.31.0');
      expect(notice.severity, AppNoticeSeverity.success);
    },
  );
}
