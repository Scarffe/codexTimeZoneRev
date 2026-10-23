import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_activity_timeline.dart';
import 'dashboard_style.dart';

/// A display sample. Null remains unknown; cancellation never becomes zero.
@immutable
class ChartBar {
  const ChartBar({
    required this.label,
    required this.value,
    this.secondaryValue,
    this.detail,
    this.cancelled = false,
  });
  final String label;
  final double? value, secondaryValue;
  final String? detail;
  final bool cancelled;
}

double? _known(double? value) =>
    value != null && value.isFinite && value >= 0 ? value : null;

String _number(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toString();

String _seconds(int? ms) =>
    ms == null ? '未知' : '${(ms / 1000).toStringAsFixed(3)} s';

TextStyle _labelStyle(BuildContext context) =>
    context.theme.typography.body.sm.copyWith(fontSize: 12);

/// Quantitative series identity is independent of the neutral application chrome.
class _ChartPalette {
  const _ChartPalette(this.blue, this.purple, this.teal, this.amber);
  factory _ChartPalette.of(BuildContext context) => _ChartPalette(
    DashboardPalette.of(context).accent,
    DashboardPalette.of(context).reasoning,
    DashboardPalette.of(context).tool,
    DashboardPalette.of(context).muted,
  );
  final Color blue, purple, teal, amber;
  Color category(String category) => switch (category) {
    'reasoning' => purple,
    'tool' => teal,
    'other' => amber,
    _ => blue,
  };
}

class _BarSeriesColors extends InheritedWidget {
  const _BarSeriesColors({
    required this.primary,
    required this.secondary,
    required super.child,
  });
  final Color primary, secondary;
  static ({Color primary, Color secondary}) of(BuildContext context) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_BarSeriesColors>();
    final palette = _ChartPalette.of(context);
    return (
      primary: inherited?.primary ?? palette.blue,
      secondary: inherited?.secondary ?? palette.purple,
    );
  }

  @override
  bool updateShouldNotify(_BarSeriesColors oldWidget) =>
      primary != oldWidget.primary || secondary != oldWidget.secondary;
}

class MonitorChoice extends StatelessWidget {
  const MonitorChoice({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String label, value;

  /// Forui maps the displayed label to the stored value.
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => FSelect<String>(
    label: Text(label),
    items: items,
    enabled: items.isNotEmpty,
    control: FSelectControl.lifted(
      value: items.containsValue(value) ? value : null,
      onChange: (next) {
        if (next != null) onChanged(next);
      },
    ),
  );
}

class MonitorChartFrame extends StatelessWidget {
  const MonitorChartFrame({
    super.key,
    required this.title,
    required this.icon,
    this.controls = const [],
    required this.child,
    this.footnotes = const [],
  });
  final String title;
  final IconData icon;
  final List<Widget> controls;
  final Widget child;
  final List<String> footnotes;

  @override
  Widget build(BuildContext context) => FCard(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: context.theme.colors.foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: context.theme.typography.body.md.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (controls.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final control in controls)
                    SizedBox(
                      width: math.min(142, constraints.maxWidth),
                      child: control,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            child,
            for (final note in footnotes)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  note,
                  style: _labelStyle(context)
                      .copyWith(color: context.theme.colors.mutedForeground),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Native, local inspection works with keyboard, touch and screen readers.
class _InspectValues extends StatefulWidget {
  const _InspectValues({required this.records});
  final List<String> records;

  @override
  State<_InspectValues> createState() => _InspectValuesState();
}

class _InspectValuesState extends State<_InspectValues> {
  RawDialogRoute<void>? _route;
  NavigatorState? _navigator;

  @override
  void didUpdateWidget(_InspectValues oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.records, widget.records)) _dismissInspection();
  }

  @override
  void dispose() {
    _dismissInspection();
    super.dispose();
  }

  void _dismissInspection() {
    final route = _route;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (route == null || navigator == null) return;
    // Replacement and disposal can happen during build. Remove only our exact
    // route after that frame, including when another overlay is above it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted &&
          route.isActive &&
          identical(route.navigator, navigator)) {
        navigator.removeRoute(route);
      }
    });
  }

