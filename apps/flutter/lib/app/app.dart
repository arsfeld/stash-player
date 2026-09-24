import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/system_appearance.dart';
import '../ui/theme/app_theme.dart';
import 'app_controller.dart';
import 'app_router.dart';
import 'providers.dart';
import 'toast_host.dart';

class StashPlayerApp extends ConsumerStatefulWidget {
  const StashPlayerApp({super.key});

  @override
  ConsumerState<StashPlayerApp> createState() => _StashPlayerAppState();
}

class _StashPlayerAppState extends ConsumerState<StashPlayerApp> {
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
    final appearance =
        ref.watch(systemAppearanceProvider).valueOrNull ??
        SystemAppearance.none;
    ThemeData themeFor(Brightness brightness) => buildAppTheme(
      brightness,
      accent: appearance.accent,
      fontFamily: appearance.fontFamily,
      bodyFontPt: appearance.fontSizePt,
    );

    return MaterialApp(
      title: 'Stash Player',
      themeMode: ThemeMode.system,
      theme: themeFor(Brightness.light),
      darkTheme: themeFor(Brightness.dark),
      builder: (context, child) => ToastHost(child: child!),
      home: const AppRouter(),
    );
  }
}
