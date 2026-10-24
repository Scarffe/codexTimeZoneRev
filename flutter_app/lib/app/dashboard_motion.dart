import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'dashboard_style.dart';

/// One policy for mounted pages and Navigator overlays. Local TickerMode is
/// checked at the consumer, so an IndexedStack page cancels rather than pauses.
class DashboardMotionScope extends StatelessWidget {
  const DashboardMotionScope({
    super.key,
    required this.reducedMotion,
    required this.child,
  });
  final bool reducedMotion;
  final Widget child;

  static bool enabledOf(BuildContext context) =>
      (context.dependOnInheritedWidgetOfExactType<_MotionPolicy>()?.enabled ??
          true) &&
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;

  @override
  Widget build(BuildContext context) =>
      _MotionPolicy(enabled: !reducedMotion, child: child);
}

class _MotionPolicy extends InheritedWidget {
  const _MotionPolicy({required this.enabled, required super.child});
  final bool enabled;
  @override
  bool updateShouldNotify(_MotionPolicy oldWidget) =>
      enabled != oldWidget.enabled;
}

/// One client-wide, input-transparent decoration, including Navigator overlays.
/// Only active click waves tick; a stationary pointer never animates the light.
class DashboardMotionBackdrop extends StatefulWidget {
  const DashboardMotionBackdrop({super.key, required this.child});
  final Widget child;
  @override
  State<DashboardMotionBackdrop> createState() =>
      _DashboardMotionBackdropState();
}

