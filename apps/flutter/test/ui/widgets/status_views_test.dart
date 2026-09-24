import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/app_theme.dart';
import 'package:stash_player_flutter/ui/widgets/status_views.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('the loading view is a labelled spinner', (tester) async {
    await _pump(tester, const AppLoadingView(semanticLabel: 'Loading scenes'));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Loading scenes'), findsOneWidget);
  });

  testWidgets('the empty view offers its action', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      AppEmptyView(
        message: 'No scenes match these filters',
        actionLabel: 'Clear filters',
        onAction: () => taps++,
      ),
    );

    expect(find.text('No scenes match these filters'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('the error view retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      AppErrorView(message: 'Server unreachable', onRetry: () => retries++),
    );

    expect(find.text('Server unreachable'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('the inline banner retries without replacing the page', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      Column(
        children: [
          AppInlineBanner(
            message: 'Could not load more scenes',
            actionLabel: 'Retry',
            onAction: () => retries++,
          ),
          const Expanded(child: SizedBox()),
        ],
      ),
    );

    expect(find.text('Could not load more scenes'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retries, 1);
  });
}
