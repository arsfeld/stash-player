import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// What the desktop reports about its own look: the accent colour, and
/// (on GNOME) the UI font. Every field is null while unknown, which the
/// theme treats as "use the built-in default".
@immutable
class SystemAppearance {
  const SystemAppearance({this.accent, this.fontFamily, this.fontSizePt});

  static const none = SystemAppearance();

  final Color? accent;
  final String? fontFamily;
  final double? fontSizePt;

  /// Decodes one event from the `stash_player/appearance` channel: a map
  /// with an optional ARGB `accent` int and an optional Pango `fontName`
  /// such as `"Adwaita Sans 11"`. Anything malformed decodes to unknown
  /// rather than throwing, since a bad event must never take the theme
  /// down with it.
  static SystemAppearance fromEvent(Object? event) {
    if (event is! Map) return none;
    final accent = event['accent'];
    final fontName = event['fontName'];
    final font = parseFontName(fontName is String ? fontName : null);
    return SystemAppearance(
      accent: accent is int ? Color(accent) : null,
      fontFamily: font?.family,
      fontSizePt: font?.sizePt,
    );
  }

  /// Splits a Pango font description into its family and point size.
  /// Style words (`Bold`, `Italic`) are rare in a UI font setting and are
  /// left in the family, where font matching ignores what it can't use.
  static ({String family, double? sizePt})? parseFontName(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final match = RegExp(r'^(.*?)\s+(\d+(?:\.\d+)?)$').firstMatch(trimmed);
    if (match == null) return (family: trimmed, sizePt: null);
    return (family: match.group(1)!, sizePt: double.parse(match.group(2)!));
  }

  @override
  bool operator ==(Object other) =>
      other is SystemAppearance &&
      other.accent == accent &&
      other.fontFamily == fontFamily &&
      other.fontSizePt == fontSizePt;

  @override
  int get hashCode => Object.hash(accent, fontFamily, fontSizePt);

  @override
  String toString() =>
      'SystemAppearance(accent: $accent, font: $fontFamily $fontSizePt)';
}
