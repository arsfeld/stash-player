import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/notices.dart';
import 'package:stash_player_flutter/app/toast_host.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/app_toast.dart';

void main() {
  late ProviderContainer container;
  late int taps;

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    taps = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          builder: (context, child) => ToastHost(child: child!),
          home: Scaffold(
            body: SizedBox.expand(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('behind'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows a notice, then dismisses it', (tester) async {
    await pump(tester);
    container
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: 'Reconnected'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Reconnected'), findsOneWidget);

    await tester.pump(ToastHost.duration);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AppToast), findsNothing);
  });

  testWidgets('an error notice is tinted with the theme error colour', (
    tester,
  ) async {
    await pump(tester);
    container
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: 'Failed', severity: AppNoticeSeverity.error));
    await tester.pump();
    final toast = tester.widget<AppToast>(find.byType(AppToast));
    expect(
      toast.background,
      Theme.of(tester.element(find.byType(AppToast))).colorScheme.error,
    );
  });

  testWidgets('the app underneath still takes taps while a toast is up', (
    tester,
  ) async {
    await pump(tester);
    container
        .read(globalNoticeProvider.notifier)
        .show(AppNotice(message: 'Reconnected'));
    await tester.pump();
    await tester.tapAt(const Offset(20, 300));
    expect(taps, 1);
  });
}
