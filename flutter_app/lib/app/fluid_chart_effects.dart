import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Quantitative direction of the measured mark, independent of its aspect ratio.
enum ChartFlowAxis { vertical, horizontal }

/// One mark's paint-only liquid and perimeter halo. The mark's measured rectangle
/// is never resized by this painter. Its owner runs the clock only while hovered.
class ChartHoverPainter extends CustomPainter {
  ChartHoverPainter({
    required this.elapsed,
    required this.color,
    required this.viewport,
    this.liquid = true,
    this.flowAxis = ChartFlowAxis.vertical,
  }) : super(repaint: elapsed);

  final ValueListenable<Duration?> elapsed;
  final Color color;

  /// Plot coordinates relative to this mark, including reserved decoration space.
  final Rect viewport;
  final bool liquid;
  final ChartFlowAxis flowAxis;

  @override
  void paint(Canvas canvas, Size size) {
    final time = elapsed.value;
    if (time == null || size.isEmpty) return;
    final phase = (time.inMicroseconds / 1250000) % 1;
    final mark = Offset.zero & size;
    if (liquid) {
      canvas.save();
      canvas.clipRect(mark);
      // Additive light from the exact series color makes a moving same-hue band
      // visible over the solid fill; no level, endpoint or stack join is moved.
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(
          begin: flowAxis == ChartFlowAxis.vertical
              ? Alignment.centerLeft
              : Alignment.topCenter,
          end: flowAxis == ChartFlowAxis.vertical
              ? Alignment.centerRight
              : Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .24),
            color.withValues(alpha: 0),
          ],
        ).createShader(mark);
      // Repeated bands extend past both ends: wrapping removes/adds a band only
      // outside the measured clip. Normalized cross/length coordinates transpose
      // for horizontal marks, including marks narrower than they are tall.
      Offset point(double cross, double length) =>
          flowAxis == ChartFlowAxis.vertical
          ? Offset(cross * size.width, length * size.height)
          : Offset(length * size.width, cross * size.height);
      for (var i = -3; i <= 4; i++) {
        final length =
            i / 2 + (flowAxis == ChartFlowAxis.vertical ? -phase : phase);
        final start = point(-.2, length);
        final a = point(.15, length - .30);
        final b = point(.65, length + .18);
        final c = point(1.2, length - .12);
        final d = point(1.2, length + .08);
        final e = point(.65, length + .38);
        final f = point(.15, length - .10);
        final g = point(-.2, length + .20);
        final band = Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(a.dx, a.dy, b.dx, b.dy, c.dx, c.dy)
          ..lineTo(d.dx, d.dy)
          ..cubicTo(e.dx, e.dy, f.dx, f.dy, g.dx, g.dy)
          ..close();
        canvas.drawPath(band, paint);
      }
      canvas.restore();
    }

    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(viewport),
        Path()..addRect(mark),
      ),
    );
    final perimeter = 2 * (size.width + size.height);
    for (var i = 0; i < 16; i++) {
      // Integer stagger preserves a separate exact 1700ms particle period.
      // Emitters and seeded drift never depend on the liquid's wrapped phase.
      final age = ((time.inMicroseconds + i * 1050657) % 1700000) / 1700000;
      var distance = (i + .5) / 16 * perimeter;
      late Offset origin, normal;
      if (distance < size.width) {
        origin = Offset(distance, 0);
        normal = const Offset(0, -1);
      } else if ((distance -= size.width) < size.height) {
        origin = Offset(size.width, distance);
        normal = const Offset(1, 0);
      } else if ((distance -= size.height) < size.width) {
        origin = Offset(size.width - distance, size.height);
        normal = const Offset(0, 1);
      } else {
        distance -= size.width;
        origin = Offset(0, size.height - distance);
        normal = const Offset(-1, 0);
      }
      final tangent = Offset(-normal.dy, normal.dx);
      final drift = ((i * 37 % 17) / 8 - 1) * 2.5;
      final spread = 6 + (i * 13 % 11) / 10;
      // Maximum normal reach 9px plus the 3px glow fits existing 12px gutters.
      final center =
          origin + normal * (2 + spread * age) + tangent * drift * age;
      final alpha = .8 * math.sin(math.pi * age);
      final glowBounds = Rect.fromCircle(center: center, radius: 3);
      canvas.drawCircle(
        center,
        3,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha * .38),
              color.withValues(alpha: 0),
            ],
          ).createShader(glowBounds),
      );
      canvas.drawCircle(
        center,
        .8 + .45 * (1 - age),
        Paint()..color = color.withValues(alpha: alpha),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ChartHoverPainter oldDelegate) =>
      elapsed != oldDelegate.elapsed ||
      color != oldDelegate.color ||
      viewport != oldDelegate.viewport ||
      liquid != oldDelegate.liquid ||
      flowAxis != oldDelegate.flowAxis;
}
