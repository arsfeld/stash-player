import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/platform_dialect.dart';

/// An indeterminate progress indicator in the ambient dialect: libadwaita's
/// rotating arc, or AppKit's twelve fading spokes.
///
/// Coloured like an icon: [color] if given, otherwise the ambient
/// [IconTheme] (so inside a button it takes the button's foreground),
/// otherwise the theme's dimmed text colour.
class AppSpinner extends StatefulWidget {
  const AppSpinner({this.size = 16, this.color, super.key});

  @visibleForTesting
  static const Key arcKey = Key('app-spinner-arc');
  @visibleForTesting
  static const Key spokesKey = Key('app-spinner-spokes');

  final double size;
  final Color? color;

  @override
  State<AppSpinner> createState() => _AppSpinnerState();
}

class _AppSpinnerState extends State<AppSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    final adwaita = PlatformDialect.of(context) == PlatformDialect.adwaita;
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        key: adwaita ? AppSpinner.arcKey : AppSpinner.spokesKey,
        painter: adwaita
            ? _ArcPainter(_turn, color)
            : _SpokesPainter(_turn, color),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.turn, this.color) : super(repaint: turn);

  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide / 8;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      paint..color = color.withValues(alpha: 0.15),
    );
    canvas.drawArc(
      rect,
      turn.value * 2 * math.pi,
      math.pi * 0.6,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

class _SpokesPainter extends CustomPainter {
  _SpokesPainter(this.turn, this.color) : super(repaint: turn);

  static const _spokes = 12;

  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..strokeWidth = size.shortestSide / 11
      ..strokeCap = StrokeCap.round;
    final lead = (turn.value * _spokes).floor();
    canvas.translate(size.width / 2, size.height / 2);
    for (var i = 0; i < _spokes; i++) {
      // The leading spoke is opaque and each one behind it fades, which
      // is what reads as rotation.
      final age = (lead - i) % _spokes;
      paint.color = color.withValues(alpha: 1 - age / _spokes * 0.85);
      final angle = i * 2 * math.pi / _spokes - math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        direction * radius * 0.45,
        direction * radius * 0.9,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpokesPainter old) => old.color != color;
}