  void _openInspection() {
    if (_route != null) return;
    final records = widget.records;
    final navigator = Navigator.of(context, rootNavigator: true);
    late final RawDialogRoute<void> route;
    route = RawDialogRoute<void>(
      barrierDismissible: true,
      barrierLabel: '关闭图表数值',
      barrierColor: const Color(0x80000000),
      pageBuilder: (context, _, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 620,
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: FCard(
              style: FCardStyleDelta.delta(
                decoration: DecorationDelta.shapeDelta(
                  color: context.theme.colors.card,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('图表数值', style: context.theme.typography.body.lg),
                    const SizedBox(height: 12),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final record in records)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(record),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FButton(
                      onPress: () {
                        if (identical(_route, route)) _dismissInspection();
                      },
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _route = route;
    _navigator = navigator;
    navigator.push<void>(route).whenComplete(() {
      if (identical(_route, route)) {
        _route = null;
        _navigator = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: FButton(
      mainAxisSize: MainAxisSize.min,
      variant: FButtonVariant.ghost,
      prefix: const Icon(FLucideIcons.table2, size: 16),
      onPress: _openInspection,
      child: const Text('查看数值'),
    ),
  );
}

class _Scale {
  _Scale(double actual, {double? requested, bool integers = false}) {
    if (requested != null &&
        requested.isFinite &&
        requested > 0 &&
        requested >= actual) {
      step = integers
          ? math.max(1, (requested / 4).ceilToDouble())
          : requested / 4;
      max = integers ? (requested / step).ceil() * step : requested;
    } else {
      final raw = math.max(actual, 1e-9) / 4;
      final magnitude = math
          .pow(10, (math.log(raw) / math.ln10).floor())
          .toDouble();
      final fraction = raw / magnitude;
      var calculatedStep =
          (fraction <= 1
              ? 1
              : fraction <= 2
              ? 2
              : fraction <= 5
              ? 5
              : 10) *
          magnitude;
      if (actual == 0) calculatedStep = 1;
      if (integers) calculatedStep = math.max(1, calculatedStep.ceilToDouble());
      step = calculatedStep;
      max = math.max(step, (actual / step).ceil() * step);
    }
  }
  late final double step, max;
  List<double> get ticks => [
    for (var i = 0; i <= (max / step).round(); i++) i * step,
  ];
  String label(double value) {
    if (value >= 1e9) return '${_trim(value / 1e9, 2)}G';
    if (value >= 1e6) return '${_trim(value / 1e6, 2)}M';
    if (value >= 1e3) return '${_trim(value / 1e3, 2)}k';
    if (value == 0) return '0';
    final decimals = step >= 1
        ? 3
        : ((-math.log(step) / math.ln10).ceil() + 2).clamp(0, 9);
    return _trim(value, decimals);
  }

  String _trim(double value, int decimals) {
    final text = value.toStringAsFixed(decimals);
    return text.contains('.')
        ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : text;
  }
}

/// Pointer inspection is attached to actual marks, never an estimated chart bin.
/// It adds no focus nodes; the chart's numeric inspector remains the touch and
/// keyboard path. Portal ownership keeps disposal independent of other routes.
class _HoverMark extends StatefulWidget {
  const _HoverMark({required this.record, required this.child});
  final String record;
  final Widget child;
  @override
  State<_HoverMark> createState() => _HoverMarkState();
}

class _HoverMarkState extends State<_HoverMark> {
  final _portal = OverlayPortalController();
  void _clear() {
    if (!_portal.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.hide();
    });
  }

  @override
  void didUpdateWidget(_HoverMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record != widget.record) _clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _clear();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) {
      final box = this.context.findRenderObject()! as RenderBox;
      final overlayBox =
          Overlay.of(this.context).context.findRenderObject()! as RenderBox;
      final position = box.localToGlobal(Offset.zero, ancestor: overlayBox);
      final screen = overlayBox.size;
      final width = math.min(330.0, math.max(80.0, screen.width - 24));
      return Positioned(
        left: position.dx.clamp(
          12.0,
          math.max(12.0, screen.width - width - 12),
        ),
        top: (position.dy + box.size.height + 6).clamp(
          12.0,
          math.max(12.0, screen.height - 150),
        ),
        width: width,
        child: IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('monitor-chart-hover'),
            decoration: BoxDecoration(
              color: DashboardPalette.of(context).panel,
              border: Border.all(color: DashboardPalette.of(context).border),
              borderRadius: BorderRadius.circular(7),
              boxShadow: const [
                BoxShadow(color: Color(0x22000000), blurRadius: 8),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                widget.record,
                style: _labelStyle(context)
                    .copyWith(color: DashboardPalette.of(context).foreground),
              ),
            ),
          ),
        ),
      );
    },
    child: MouseRegion(
      onEnter: (_) {
        if (TickerMode.valuesOf(context).enabled) _portal.show();
      },
      onExit: (_) => _portal.hide(),
      child: widget.child,
    ),
  );
}

class _Grid extends CustomPainter {
  const _Grid({
    required this.color,
    required this.divisions,
    this.horizontal = true,
  });
  final Color color;
  final int divisions;
  final bool horizontal;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i <= divisions; i++) {
      final fraction = i / divisions;
      if (horizontal) {
        final x = fraction * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      } else {
        final y = fraction * size.height;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Grid oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.divisions != divisions ||
      oldDelegate.horizontal != horizontal;
}

class _HorizontalTicks extends StatelessWidget {
  const _HorizontalTicks({required this.scale});
  final _Scale scale;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final labelWidth = math.min(64.0, constraints.maxWidth / 3);
      return SizedBox(
        height: 22 * MediaQuery.textScalerOf(context).scale(1),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < scale.ticks.length; i++)
              Positioned(
                left: i == 0
                    ? 0
                    : i == scale.ticks.length - 1
                    ? constraints.maxWidth - labelWidth
                    : constraints.maxWidth * scale.ticks[i] / scale.max -
                          labelWidth / 2,
                width: labelWidth,
                child: Text(
                  scale.label(scale.ticks[i]),
                  key: ValueKey('monitor-axis-tick-$i'),
                  textAlign: i == 0
                      ? TextAlign.left
                      : i == scale.ticks.length - 1
                      ? TextAlign.right
                      : TextAlign.center,
                  style: _labelStyle(context),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class MonitorBarChart extends StatelessWidget {
  const MonitorBarChart({
    super.key,
    required this.bars,
    required this.unit,
    this.horizontal = false,
    this.integers = false,
    this.stacked = false,
    this.xLabel = '',
    this.height = 214,
    this.maxValue,
    this.primaryLabel = '数值',
    this.secondaryLabel = '补充数值',
    this.line = false,
    this.compactMeters = false,
  });
  final List<ChartBar> bars;
  final String unit, xLabel, primaryLabel, secondaryLabel;
  final bool horizontal, integers, stacked;
  final double height;

  /// View-only presentations. Existing callers retain their original chart.
  final bool line, compactMeters;

  /// Optional requested domain (e.g. 100%). Valid actual data is never clipped.
  final double? maxValue;

  String _value(double? value) =>
      _known(value) == null ? '未知' : '${_number(value!)} $unit';
  String _visibleValue(double? value) {
    final known = _known(value);
    if (known == null) return '未知';
    if (known == known.roundToDouble()) return _value(known);
    if (known < .01) return '<0.01 $unit';
    final number = known
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '$number $unit';
  }

  String _record(ChartBar bar) =>
      '${bar.label}${stacked ? ' · $primaryLabel' : ''}：${bar.cancelled ? '取消' : _value(bar.value)}'
      '${stacked ? ' · $secondaryLabel：${_value(bar.secondaryValue)}' : ''}'
      '${bar.detail == null ? '' : '\n${bar.detail}'}';

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) return const Text('暂无可绘制数据');
    final actual = bars.fold<double>(
      0,
      (max, bar) => math.max(
        max,
        bar.cancelled
            ? 0
            : (_known(bar.value) ?? 0) +
                  (stacked ? _known(bar.secondaryValue) ?? 0 : 0),
      ),
    );
    final scale = _Scale(actual, requested: maxValue, integers: integers);
    final knownCount = bars
        .where((b) => !b.cancelled && _known(b.value) != null)
        .length;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label:
          '${horizontal ? '横条图' : '柱形图'}，${bars.length} 项，$knownCount 项有已知值，单位 $unit。'
          '${bars.take(4).map(_record).join('；')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(unit, style: _labelStyle(context)),
              if (stacked) ...[
                _Legend(
                  label: primaryLabel,
                  color: _BarSeriesColors.of(context).primary,
                ),
                _Legend(
                  label: secondaryLabel,
                  color: _BarSeriesColors.of(context).secondary,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (compactMeters && horizontal)
            _meters(context, scale)
          else if (horizontal) ...[
            for (var i = 0; i < bars.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Semantics(
                  label: _record(bars[i]),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        bars[i].label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _labelStyle(context),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 24,
                        child: LayoutBuilder(
                          builder: (context, constraints) => CustomPaint(
                            painter: _Grid(
                              color: DashboardPalette.of(context).grid,
                              divisions: scale.ticks.length - 1,
                            ),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: _horizontalMarks(
                                context,
                                i,
                                constraints.maxWidth,
                                scale.max,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (stacked &&
                          !bars[i].cancelled &&
                          _known(bars[i].secondaryValue) == null)
                        Text('$secondaryLabel —', style: _labelStyle(context)),
                      if (bars.length <= 4)
                        Text(
                          bars[i].cancelled
                              ? '取消'
                              : '${_visibleValue(bars[i].value)}${stacked ? ' · ${_visibleValue(bars[i].secondaryValue)}' : ''}',
                          semanticsLabel: bars[i].cancelled
                              ? '取消'
                              : '${_value(bars[i].value)}${stacked ? ' · ${_value(bars[i].secondaryValue)}' : ''}',
                          style: _labelStyle(context),
                        ),
                    ],
                  ),
                ),
              ),
            _HorizontalTicks(scale: scale),
          ] else
            _columns(context, scale),
          if (xLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                xLabel,
                style: _labelStyle(context),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 8),
          _InspectValues(records: bars.map(_record).toList()),
        ],
      ),
    );
  }

  List<Widget> _horizontalMarks(
    BuildContext context,
    int index,
    double width,
    double max,
  ) {
    final bar = bars[index];
    if (bar.cancelled) {
      return [
        Center(
          child: _HoverMark(
            record: _record(bar),
            child: Text('×', key: ValueKey('monitor-bar-$index-cancelled')),
          ),
        ),
      ];
    }
    final primary = _known(bar.value), secondary = _known(bar.secondaryValue);
    return [
      if (primary != null)
        Positioned(
          left: 0,
          top: 2,
          height: 20,
          width: width * primary / max,
          child: _HoverMark(
            record: _record(bar),
            child: ColoredBox(
              key: ValueKey('monitor-bar-$index-primary'),
              color: _BarSeriesColors.of(context).primary,
            ),
          ),
        )
      else
        Align(
          alignment: Alignment.centerLeft,
          child: _HoverMark(
            record: _record(bar),
            child: Text('—', key: ValueKey('monitor-bar-$index-unknown')),
          ),
        ),
      if (stacked && secondary != null)
        Positioned(
          left: width * (primary ?? 0) / max,
          top: 2,
          height: 20,
          width: width * secondary / max,
          child: _HoverMark(
            record: _record(bar),
            child: ColoredBox(
              key: ValueKey('monitor-bar-$index-secondary'),
              color: _BarSeriesColors.of(context).secondary,
            ),
          ),
        ),
    ];
  }

  Widget _meters(BuildContext context, _Scale scale) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth > 440
          ? (constraints.maxWidth - 20) / 2
          : constraints.maxWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              for (var i = 0; i < bars.length; i++)
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 8,
                        children: [
                          Text(bars[i].label, style: _labelStyle(context)),
                          Text(
                            bars[i].cancelled
                                ? '取消'
                                : _visibleValue(bars[i].value),
                            style: context.theme.typography.body.md.copyWith(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        height: 24,
                        child: LayoutBuilder(
                          builder: (context, inner) => ColoredBox(
                            color: DashboardPalette.of(context).soft,
                            child: Stack(
                              children: _horizontalMarks(
                                context,
                                i,
                                inner.maxWidth,
                                scale.max,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _HorizontalTicks(scale: scale),
                      if (bars[i].detail != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            bars[i].detail!,
                            style: _labelStyle(context),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );

  Widget _columns(BuildContext context, _Scale scale) {
    final plotHeight = math.max(100.0, height - 70);
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelWidth = math.min(52.0, constraints.maxWidth * .2);
        final plotWidth = math.max(0.0, constraints.maxWidth - labelWidth);
        final slot = plotWidth / bars.length;
        final markWidth = math.max(.5, math.min(38.0, slot * .65));
        return Column(
          children: [
            SizedBox(
              height: plotHeight + 12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    height: plotHeight + 12,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var i = 0; i < scale.ticks.length; i++)
                          Positioned(
                            top:
                                plotHeight * (1 - scale.ticks[i] / scale.max) -
                                6,
                            left: 0,
                            right: 6,
                            child: Text(
                              scale.label(scale.ticks[i]),
                              key: ValueKey('monitor-axis-tick-$i'),
                              style: _labelStyle(context),
                              textAlign: TextAlign.right,
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: plotWidth,
                    height: plotHeight,
                    child: CustomPaint(
                      painter: _Grid(
                        color: DashboardPalette.of(context).grid,
                        divisions: scale.ticks.length - 1,
                        horizontal: false,
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (line)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  key: const ValueKey('monitor-duration-line'),
                                  painter: _DurationLine(
                                    bars,
                                    scale.max,
                                    _BarSeriesColors.of(context).primary,
                                  ),
                                ),
                              ),
                            ),
                          for (var i = 0; i < bars.length; i++) ...[
                            if (bars[i].cancelled ||
                                _known(bars[i].value) == null)
                              Positioned(
                                left: slot * i,
                                width: slot,
                                bottom: 4,
                                child: Semantics(
                                  label: _record(bars[i]),
                                  child: Center(
                                    child: _HoverMark(
                                      record: _record(bars[i]),
                                      child: Text(
                                        bars[i].cancelled ? '×' : '—',
                                        key: ValueKey(
                                          'monitor-bar-$i-${bars[i].cancelled ? 'cancelled' : 'unknown'}',
                                        ),
                                        style: _labelStyle(context),
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              Positioned(
                                left:
                                    slot * i +
                                    (slot -
                                            (line
                                                ? math.min(8.0, slot)
                                                : markWidth)) /
                                        2,
                                width: line ? math.min(8.0, slot) : markWidth,
                                bottom: line
                                    ? plotHeight *
                                              _known(bars[i].value)! /
                                              scale.max -
                                          4
                                    : 0,
                                height: line
                                    ? 8
                                    : plotHeight *
                                          _known(bars[i].value)! /
                                          scale.max,
                                child: Semantics(
                                  label: _record(bars[i]),
                                  child: _HoverMark(
                                    record: _record(bars[i]),
                                    child: ColoredBox(
                                      key: ValueKey('monitor-bar-$i-primary'),
                                      color: _BarSeriesColors.of(context)
                                          .primary,
                                    ),
                                  ),
                                ),
                              ),
                            if (stacked &&
                                !bars[i].cancelled &&
                                _known(bars[i].secondaryValue) != null)
                              Positioned(
                                left: slot * i + (slot - markWidth) / 2,
                                width: markWidth,
                                bottom:
                                    plotHeight *
                                    (_known(bars[i].value) ?? 0) /
                                    scale.max,
                                height:
                                    plotHeight *
                                    _known(bars[i].secondaryValue)! /
                                    scale.max,
                                child: _HoverMark(
                                  record: _record(bars[i]),
                                  child: ColoredBox(
                                    key: ValueKey('monitor-bar-$i-secondary'),
                                    color: _BarSeriesColors.of(context)
                                        .secondary,
                                  ),
                                ),
                              ),
                            if (stacked &&
                                !bars[i].cancelled &&
                                _known(bars[i].secondaryValue) == null)
                              Positioned(
                                left: slot * i,
                                width: slot,
                                bottom: math.min(
                                  plotHeight - 18,
                                  plotHeight *
                                      (_known(bars[i].value) ?? 0) /
                                      scale.max,
                                ),
                                child: Center(
                                  child: ColoredBox(
                                    color: context.theme.colors.background,
                                    child: Text(
                                      '—',
                                      style: _labelStyle(context),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(left: labelWidth),
              child: SizedBox(
                height:
                    (bars.length <= 4 ? 60 : 38) *
                    MediaQuery.textScalerOf(context).scale(1),
                child: Stack(
                  children: [
                    for (final i in _labelIndices(plotWidth))
                      Positioned(
                        left: math.min(
                          math.max(
                            0.0,
                            slot * (i + .5) - math.min(90.0, plotWidth / 3) / 2,
                          ),
                          math.max(
                            0.0,
                            plotWidth - math.min(90.0, plotWidth / 3),
                          ),
                        ),
                        width: math.min(90.0, plotWidth / 3),
                        child: Column(
                          children: [
                            Text(
                              bars[i].label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: _labelStyle(context),
                            ),
                            if (bars.length <= 4)
                              Text(
                                bars[i].cancelled
                                    ? '取消'
                                    : _value(bars[i].value),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _labelStyle(context),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<int> _labelIndices(double width) {
    final count = math.max(1, (width / 80).floor());
    if (bars.length <= count) return [for (var i = 0; i < bars.length; i++) i];
    if (count == 1) return [bars.length - 1];
    return {
      for (var i = 0; i < count; i++)
        (i * (bars.length - 1) / (count - 1)).round(),
    }.toList();
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ColoredBox(color: color, child: const SizedBox(width: 12, height: 12)),
      const SizedBox(width: 5),
      Text(label, style: _labelStyle(context)),
    ],
  );
}

class _DurationLine extends CustomPainter {
  const _DurationLine(this.bars, this.max, this.color);
  final List<ChartBar> bars;
  final double max;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    Offset? previous;
    for (var i = 0; i < bars.length; i++) {
      final value = bars[i].cancelled ? null : _known(bars[i].value);
      if (value == null) {
        previous = null;
        continue;
      }
      final point = Offset(
        size.width * (i + .5) / bars.length,
        size.height * (1 - value / max),
      );
      if (previous != null) canvas.drawLine(previous, point, paint);
      previous = point;
    }
  }

  @override
  bool shouldRepaint(_DurationLine oldDelegate) =>
      oldDelegate.bars != bars ||
      oldDelegate.max != max ||
      oldDelegate.color != color;
}

class MonitorCoverageChart extends StatelessWidget {
  const MonitorCoverageChart({
    super.key,
    required this.observedMs,
    required this.unclassifiedMs,
  });
  final int observedMs, unclassifiedMs;
  @override
  Widget build(BuildContext context) {
    if (observedMs < 0 ||
        unclassifiedMs < 0 ||
        observedMs + unclassifiedMs == 0) {
      return const Text('暂无可绘制覆盖数据');
    }
    final total = observedMs + unclassifiedMs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            Text('已观测 ${_seconds(observedMs)}'),
            Text('未归类 ${_seconds(unclassifiedMs)}'),
            Text('窗口合计 ${_seconds(total)}'),
          ],
        ),
        const SizedBox(height: 8),
        _BarSeriesColors(
          primary: _ChartPalette.of(context).teal,
          secondary: _ChartPalette.of(context).amber,
          child: MonitorBarChart(
            bars: [
              ChartBar(
                label: '已观测 / 未归类',
                value: observedMs / 1000,
                secondaryValue: unclassifiedMs / 1000,
                detail: '窗口合计 ${_seconds(total)}。',
              ),
            ],
            unit: 's',
            horizontal: true,
            stacked: true,
            primaryLabel: '已观测',
            secondaryLabel: '未归类',
            maxValue: total / 1000,
          ),
        ),
      ],
    );
  }
}

class MonitorIntervalChart extends StatelessWidget {
  const MonitorIntervalChart({super.key, required this.data});
  final SessionActivityTimelineData data;
  String _record(SessionActivityTimelineRow row) =>
      '${row.label} · 偏移 ${_seconds(row.offsetStartMs)} → ${_seconds(row.offsetEndMs)} · 项时长 ${_seconds(row.durationMs)}\n'
      '记录开始：${row.startedAtMs ?? '未知'} · 记录结束：${row.completedAtMs ?? '未知'} · Unix epoch 毫秒'
      '${row.drawable ? '' : '\n未绘制：${row.reasonText}'}';

  @override
  Widget build(BuildContext context) {
    if (!data.available) return Text(data.reasonText);
    if (data.rows.isEmpty) return const Text('暂无可绘制活动记录');
    final span = data.spanMs;
    final scale = span == null
        ? null
        : _Scale(span / 1000, requested: span / 1000);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label:
          '${data.rows.length} 条日志活动记录，${data.rows.where((r) => r.drawable).length} 条可定位。'
          '窗口 ${_seconds(span)}。活动可重叠；空白不代表等待。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (span == null)
            const Text('缺少回合边界，仅保留已记录事实。')
          else ...[
            Text('相对窗口时间 (s)', style: _labelStyle(context)),
            const SizedBox(height: 6),
            _HorizontalTicks(scale: scale!),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              for (final category in const {
                'message': '消息',
                'reasoning': '推理',
                'tool': '工具',
                'other': '其他',
              }.entries)
                _Legend(
                  label: category.value,
                  color: _ChartPalette.of(context).category(category.key),
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (final row in data.rows)
            Semantics(
              label: _record(row),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(row.label, style: _labelStyle(context)),
                    const SizedBox(height: 6),
                    if (span != null && row.drawable)
                      SizedBox(
                        height: 24,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            final uncertainty = (data.boundsResolutionMs / span)
                                .clamp(0.0, .5);
                            return CustomPaint(
                              painter: _Grid(
                                color: DashboardPalette.of(context).grid,
                                divisions: 4,
                              ),
                              child: Stack(
                                children: [
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: width * uncertainty,
                                    child: ColoredBox(
                                      color: context.theme.colors.muted
                                          .withValues(alpha: .65),
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: width * uncertainty,
                                    child: ColoredBox(
                                      color: context.theme.colors.muted
                                          .withValues(alpha: .65),
                                    ),
                                  ),
                                  Positioned(
                                    left: width * row.offsetStartMs! / span,
                                    width:
                                        width *
                                        (row.offsetEndMs! -
                                            row.offsetStartMs!) /
                                        span,
                                    top: 2,
                                    height: 20,
                                    child: _HoverMark(
                                      record: _record(row),
                                      child: ColoredBox(
                                        key: ValueKey(
                                          'monitor-interval-${row.ordinal}',
                                        ),
                                        color: _ChartPalette.of(context)
                                            .category(row.category),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      )
                    else
                      Text(
                        '— ${row.reasonText.isEmpty ? '无法定位' : row.reasonText}',
                        style: _labelStyle(context),
                      ),
                  ],
                ),
              ),
            ),
          const Text('日志活动可重叠；空白不代表等待。', style: TextStyle(fontSize: 12)),
          if (data.sourcePartial) const Text('来源不完整'),
          if (data.omittedItems > 0) Text('省略 ${data.omittedItems} 项'),
          _InspectValues(records: data.rows.map(_record).toList()),
        ],
      ),
    );
  }
}
