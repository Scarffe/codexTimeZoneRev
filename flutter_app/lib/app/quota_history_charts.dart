import '../l10n/app_copy.dart';

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/account_usage.dart';
import '../services/quota_history.dart';
import 'dashboard_style.dart';
import 'dashboard_motion.dart';
import 'inspection_format.dart';

String historyDate(DateTime time) =>
    time.toLocal().toIso8601String().substring(0, 10);
String historyTime(DateTime? time, {AppCopy? copy}) => time == null
    ? (copy?.text('common.unknown') ?? '未知')
    : '${time.toLocal().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} ${historyOffset(time.toLocal().timeZoneOffset.inMinutes)}';
String historyOffset(int minutes) =>
    'UTC${minutes < 0 ? '-' : '+'}${(minutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(minutes.abs() % 60).toString().padLeft(2, '0')}';
String _historyClock(DateTime? time, AppCopy copy) => time == null
    ? copy.text('common.unknown')
    : time.toLocal().toIso8601String().substring(11, 19);

/// One keyboard/semantics target and one painter, independent of sample count.
/// The readout has no timer and is cleared only when pointer/focus leaves.
class _HistoryInspection extends StatefulWidget {
  const _HistoryInspection({
    required this.records,
    required this.height,
    required this.painter,
    required this.pick,
    required this.label,
    required this.identity,
    required this.keyPrefix,
  });
  final List<String> records;
  final double height;
  final String label, keyPrefix;
  final Object identity;
  final CustomPainter Function(int?) painter;
  final int? Function(Offset, Size) pick;
  @override
  State<_HistoryInspection> createState() => _HistoryInspectionState();
}

