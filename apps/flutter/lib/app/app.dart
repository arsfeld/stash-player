import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class StashPlayerApp extends ConsumerWidget {
  const StashPlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Stash Player Flutter',
    themeMode: ThemeMode.system,
    theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.deepPurple,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const Scaffold(body: Center(child: Text('Stash Player Flutter'))),
  );
}
