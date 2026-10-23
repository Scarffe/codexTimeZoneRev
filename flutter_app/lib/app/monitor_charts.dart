import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_activity_timeline.dart';

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
  factory _ChartPalette.of(BuildContext context) =>
      context.theme.colors.background.computeLuminance() < .5
      ? const _ChartPalette(
          Color(0xff60a5fa),
          Color(0xffc084fc),
          Color(0xff2dd4bf),
          Color(0xfffbbf24),
        )
      : const _ChartPalette(
          Color(0xff2563eb),
          Color(0xff9333ea),
          Color(0xff0f766e),
          Color(0xffb45309),
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
      padding: const EdgeInsets.all(16),
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
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  for (final control in controls)
                    SizedBox(
                      width: math.min(180, constraints.maxWidth),
                      child: control,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            child,
            for (final note in footnotes)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
class _InspectValues extends StatelessWidget {
  const _InspectValues({required this.records});
  final List<String> records;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: FButton(
      mainAxisSize: MainAxisSize.min,
      variant: FButtonVariant.ghost,
      prefix: const Icon(FLucideIcons.table2, size: 16),
      onPress: () => showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭图表数值',
        pageBuilder: (context, _, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 620,
                maxHeight: MediaQuery.sizeOf(context).height * .85,
              ),
              child: FCard(
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
                        onPress: () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
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
  });
  final List<ChartBar> bars;
  final String unit, xLabel, primaryLabel, secondaryLabel;
  final bool horizontal, integers, stacked;
  final double height;

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
          if (horizontal) ...[
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
                              color: context.theme.colors.border,
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
    if (bar.cancelled) return [const Center(child: Text('×'))];
    final primary = _known(bar.value), secondary = _known(bar.secondaryValue);
    return [
      if (primary != null)
        Positioned(
          left: 0,
          top: 2,
          height: 20,
          width: width * primary / max,
          child: ColoredBox(
            key: ValueKey('monitor-bar-$index-primary'),
            color: _BarSeriesColors.of(context).primary,
          ),
        )
      else
        const Align(alignment: Alignment.centerLeft, child: Text('—')),
      if (stacked && secondary != null)
        Positioned(
          left: width * (primary ?? 0) / max,
          top: 2,
          height: 20,
          width: width * secondary / max,
          child: ColoredBox(
            key: ValueKey('monitor-bar-$index-secondary'),
            color: _BarSeriesColors.of(context).secondary,
          ),
        ),
    ];
  }

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
                        color: context.theme.colors.border,
                        divisions: scale.ticks.length - 1,
                        horizontal: false,
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
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
                                    child: Text(
                                      bars[i].cancelled ? '×' : '—',
                                      style: _labelStyle(context),
                                    ),
                                  ),
                                ),
                              )
                            else
                              Positioned(
                                left: slot * i + (slot - markWidth) / 2,
                                width: markWidth,
                                bottom: 0,
                                height:
                                    plotHeight *
                                    _known(bars[i].value)! /
                                    scale.max,
                                child: Semantics(
                                  label: _record(bars[i]),
                                  child: ColoredBox(
                                    key: ValueKey('monitor-bar-$i-primary'),
                                    color: _BarSeriesColors.of(context).primary,
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
                                child: ColoredBox(
                                  key: ValueKey('monitor-bar-$i-secondary'),
                                  color: _BarSeriesColors.of(context).secondary,
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
                                color: context.theme.colors.border,
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
                                    child: ColoredBox(
                                      key: ValueKey(
                                        'monitor-interval-${row.ordinal}',
                                      ),
                                      color: _ChartPalette.of(context)
                                          .category(row.category),
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
