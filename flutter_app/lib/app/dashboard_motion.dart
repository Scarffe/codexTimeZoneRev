import 'package:flutter/gestures.dart';
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

/// Event-driven light behind content and one finite, non-interactive burst.
class DashboardMotionBackdrop extends StatefulWidget {
  const DashboardMotionBackdrop({super.key, required this.child});
  final Widget child;
  @override
  State<DashboardMotionBackdrop> createState() =>
      _DashboardMotionBackdropState();
}

class _DashboardMotionBackdropState extends State<DashboardMotionBackdrop>
    with SingleTickerProviderStateMixin {
  late final _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  )..addListener(_tick);
  bool _enabled = false;
  Offset? _pointer, _origin;

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = DashboardMotionScope.enabledOf(context);
    if (!_enabled) {
      _pointer = _origin = null;
      _burst.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = DashboardPalette.of(context).accent;
    return MouseRegion(
      opaque: false,
      onHover: (event) {
        if (_enabled) setState(() => _pointer = event.localPosition);
      },
      onExit: (_) => setState(() => _pointer = null),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (!_enabled || event.buttons != kPrimaryMouseButton) return;
          _origin = event.localPosition;
          _burst.forward(from: 0);
        },
        child: ClipRect(
          child: CustomPaint(
            painter: _Spotlight(_enabled ? _pointer : null, color),
            foregroundPainter: _OrbitRings(
              _enabled && _burst.isAnimating ? _origin : null,
              _burst.value,
              color,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }
}

class _Spotlight extends CustomPainter {
  const _Spotlight(this.center, this.color);
  final Offset? center;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (center == null) return;
    final bounds = Rect.fromCircle(center: center!, radius: 140);
    canvas.drawCircle(
      center!,
      140,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: .065), color.withValues(alpha: 0)],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_Spotlight oldDelegate) =>
      center != oldDelegate.center || color != oldDelegate.color;
}

class _OrbitRings extends CustomPainter {
  const _OrbitRings(this.center, this.progress, this.color);
  final Offset? center;
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (center == null) return;
    final eased = Curves.easeOutCubic.transform(progress);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: .075 * (1 - progress));
    canvas.drawCircle(center!, 8 + 140 * eased, paint);
    canvas.drawCircle(center!, 4 + 102 * eased, paint);
  }

  @override
  bool shouldRepaint(_OrbitRings oldDelegate) =>
      center != oldDelegate.center ||
      progress != oldDelegate.progress ||
      color != oldDelegate.color;
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
