import 'dart:math' as math;
import 'dart:ui';

/// WCAG 2.x relative luminance and contrast ratio, for asserting that
/// text is legible on the surface it is actually painted on.
///
/// This exists because no test in the suite asserted a colour, and the
/// redesign's worst defect was one: the metadata drawer painted
/// theme-derived text on a theme-independent near-black panel, so in
/// light mode it rendered `#1A1B1E` on `#131416`, a ratio of about
/// 1.02:1, and every test still passed because they only ever looked for
/// the text's content.

/// The sRGB-linearised value of one channel, per WCAG's own formula.
double _linearise(double channel) => channel <= 0.03928
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

/// Relative luminance of an opaque [color], 0 for black and 1 for white.
double relativeLuminance(Color color) =>
    0.2126 * _linearise(color.r) +
    0.7152 * _linearise(color.g) +
    0.0722 * _linearise(color.b);

/// Contrast ratio between [foreground] and [background], from 1:1
/// (identical) to 21:1 (black on white).
///
/// Both colours are composited before measuring, so a translucent one is
/// measured as it renders rather than as it is declared. [background] is
/// composited over black: for the player's panels that is the darkest
/// they can be, which is the pessimistic case for the dark text this
/// guards against.
double contrastRatio(Color foreground, Color background) {
  final opaqueBackground = Color.alphaBlend(
    background,
    const Color(0xFF000000),
  );
  final composited = Color.alphaBlend(foreground, opaqueBackground);
  final a = relativeLuminance(composited);
  final b = relativeLuminance(opaqueBackground);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}
