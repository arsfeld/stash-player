import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/ui/theme/platform_dialect.dart';

void main() {
  test('only macOS speaks the macOS dialect', () {
    expect(
      PlatformDialect.forPlatform(TargetPlatform.macOS),
      PlatformDialect.macos,
    );
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.android,
    ]) {
      expect(PlatformDialect.forPlatform(platform), PlatformDialect.adwaita);
    }
  });

  testWidgets('of(context) follows the ambient theme platform', (tester) async {
    late PlatformDialect seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) {
            seen = PlatformDialect.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, PlatformDialect.macos);
  });
}