class _DashboardMotionBackdropState extends State<DashboardMotionBackdrop>
    with SingleTickerProviderStateMixin {
  final _field = _ClientWaveField();
  late final Ticker _ticker = createTicker(_tick);
  bool _enabled = false;

  void _tick(Duration elapsed) {
    _field.advance(elapsed);
    if (_field.waves.isEmpty) _ticker.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = DashboardMotionScope.enabledOf(context);
    if (!_enabled) {
      _ticker.stop();
      _field.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = DashboardPalette.of(context).accent;
    return MouseRegion(
      opaque: false,
      onHover: (event) {
        if (_enabled) _field.pointAt(event.localPosition);
      },
      onExit: (_) => _field.pointAt(null),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (!_enabled || event.buttons != kPrimaryMouseButton) return;
          if (!_ticker.isActive) _field.elapsed = Duration.zero;
          _field.contact(event.localPosition);
          if (!_ticker.isActive) _ticker.start();
        },
        child: ClipRect(
          child: RepaintBoundary(
            child: CustomPaint(
              foregroundPainter: _ClientWaves(_field, color),
              child: RepaintBoundary(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _field.dispose();
    super.dispose();
  }
}

class _ClickWave {
  const _ClickWave(this.origin, this.started);
  // Retain the event's client logical-pixel origin if the client is resized.
  final Offset origin;
  final Duration started;
}

class _ClientWaveField extends ChangeNotifier {
  static const lifetime = Duration(seconds: 4);
  final waves = <_ClickWave>[];
  Duration elapsed = Duration.zero;
  Offset? pointer;

  void pointAt(Offset? point) {
    if (pointer == point) return;
    pointer = point;
    notifyListeners();
  }

  void contact(Offset origin) {
    if (waves.length == 4) waves.removeAt(0);
    waves.add(_ClickWave(origin, elapsed));
    notifyListeners();
  }

  void advance(Duration value) {
    elapsed = value;
    waves.removeWhere((wave) => elapsed - wave.started >= lifetime);
    notifyListeners();
  }

  void clear() {
    waves.clear();
    pointer = null;
    elapsed = Duration.zero;
    notifyListeners();
  }
}

class _ClientWaves extends CustomPainter {
  _ClientWaves(this.field, this.color) : super(repaint: field);
  final _ClientWaveField field;
  final Color color;

  // Mirror lattice index n counts wall contacts along that axis. The diamond
  // |nx|+|ny|<=4 contains exactly 41 images, including the original source.
  static double _mirror(double origin, double extent, int n) =>
      n.isEven ? n * extent + origin : (n + 1) * extent - origin;

  static bool _crossesClient(Offset center, double radius, Size size) {
    if (radius <= 0) return false;
    final nearX = math.max(0.0, math.max(-center.dx, center.dx - size.width));
    final nearY = math.max(0.0, math.max(-center.dy, center.dy - size.height));
    final farX = math.max(center.dx.abs(), (center.dx - size.width).abs());
    final farY = math.max(center.dy.abs(), (center.dy - size.height).abs());
    final squared = radius * radius;
    return squared >= nearX * nearX + nearY * nearY &&
        squared <= farX * farX + farY * farY;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || (field.pointer == null && field.waves.isEmpty)) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final pointer = field.pointer;
    if (pointer != null) {
      // Foreground placement keeps the very quiet light coherent across cards.
      final bounds = Rect.fromCircle(center: pointer, radius: 220);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: .035), color.withValues(alpha: 0)],
          ).createShader(bounds),
      );
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    for (final wave in field.waves) {
      final t = (field.elapsed - wave.started).inMicroseconds / 1000000;
      final tail = ((4 - t) / .5).clamp(0.0, 1.0);
      final fade = tail * tail * (3 - 2 * tail);
      final amplitude = .24 * math.exp(-.75 * t) * fade;
      final radius = 480 * t;
      for (var nx = -4; nx <= 4; nx++) {
        for (var ny = -4; ny <= 4; ny++) {
          final order = nx.abs() + ny.abs();
          if (order > 4) continue;
          final source = Offset(
            _mirror(wave.origin.dx, size.width, nx),
            _mirror(wave.origin.dy, size.height, ny),
          );
          final alpha = amplitude * math.pow(.58, order);
          // Two crests at most: 4 bursts * 41 images * 2 = 328 attempts.
          // No saveLayer, accumulated particles, or radius-dependent loops.
          for (var crest = 0; crest < 2; crest++) {
            final r = radius - crest * 16;
            if (!_crossesClient(source, r, size)) continue;
            paint
              ..color = color.withValues(alpha: alpha * (crest == 0 ? 1 : .4))
              ..strokeWidth = crest == 0 ? 1.8 : 1.1
              ..maskFilter = crest == 0
                  ? const MaskFilter.blur(BlurStyle.normal, .55)
                  : null;
            canvas.drawCircle(source, r, paint);
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClientWaves oldDelegate) =>
      field != oldDelegate.field || color != oldDelegate.color;
}

/// Adds paint-only movement without owning focus, gestures, keys or callbacks.
/// The original child keeps its static Forui hover and keyboard focus treatment.
class DashboardMotionFeedback extends StatefulWidget {
  const DashboardMotionFeedback({
    super.key,
    required this.child,
    this.enabled = true,
  });
  final Widget child;
  final bool enabled;
  @override
  State<DashboardMotionFeedback> createState() =>
      _DashboardMotionFeedbackState();
}

class _DashboardMotionFeedbackState extends State<DashboardMotionFeedback>
    with SingleTickerProviderStateMixin {
  late final _response = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  )..addListener(_tick);
  bool _motion = false, _hover = false, _pressed = false;
  double _fromScale = 1, _toScale = 1, _fromLift = 0, _toLift = 0;

  double get _phase => Curves.easeOutBack.transform(_response.value);
  double get _scale => _fromScale + (_toScale - _fromScale) * _phase;
  double get _lift => _fromLift + (_toLift - _fromLift) * _phase;

  void _tick() {
    if (mounted) setState(() {});
  }

  void _clear() {
    _hover = _pressed = false;
    _fromScale = _toScale = 1;
    _fromLift = _toLift = 0;
    _response.reset();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = DashboardMotionScope.enabledOf(context);
    if (!_motion) _clear();
  }

  @override
  void didUpdateWidget(DashboardMotionFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _clear();
  }

  void _respond() {
    if (!widget.enabled || !_motion) return;
    _fromScale = _scale;
    _fromLift = _lift;
    _toScale = _pressed ? .985 : (_hover ? 1.025 : 1);
    _toLift = _hover && !_pressed ? -.8 : 0;
    _response.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final active = _motion && widget.enabled;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _hover = widget.enabled && _motion;
        _respond();
      },
      onExit: (_) {
        _hover = _pressed = false;
        _respond();
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (event.buttons != kPrimaryMouseButton ||
              !widget.enabled ||
              !_motion) {
            return;
          }
          setState(() => _pressed = true);
          _respond();
        },
        onPointerUp: (_) {
          setState(() => _pressed = false);
          _respond();
        },
        onPointerCancel: (_) {
          setState(() => _pressed = false);
          _respond();
        },
        child: Transform.translate(
          offset: Offset(0, active ? _lift : 0),
          transformHitTests: false,
          child: Transform.scale(
            scale: active ? _scale.clamp(.98, 1.04) : 1,
            transformHitTests: false,
            child: widget.child,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _response.dispose();
    super.dispose();
  }
}
