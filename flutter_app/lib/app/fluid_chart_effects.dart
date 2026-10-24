import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// One mark's paint-only liquid and perimeter halo. The mark's measured rectangle
/// is never resized by this painter. Its owner runs the clock only while hovered.
class ChartHoverPainter extends CustomPainter {
  ChartHoverPainter({
    required this.elapsed,
    required this.color,
    required this.viewport,
    this.liquid = true,
  }) : super(repaint: elapsed);

  final ValueListenable<Duration?> elapsed;
  final Color color;

  /// Plot coordinates relative to this mark, including reserved decoration space.
  final Rect viewport;
  final bool liquid;

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
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .24),
            color.withValues(alpha: 0),
          ],
        ).createShader(mark);
      for (var i = -1; i < 3; i++) {
        final y = (phase * 2 + i) * size.height / 2;
        final band = Path()
          ..moveTo(-size.width * .2, y)
          ..cubicTo(
            size.width * .15,
            y - size.height * .30,
            size.width * .65,
            y + size.height * .18,
            size.width * 1.2,
            y - size.height * .12,
          )
          ..lineTo(size.width * 1.2, y + size.height * .08)
          ..cubicTo(
            size.width * .65,
            y + size.height * .38,
            size.width * .15,
            y - size.height * .10,
            -size.width * .2,
            y + size.height * .20,
          )
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
    for (var i = 0; i < 24; i++) {
      final age = (phase + i * .61803398875) % 1;
      var distance = (i / 24 + phase * .13) % 1 * perimeter;
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
      final center = origin + normal * (2.8 + 6.2 * age);
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
      liquid != oldDelegate.liquid;
}
