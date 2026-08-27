import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/app/app.dart';

void main() {
  testWidgets('uses the experimental display name and Material 3', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: StashPlayerApp()));
    expect(find.text('Stash Player Flutter'), findsOneWidget);
    final context = tester.element(find.byType(MaterialApp));
    expect(Theme.of(context).useMaterial3, isTrue);
  });
}
