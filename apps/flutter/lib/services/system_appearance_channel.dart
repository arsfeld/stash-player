import 'package:flutter/services.dart';

import '../domain/system_appearance.dart';

/// The desktop's accent colour and UI font, as the native runner reports
/// them: once on listen, then on every change. See `appearance_channel.cc`
/// (Linux, from the XDG settings portal) and `AppearanceStreamHandler` in
/// `MainFlutterWindow.swift` (macOS, from `NSColor.controlAccentColor`).
Stream<SystemAppearance> watchSystemAppearance({
  EventChannel channel = const EventChannel('stash_player/appearance'),
}) => channel.receiveBroadcastStream().map(SystemAppearance.fromEvent);