class _HistoryInspectionState extends State<_HistoryInspection> {
  int? _index;
  bool _focused = false;
  @override
  void didUpdateWidget(_HistoryInspection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity != oldWidget.identity) _index = null;
  }

  void _step(int delta) {
    if (widget.records.isEmpty) return;
    setState(
      () => _index =
          ((_index ?? (delta > 0 ? -1 : widget.records.length)) + delta).clamp(
            0,
            widget.records.length - 1,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Observe the existing policy; these factual charts are deliberately static,
    // so reduced motion and hidden TickerMode never allocate animation tickers.
    DashboardMotionScope.enabledOf(context);
    final readout = _index == null
        ? AppCopy.of(context).text('history.inspectionHint')
        : widget.records[_index!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: widget.label,
          value: readout,
          focusable: true,
          increasedValue: widget.records.isEmpty
              ? readout
              : widget.records[((_index ?? -1) + 1).clamp(
                  0,
                  widget.records.length - 1,
                )],
          decreasedValue: widget.records.isEmpty
              ? readout
              : widget.records[((_index ?? widget.records.length) - 1).clamp(
                  0,
                  widget.records.length - 1,
                )],
          onIncrease: () => _step(1),
          onDecrease: () => _step(-1),
          child: Focus(
            onFocusChange: (focused) => setState(() {
              _focused = focused;
              _index = focused && widget.records.isNotEmpty ? 0 : null;
            }),
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent || event is KeyRepeatEvent) {
                if ([
                  LogicalKeyboardKey.arrowRight,
                  LogicalKeyboardKey.arrowDown,
                ].contains(event.logicalKey)) {
                  _step(1);
                  return KeyEventResult.handled;
                }
                if ([
                  LogicalKeyboardKey.arrowLeft,
                  LogicalKeyboardKey.arrowUp,
                ].contains(event.logicalKey)) {
                  _step(-1);
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: LayoutBuilder(
              builder: (context, constraints) => MouseRegion(
                onHover: (event) {
                  final next = widget.pick(
                    event.localPosition,
                    Size(constraints.maxWidth, widget.height),
                  );
                  if (next != _index) setState(() => _index = next);
                },
                onExit: (_) {
                  if (!_focused) setState(() => _index = null);
                },
                child: GestureDetector(
                  onTapDown: (event) => setState(
                    () => _index = widget.pick(
                      event.localPosition,
                      Size(constraints.maxWidth, widget.height),
                    ),
                  ),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: ValueKey('${widget.keyPrefix}-canvas'),
                      size: Size(constraints.maxWidth, widget.height),
                      painter: widget.painter(_index),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Text(
            readout,
            key: ValueKey('${widget.keyPrefix}-readout'),
            style: context.theme.typography.body.sm.copyWith(height: 1.15),
          ),
        ),
      ],
    );
  }
}

class QuotaHistoryTrendChart extends StatelessWidget {
  const QuotaHistoryTrendChart({
    super.key,
    required this.projection,
    required this.filter,
    this.used = false,
    this.highlightedInterval,
  });
  final QuotaHistoryProjection projection;
  final QuotaHistoryFilter filter;
  final bool used;
  final (DateTime, DateTime)? highlightedInterval;
  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
    final points = projection.trendSegments.expand((c) => c.points).toList();
    final records = <String>[
      for (var i = 0; i < points.length; i++)
        copy.text(
          'history.trendRecord',
          args: {
            'time': historyTime(points[i].completedAtUtc, copy: copy),
            'remaining': inspectionNumber(points[i].remainingPercent),
            'used': inspectionNumber(points[i].usedPercent),
            'quality': copy.text(
              points[i].timeQuality ==
                      UsageObservationTimeQuality.localReceiptFallback
                  ? 'history.receiptFallback'
                  : 'history.queryCompletion',
            ),
            'distance': i == 0
                ? copy.text('history.firstDrawn')
                : copy.text(
                    'history.sincePrevious',
                    args: {
                      'seconds': inspectionNumber(
                        points[i].completedAtUtc
                                .difference(points[i - 1].completedAtUtc)
                                .inMilliseconds /
                            1000,
                      ),
                    },
                  ),
            'interval': points[i].expectedIntervalSec,
            'reset': historyTime(points[i].resetsAtUtc, copy: copy),
          },
        ),
    ];
    final palette = DashboardPalette.of(context);
    final style = context.theme.typography.body.sm.copyWith(
      fontSize: MediaQuery.textScalerOf(context).scale(11),
      color: palette.muted,
    );
    return _HistoryInspection(
      label: copy.text('history.trend'),
      keyPrefix: '额度趋势',
      identity: (projection, used),
      records: records,
      height: 220,
      pick: (offset, size) {
        if (points.isEmpty) return null;
        var nearest = 0, distance = double.infinity;
        for (var i = 0; i < points.length; i++) {
          final pos = _trendPoint(points[i], filter, size, used);
          final d = (pos - offset).distanceSquared;
          if (d < distance) {
            nearest = i;
            distance = d;
          }
        }
        return nearest;
      },
      painter: (index) => QuotaHistoryTrendPainter(
        projection: projection,
        filter: filter,
        palette: palette,
        style: style,
        used: used,
        selected: index == null ? null : points[index],
        highlightedInterval: highlightedInterval,
      ),
    );
  }
}

double _trendX(DateTime time, QuotaHistoryFilter filter, Size size) =>
    42 +
    (size.width - 52) *
        ((time.millisecondsSinceEpoch - filter.fromUtc.millisecondsSinceEpoch) /
                math.max(
                  1,
                  filter.toUtc.difference(filter.fromUtc).inMilliseconds,
                ))
            .clamp(0, 1);
Offset _trendPoint(
  QuotaHistoryPoint p,
  QuotaHistoryFilter filter,
  Size size,
  bool used,
) => Offset(
  _trendX(p.completedAtUtc, filter, size),
  10 +
      (size.height - 40) *
          (1 - (used ? p.usedPercent : p.remainingPercent) / 100),
);
void _label(Canvas canvas, String text, Offset offset, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, offset);
}

class QuotaHistoryTrendPainter extends CustomPainter {
  QuotaHistoryTrendPainter({
    required this.projection,
    required this.filter,
    required this.palette,
    required this.style,
    this.used = false,
    this.selected,
    this.highlightedInterval,
  });
  final QuotaHistoryProjection projection;
  final QuotaHistoryFilter filter;
  final DashboardPalette palette;
  final TextStyle style;
  final bool used;
  final QuotaHistoryPoint? selected;
  final (DateTime, DateTime)? highlightedInterval;
  @override
  void paint(Canvas canvas, Size size) {
    for (final value in [0, 25, 50, 75, 100]) {
      final y = 10 + (size.height - 40) * (1 - value / 100);
      canvas.drawLine(
        Offset(42, y),
        Offset(size.width - 10, y),
        Paint()..color = palette.grid,
      );
      _label(canvas, '$value%', Offset(0, y - 7), style);
    }
    _label(
      canvas,
      historyDate(filter.fromUtc),
      Offset(42, size.height - 20),
      style,
    );
    _label(
      canvas,
      historyDate(filter.toUtc),
      Offset(math.max(42, size.width - 90), size.height - 20),
      style,
    );
    if (highlightedInterval case final interval?) {
      final x = _trendX(interval.$1, filter, size),
          end = _trendX(interval.$2, filter, size);
      canvas.drawRect(
        Rect.fromLTRB(x, 10, math.max(x + 2, end), size.height - 30),
        Paint()..color = palette.controlAccent.withValues(alpha: .2),
      );
    }
    QuotaHistoryPoint? previous;
    final line = Paint()
      ..color = palette.dataBlue
      ..strokeWidth = 1.7;
    for (final column in projection.trendSegments) {
      if (column.points.isEmpty) continue;
      // Task 3 contract: the type is a screen column, not a continuity span.
      // Only this explicit flag permits a cross-column connector.
      if (column.connectToPrevious &&
          !column.hasInternalGaps &&
          previous != null) {
        canvas.drawLine(
          _trendPoint(previous, filter, size, used),
          _trendPoint(column.points.first, filter, size, used),
          line,
        );
      }
      for (var i = 0; i < column.points.length; i++) {
        final point = column.points[i],
            at = _trendPoint(point, filter, size, used);
        if (i > 0 && !column.hasInternalGaps) {
          canvas.drawLine(
            _trendPoint(column.points[i - 1], filter, size, used),
            at,
            line,
          );
        }
        canvas.drawCircle(
          at,
          identical(selected, point) ? 5 : 2.5,
          Paint()..color = palette.dataBlue,
        );
      }
      if (column.hasInternalGaps) {
        final x = _trendPoint(column.points.first, filter, size, used).dx;
        canvas.drawLine(
          Offset(x - 3, size.height - 34),
          Offset(x + 3, size.height - 40),
          Paint()
            ..color = palette.muted
            ..strokeWidth = 2,
        );
      }
      // Dense columns also prohibit an outgoing connector conservatively.
      previous = column.hasInternalGaps ? null : column.points.last;
    }
  }

  @override
  bool shouldRepaint(QuotaHistoryTrendPainter oldDelegate) => true;
}

class QuotaHistoryHeatmap extends StatelessWidget {
  const QuotaHistoryHeatmap({super.key, required this.cells});
  final List<QuotaHistoryHourCell> cells;
  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
    final rows = <String>[];
    for (final c in cells) {
      final key = '${c.localDate}|${c.utcOffsetMinutes}';
      if (!rows.contains(key)) rows.add(key);
    }
    final records = [
      for (final c in cells)
        copy.text(
          'history.hourRecord',
          args: {
            'date': c.localDate,
            'hour': c.localHour.toString().padLeft(2, '0'),
            'offset': historyOffset(c.utcOffsetMinutes),
            'remaining': c.observedRemaining == null
                ? copy.text('common.unknown')
                : '${inspectionNumber(c.observedRemaining!)}%',
            'samples': copy.text(
              c.sampleCount == 1 ? 'history.singleSample' : 'history.samples',
              args: {'count': c.sampleCount},
            ),
            'failures': c.failureCount,
            'gap': c.hasGap ? copy.text('history.hasGap') : '',
            'first': _historyClock(c.firstObservedUtc, copy),
            'last': _historyClock(c.lastObservedUtc, copy),
          },
        ),
    ];
    final palette = DashboardPalette.of(context);
    final style = context.theme.typography.body.sm.copyWith(
      fontSize: MediaQuery.textScalerOf(context).scale(10),
      color: palette.muted,
    );
    final height = math.max(100.0, rows.length * 44.0 + 26);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: math.max(
          550,
          MediaQuery.sizeOf(context).width > 1150
              ? (MediaQuery.sizeOf(context).width - 180) * .55
              : MediaQuery.sizeOf(context).width - 180,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Text(copy.text('history.zeroRemaining')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [palette.danger, palette.dataBlue],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('100%'),
                ],
              ),
            ),
            _HistoryInspection(
              label: copy.text('history.hourly'),
              keyPrefix: '小时观测',
              identity: cells,
              records: records,
              height: height,
              pick: (offset, size) {
                final hour = ((offset.dx - 112) / ((size.width - 116) / 24))
                    .floor();
                final row = ((offset.dy - 24) / 44).floor();
                if (hour < 0 || hour > 23 || row < 0 || row >= rows.length) {
                  return null;
                }
                final index = cells.indexWhere(
                  (c) =>
                      '${c.localDate}|${c.utcOffsetMinutes}' == rows[row] &&
                      c.localHour == hour,
                );
                return index < 0 ? null : index;
              },
              painter: (index) =>
                  _HeatmapPainter(cells, rows, palette, style, index),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter(
    this.cells,
    this.rows,
    this.palette,
    this.style,
    this.selected,
  );
  final List<QuotaHistoryHourCell> cells;
  final List<String> rows;
  final DashboardPalette palette;
  final TextStyle style;
  final int? selected;
  @override
  void paint(Canvas canvas, Size size) {
    final width = (size.width - 116) / 24;
    for (var h = 0; h < 24; h += 3) {
      _label(
        canvas,
        '${h.toString().padLeft(2, '0')}h',
        Offset(112 + h * width, 0),
        style,
      );
    }
    for (var r = 0; r < rows.length; r++) {
      final parts = rows[r].split('|');
      _label(
        canvas,
        '${parts[0]}\n${historyOffset(int.parse(parts[1]))}',
        Offset(0, 24 + r * 44),
        style,
      );
    }
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i],
          row = rows.indexOf(
            '${cells[i].localDate}|${cells[i].utcOffsetMinutes}',
          );
      final rect = Rect.fromLTWH(
        112 + c.localHour * width,
        24 + row * 44,
        width - 2,
        30,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = c.observedRemaining == null
              ? palette.soft
              : Color.lerp(
                  palette.danger,
                  palette.dataBlue,
                  c.observedRemaining! / 100,
                )!,
      );
      if (c.observedRemaining == null) {
        canvas.save();
        canvas.clipRect(rect);
        for (var x = rect.left - 24; x < rect.right; x += 6) {
          canvas.drawLine(
            Offset(x, rect.bottom),
            Offset(x + 24, rect.top),
            Paint()..color = palette.border,
          );
        }
        canvas.restore();
      }
      if (c.failureCount > 0) {
        canvas.drawRect(
          rect.deflate(1),
          Paint()
            ..color = palette.danger
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        // A contrasting cross survives even when the low-value fill is red.
        final mark = Paint()
          ..color = palette.foreground
          ..strokeWidth = 1.5;
        canvas.drawLine(
          rect.center - const Offset(3, 3),
          rect.center + const Offset(3, 3),
          mark,
        );
        canvas.drawLine(
          rect.center + const Offset(-3, 3),
          rect.center + const Offset(3, -3),
          mark,
        );
      }
      if (c.hasGap) {
        for (var x = rect.left; x < rect.right; x += 6) {
          canvas.drawLine(
            Offset(x, rect.top),
            Offset(math.min(x + 3, rect.right), rect.top),
            Paint()
              ..color = palette.foreground
              ..strokeWidth = 2,
          );
        }
      }
      if (i == selected) {
        canvas.drawRect(
          rect.inflate(1),
          Paint()
            ..color = palette.foreground
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter oldDelegate) => true;
}

String _eventLabel(AppCopy copy, QuotaHistoryEvent e) => switch (e.kind) {
  QuotaHistoryEventKind.usedIncrease => copy.text(
    'history.event.usedIncrease',
    args: {'points': inspectionNumber(e.deltaPercentagePoints!.abs())},
  ),
  QuotaHistoryEventKind.usedDecrease => copy.text(
    'history.event.usedDecrease',
    args: {'points': inspectionNumber(e.deltaPercentagePoints!.abs())},
  ),
  QuotaHistoryEventKind.reportedResetChanged => copy.text(
    'history.event.resetChanged',
  ),
  QuotaHistoryEventKind.crossedReportedReset => copy.text(
    'history.event.crossedReset',
  ),
  QuotaHistoryEventKind.queryFailure => copy.text(
    'history.event.failure',
    args: {'kind': e.errorKind ?? 'unavailable'},
  ),
  QuotaHistoryEventKind.noLimits => copy.text('history.event.noLimits'),
  QuotaHistoryEventKind.missingWindow => copy.text(
    'history.event.missingWindow',
  ),
  QuotaHistoryEventKind.clockReversal => copy.text(
    'history.event.clockReversal',
  ),
};
String _gapLabel(AppCopy copy, QuotaHistoryGapReason reason) =>
    copy.text('history.gap.${reason.name}');

class QuotaHistoryTimeline extends StatefulWidget {
  const QuotaHistoryTimeline({
    super.key,
    required this.projection,
    required this.onSelect,
    this.selected,
  });
  final QuotaHistoryProjection projection;
  final ValueChanged<(DateTime, DateTime)> onSelect;
  final (DateTime, DateTime)? selected;
  @override
  State<QuotaHistoryTimeline> createState() => _QuotaHistoryTimelineState();
}

class _QuotaHistoryTimelineState extends State<QuotaHistoryTimeline> {
  late List<(DateTime, DateTime, String)> _items;
  QuotaHistoryProjection? _preparedProjection;
  bool? _preparedEnglish;
  void _prepare(AppCopy copy) {
    if (identical(_preparedProjection, widget.projection) &&
        _preparedEnglish == copy.isEnglish) {
      return;
    }
    _preparedProjection = widget.projection;
    _preparedEnglish = copy.isEnglish;
    _items = [
      for (final e in widget.projection.events)
        (
          e.fromUtc,
          e.toUtc,
          '${_eventLabel(copy, e)}${e.previousReportedResetUtc != null || e.reportedResetUtc != null ? copy.text(
                  'history.resetReport',
                  args: {
                    'previous': historyTime(e.previousReportedResetUtc, copy: copy),
                    'current': historyTime(e.reportedResetUtc, copy: copy),
                  },
                ) : ''}',
        ),
      for (final g in widget.projection.gaps)
        (g.fromUtc, g.toUtc, _gapLabel(copy, g.reason)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
    _prepare(copy);
    return SizedBox(
      height: 350,
      child: _items.isEmpty
          ? Text(copy.text('history.noEvents'))
          : ListView.builder(
              key: const ValueKey('history-timeline-list'),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index],
                    interval = (_items[index].$1, _items[index].$2);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FButton(
                    key: ValueKey('history-event-$index'),
                    mainAxisAlignment: MainAxisAlignment.start,
                    variant: interval == widget.selected
                        ? FButtonVariant.primary
                        : FButtonVariant.outline,
                    onPress: () => widget.onSelect(interval),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${item.$3}\n${historyTime(item.$1, copy: copy)}\n${copy.text('history.until', args: {'time': historyTime(item.$2, copy: copy)})}',
                        style: context.theme.typography.body.sm,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
