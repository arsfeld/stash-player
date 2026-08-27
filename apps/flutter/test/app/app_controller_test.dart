import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app_controller.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/providers.dart';
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/features/connection/connection_controller.dart';

import '../support/fakes.dart';

void main() {
  ({ProviderContainer container, FakeConnectionStore store}) buildContainer({
    ConnectionConfig saved = const ConnectionConfig(),
    Future<ConnectionConfig>? loadFuture,
    Map<String, String> environment = const {},
  }) {
    final store = FakeConnectionStore(saved: saved, loadFuture: loadFuture);
    final container = ProviderContainer(
      overrides: [
        connectionStoreProvider.overrideWithValue(store),
        environmentProvider.overrideWithValue(environment),
        stashApiFactoryProvider.overrideWithValue(
          (config) => FakeStashApi(versionValue: 'v0.31.0'),
        ),
        connectionControllerOverride,
      ],
    );
    addTearDown(container.dispose);
    return (container: container, store: store);
  }

  test(
    'no saved URL selects the connection destination, with no notice',
    () async {
      final (:container, :store) = buildContainer();

      await container.read(appControllerProvider.notifier).bootstrap();

      expect(
        container.read(appControllerProvider),
        const AppDestination.connection(),
      );
      expect(container.read(globalNoticeProvider), isNull);
      expect(store.saveCalls, isEmpty);
    },
  );

  test(
    'a valid stored/effective connection selects the library destination',
    () async {
      final (:container, :store) = buildContainer(
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
      expect(store.saveCalls, isEmpty);
    },
  );

  test('a bootstrap failure stays on the connection destination and reports '
      'the error as a notice, not a stored-config failure', () async {
    final (:container, :store) = buildContainer(
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
    expect(store.saveCalls, isEmpty);
  });

  test(
    'successful settings replacement creates a new API instance, bumps the '
    'generation, returns to the library, and emits a Connected notice',
    () async {
      final (:container, :store) = buildContainer(
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
      // The controller was never independently `ready` for this config
      // before the call, so the alreadyReady short-circuit must not
      // trigger — this went through testAndSave and persisted once.
      expect(store.saveCalls, hasLength(1));
      expect(store.saveCalls.single.serverUrl, 'https://new.test');
    },
  );

  test('replaceConnection skips re-validating when the controller is already '
      'ready for the exact same config', () async {
    final (:container, :store) = buildContainer(
      saved: const ConnectionConfig(
        serverUrl: 'https://stash.test',
        apiKey: 'key',
      ),
    );
    final notifier = container.read(appControllerProvider.notifier);
    const config = ConnectionConfig(
      serverUrl: 'https://stash.test',
      apiKey: 'key',
    );

    // Get the controller into `ready` for `config` directly, the same
    // way ConnectionScreen's own "Test connection" button would, before
    // AppController ever gets involved.
    await container.read(connectionControllerProvider).testAndSave(config);
    expect(store.saveCalls, hasLength(1));

    await notifier.replaceConnection(config);

    // No second testAndSave/save — the short-circuit took effect — but
    // the generation still bumps and the destination still becomes the
    // library, exactly as a fresh validate-and-save would have done.
    expect(store.saveCalls, hasLength(1));
    expect(
      container.read(appControllerProvider),
      const AppDestination.library(),
    );
    expect(container.read(connectionGenerationProvider), 1);
    final notice = container.read(globalNoticeProvider);
    expect(notice?.message, 'Connected to v0.31.0');
  });

  test('replaceConnection revalidates when the controller is ready for a '
      'different config', () async {
    final (:container, :store) = buildContainer();
    final notifier = container.read(appControllerProvider.notifier);

    await container
        .read(connectionControllerProvider)
        .testAndSave(const ConnectionConfig(serverUrl: 'https://one.test'));
    expect(store.saveCalls, hasLength(1));

    await notifier.replaceConnection(
      const ConnectionConfig(serverUrl: 'https://two.test'),
    );

    // A different config than the one the controller was `ready` for —
    // the short-circuit must not trigger, so this goes through
    // testAndSave/save again.
    expect(store.saveCalls, hasLength(2));
    expect(store.saveCalls.last.serverUrl, 'https://two.test');
    expect(
      container.read(appControllerProvider),
      const AppDestination.library(),
    );
  });
}
