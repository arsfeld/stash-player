import 'package:flutter/foundation.dart';

/// Writes one diagnostic line to the console, tagged with [channel].
///
/// `debugPrint` rather than `dart:developer`'s `log`, which is what this
/// codebase reaches for elsewhere. `log()` delivers only to the VM
/// service: its messages show up in DevTools and are completely absent
/// from a `flutter run` terminal. That was verified the hard way against
/// this app, by shipping the load diagnostics through `log()` and then
/// watching a real slow load produce a console with nothing in it.
///
/// Diagnostics exist to be read while something is going wrong, which
/// for this app means a terminal, so they go where a terminal can see
/// them. The `[channel]` prefix keeps them greppable in exchange.
/// Elapsed time is stamped from the first diagnostic of the session
/// rather than from process start: the absolute value carries no meaning
/// on its own, and only the differences between lines are ever read.
final Stopwatch _since = Stopwatch()..start();

void logDiagnostic(String channel, String message) =>
    debugPrint('[$channel +${_since.elapsedMilliseconds}ms] $message');
