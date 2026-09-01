import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/theme/app_theme.dart';
import 'app_controller.dart';
import 'app_router.dart';
import 'notices.dart';

class StashPlayerApp extends ConsumerStatefulWidget {
  const StashPlayerApp({super.key});

  @override
  ConsumerState<StashPlayerApp> createState() => _StashPlayerAppState();
}

class _StashPlayerAppState extends ConsumerState<StashPlayerApp> {
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    // Safe to call directly: `bootstrap()` never touches provider state
    // before its first `await`, so this can't trip Riverpod's "don't
    // modify a provider while the tree is building" guard even though
    // it's invoked synchronously from `initState`.
    ref.read(appControllerProvider.notifier).bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    // Non-modal notices — successful reconnection, activity warnings, and
    // unexpected-but-safe failures — surface here, above whatever
    // destination is currently showing. Local form/library errors never
    // reach this listener; they stay in their own screen's state.
    ref.listen<AppNotice?>(globalNoticeProvider, (previous, next) {
      if (next == null || next.id == previous?.id) return;
      // Resolve the theme from the ScaffoldMessenger's own context, not
      // this State's `context` — that sits *above* the MaterialApp this
      // same build() returns, so Theme.of(context) here would silently
      // fall back to Flutter's default ThemeData instead of this app's
      // brightness-aware, seeded one (see the same bug already caught and
      // fixed in the smoke tests).
      final messengerContext = _scaffoldMessengerKey.currentContext;
      final color = messengerContext == null
          ? null
          : _colorFor(next.severity, Theme.of(messengerContext));
      _scaffoldMessengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(next.message), backgroundColor: color),
        );
    });

    return MaterialApp(
      title: 'Stash Player Flutter',
      scaffoldMessengerKey: _scaffoldMessengerKey,
      themeMode: ThemeMode.system,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const AppRouter(),
    );
  }

  Color? _colorFor(AppNoticeSeverity severity, ThemeData theme) =>
      switch (severity) {
        AppNoticeSeverity.error => theme.colorScheme.error,
        AppNoticeSeverity.success => theme.colorScheme.primary,
        AppNoticeSeverity.warning || AppNoticeSeverity.info => null,
      };
}
