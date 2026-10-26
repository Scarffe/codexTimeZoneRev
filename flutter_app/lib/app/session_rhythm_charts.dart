import '../l10n/app_language.dart';
import '../l10n/app_copy.dart';

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_rhythm.dart';
import '../services/session_rhythm_projection.dart';
import 'dashboard_style.dart';
import 'monitor_charts.dart';

String rhythmStatusLabel(
  RhythmStatus status, {
  AppCopy copy = const AppCopy(AppLanguage.zh),
}) => switch (status) {
  RhythmStatus.completed => copy.text('analysis.completed'),
  RhythmStatus.cancelled => copy.text('analysis.cancelled'),
  RhythmStatus.running => copy.text('analysis.notTerminal'),
  RhythmStatus.unknown => copy.text('analysis.unknown'),
};

String rhythmSeconds(
  num? value, {
  AppCopy copy = const AppCopy(AppLanguage.zh),
}) => value == null
    ? copy.text('analysis.unknown')
    : '${(value / 1000).toStringAsFixed(2)} s';

/// Persistent inspection: no tooltip, timer or animation; arrows inspect, Enter selects.
class RhythmInspection extends StatefulWidget {
  const RhythmInspection({
    super.key,
    required this.count,
    required this.height,
    required this.painter,
    required this.hit,
    required this.readout,
    required this.onSelect,
  });
  final int count;
  final double height;
  final CustomPainter Function(int?) painter;
  final int? Function(Offset, Size) hit;
  final Widget Function(int?) readout;
  final ValueChanged<int> onSelect;
  @override
  State<RhythmInspection> createState() => _RhythmInspectionState();
}

class _RhythmInspectionState extends State<RhythmInspection> {
  int? index;
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  void inspect(int? next) {
    if (next != null && next != index) setState(() => index = next);
  }

  @override
  Widget build(BuildContext context) {
    final selected = index != null && index! < widget.count ? index : null;
    return Focus(
      focusNode: focus,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || widget.count == 0) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if ([
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowUp,
        ].contains(key)) {
          final delta =
              key == LogicalKeyboardKey.arrowLeft ||
                  key == LogicalKeyboardKey.arrowUp
              ? -1
              : 1;
          inspect(((index ?? (delta > 0 ? -1 : 0)) + delta) % widget.count);
          return KeyEventResult.handled;
        }
        if ((key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space) &&
            index != null &&
            index! < widget.count) {
          widget.onSelect(index!);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final size = Size(box.maxWidth, widget.height);
              return Semantics(
                label: AppCopy.of(context)
                    .text('analysis.chartArrowKeysInspectEnterSelects'),
                focusable: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onHover: (event) =>
                      inspect(widget.hit(event.localPosition, size)),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (event) {
                      focus.requestFocus();
                      final next = widget.hit(event.localPosition, size);
                      inspect(next);
                      if (next != null) widget.onSelect(next);
                    },
                    child: SizedBox(
                      height: widget.height,
                      child: CustomPaint(painter: widget.painter(selected)),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          widget.readout(selected),
        ],
      ),
    );
  }
}

class SessionRhythmCharts extends StatefulWidget {
  const SessionRhythmCharts({
    super.key,
    required this.projection,
    this.selectedHour,
    required this.onHour,
    required this.onTurn,
  });
  final RhythmProjection projection;
  final RhythmHour? selectedHour;
  final ValueChanged<RhythmHour> onHour;
  final void Function(RhythmSource, RhythmTurn) onTurn;
  @override
  State<SessionRhythmCharts> createState() => _SessionRhythmChartsState();
}

class _SessionRhythmChartsState extends State<SessionRhythmCharts> {
  String metric = 'completed';
  @override
  Widget build(BuildContext context) {
    final p = widget.projection, palette = DashboardPalette.of(context);
    void label(
      Canvas canvas,
      String text,
      Offset offset,
      Color color, {
      double maxWidth = double.infinity,
    }) => _text(
      canvas,
      text,
      offset,
      color,
      maxWidth: maxWidth,
      scale: MediaQuery.textScalerOf(context),
    );
    final days = <String, List<RhythmHour>>{};
    for (final h in p.hours) {
      days
          .putIfAbsent(
            h.localStart.toIso8601String().substring(0, 10),
            () => [],
          )
          .add(h);
    }
    final rows = days.entries.toList();
    final rowSlots = <List<(int, int)>>[];
    for (final row in rows) {
      final occurrences = <int, int>{};
      rowSlots.add([
        for (final h in row.value)
          (
            h.localStart.hour,
            occurrences.update(
              h.localStart.hour,
              (n) => n + 1,
              ifAbsent: () => 0,
            ),
          ),
      ]);
    }
    final slots = rowSlots.expand((r) => r).toSet().toList()
      ..sort(
        (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
      );
    final ordered = rows.expand((r) => r.value).toList();
    final maxSlots = math.max(1, slots.length);
    final heatHeight = 24.0 + rows.length * 23;
    final flat = [
      for (final lane in p.lanes) ...[
        for (final turn in lane.turns) (lane.source, turn),
      ],
    ];
    final samples = [
      for (final pair in flat)
        if (pair.$2.status == RhythmStatus.completed &&
            pair.$2.durationMs != null &&
            pair.$2.completedAtMs != null &&
            pair.$2.completedAtMs! >=
                (widget.selectedHour?.startMs ??
                    p.fromUtc.millisecondsSinceEpoch) &&
            pair.$2.completedAtMs! <
                (widget.selectedHour?.endMs ?? p.toUtc.millisecondsSinceEpoch))
          pair,
    ];
    final d = p.distribution;
    final byDuration = <int, List<(RhythmSource, RhythmTurn)>>{};
    for (final sample in samples) {
      byDuration.putIfAbsent(sample.$2.durationMs!, () => []).add(sample);
    }
    final usedSamples = <int, int>{};
    final plottedSamples = [
      for (final duration in d.pointsMs)
        () {
          final matching =
              byDuration[duration] ?? const <(RhythmSource, RhythmTurn)>[];
          final occurrence = usedSamples.update(
            duration,
            (n) => n + 1,
            ifAbsent: () => 0,
          );
          return matching.isEmpty
              ? null
              : matching[occurrence % matching.length];
        }(),
    ];
    final maxDuration = math.max(1.0, d.maximumMs ?? 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonitorChartFrame(
          key: const ValueKey('rhythm-heatmap'),
          title: AppCopy.of(context).text('analysis.dayHourActivityHeatmap'),
          icon: FLucideIcons.grid2x2,
          controls: [
            MonitorChoice(
              label: AppCopy.of(context).text('analysis.heatmapMetric'),
              value: metric,
              items: {
                AppCopy.of(context).text('analysis.completedCount'):
                    'completed',
                AppCopy.of(context).text('analysis.cancelledCount'):
                    'cancelled',
                AppCopy.of(context).text('analysis.activityTime'): 'activity',
              },
              onChanged: (v) => setState(() => metric = v),
            ),
          ],
          footnotes: [
            AppCopy.of(context)
                .text('analysis.paleNoRecordUnknownUnderlinePartial'),
          ],
          child: RhythmInspection(
            key: ValueKey(
              'rhythm-hours-${ordered.firstOrNull?.key}-${ordered.lastOrNull?.key}-${rows.length}',
            ),
            count: ordered.length,
            height: heatHeight,
            hit: (offset, size) {
              final row = ((offset.dy - 24) / 23).floor();
              final col = ((offset.dx - 88) / ((size.width - 88) / maxSlots))
                  .floor();
              if (row < 0 ||
                  row >= rows.length ||
                  col < 0 ||
                  col >= slots.length) {
                return null;
              }
              final localIndex = rowSlots[row].indexOf(slots[col]);
              if (localIndex < 0) return null;
              return rows.take(row).fold<int>(0, (n, r) => n + r.value.length) +
                  localIndex;
            },
            painter: (selected) => _RhythmPainter((canvas, size) {
              final width = (size.width - 88) / maxSlots;
              for (var slot = 0; slot < slots.length; slot++) {
                if (slots[slot].$1 % 3 == 0 || slots[slot].$2 > 0) {
                  label(
                    canvas,
                    '${slots[slot].$1}${slots[slot].$2 > 0 ? 'b' : ''}',
                    Offset(88 + slot * width, 0),
                    palette.muted,
                  );
                }
              }
              var n = 0;
              for (var row = 0; row < rows.length; row++) {
                label(
                  canvas,
                  rows[row].key.substring(5),
                  Offset(0, 27 + row * 23),
                  palette.muted,
                );
                for (var col = 0; col < rows[row].value.length; col++) {
                  final h = rows[row].value[col];
                  final active =
                      widget.selectedHour == null ||
                      widget.selectedHour!.key == h.key;
                  final num? value = !active
                      ? null
                      : metric == 'activity'
                      ? h.activityMs
                      : metric == 'cancelled'
                      ? h.cancelledCount
                      : h.completedCount;
                  final rect = Rect.fromLTWH(
                    88 + slots.indexOf(rowSlots[row][col]) * width,
                    25 + row * 23,
                    math.max(1, width - 2),
                    19,
                  );
                  final intensity = value == null
                      ? 0.0
                      : value == 0
                      ? 0.08
                      : math.min(
                          1.0,
                          0.30 +
                              math.log(1 + value) /
                                  (metric == 'activity' ? 18 : 5),
                        );
                  canvas.drawRRect(
                    RRect.fromRectAndRadius(rect, const Radius.circular(2)),
                    Paint()
                      ..color = Color.lerp(
                        palette.soft,
                        metric == 'cancelled'
                            ? palette.danger
                            : palette.dataBlue,
                        intensity,
                      )!,
                  );
                  if (h.incomplete) {
                    canvas.drawLine(
                      rect.bottomLeft,
                      rect.bottomRight,
                      Paint()
                        ..color = palette.reasoning
                        ..strokeWidth = 2,
                    );
                  }
                  if (n == selected || widget.selectedHour?.key == h.key) {
                    canvas.drawRect(
                      rect,
                      Paint()
                        ..color = palette.foreground
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 1.5,
                    );
                  }
                  n++;
                }
              }
            }),
            readout: (i) {
              if (i == null) {
                return Text(
                  AppCopy.of(context)
                      .text('analysis.hoverArrowsInspectClickEnterFilters'),
                );
              }
              final h = ordered[i];
              final active =
                  widget.selectedHour == null ||
                  h.key == widget.selectedHour!.key;
              return Text(
                '${h.label} · ${active ? AppCopy.of(context).text('analysis.completedCancelledActivity', args: {
                        'p0': h.completedCount,
                        'p1': h.cancelledCount,
                        'p2': rhythmSeconds(h.activityMs, copy: AppCopy.of(context)),
                      }) : AppCopy.of(context).text('analysis.unselectedHourValuesHidden')}${h.incomplete ? AppCopy.of(context).text('analysis.partial') : ''}',
                key: const ValueKey('rhythm-hour-readout'),
              );
            },
            onSelect: (i) => widget.onHour(ordered[i]),
          ),
        ),
        const SizedBox(height: 12),
        MonitorChartFrame(
          key: const ValueKey('rhythm-lanes'),
          title: AppCopy.of(context).text('analysis.sessionActivityLanes'),
          icon: FLucideIcons.rows3,
          child: RhythmInspection(
            key: ValueKey(
              'rhythm-turns-${p.fromUtc}-${widget.selectedHour?.key}-${flat.length}',
            ),
            count: flat.length,
            height: math.max(74.0, p.lanes.length * 38.0 + 24),
            hit: (offset, size) {
              final row = ((offset.dy - 20) / 38).floor();
              if (row < 0 || row >= p.lanes.length) return null;
              final lane = p.lanes[row];
              if (lane.turns.isEmpty) return null;
              final start =
                  widget.selectedHour?.startMs ??
                  p.fromUtc.millisecondsSinceEpoch;
              final end =
                  widget.selectedHour?.endMs ?? p.toUtc.millisecondsSinceEpoch;
              final time =
                  start +
                  ((offset.dx - 100) / math.max(1, size.width - 100)) *
                      (end - start);
              // Match the same effective item intervals that produce the lane.
              // Real overlaps use stable native order, then turn ID, not cache order.
              int? owner;
              for (var i = 0; i < lane.turns.length; i++) {
                final turn = lane.turns[i];
                if (!turn.activityAvailable ||
                    !turn.activityIntervals.any((interval) {
                      final from = math.max(
                        interval.startMs,
                        math.max(start, p.fromUtc.millisecondsSinceEpoch),
                      );
                      final to = math.min(
                        interval.endMs,
                        math.min(end, p.toUtc.millisecondsSinceEpoch),
                      );
                      return from <= time && time < to;
                    })) {
                  continue;
                }
                if (owner == null ||
                    turn.order < lane.turns[owner].order ||
                    (turn.order == lane.turns[owner].order &&
                        turn.turnId.compareTo(lane.turns[owner].turnId) < 0)) {
                  owner = i;
                }
              }
              if (owner != null) {
                return p.lanes
                        .take(row)
                        .fold<int>(0, (n, lane) => n + lane.turns.length) +
                    owner;
              }
              // Empty space still inspects the nearest dated fact. Undated facts
              // remain in the inspection sequence and are reachable by keyboard.
              var best = 0;
              double distance(int i) =>
                  ((lane.turns[i].completedAtMs ??
                              lane.turns[i].startedAtMs ??
                              start) -
                          time)
                      .abs();
              for (var i = 1; i < lane.turns.length; i++) {
                if (distance(i) < distance(best)) best = i;
              }
              return p.lanes
                      .take(row)
                      .fold<int>(0, (n, lane) => n + lane.turns.length) +
                  best;
            },
            painter: (selected) => _RhythmPainter((canvas, size) {
              final start =
                  widget.selectedHour?.startMs ??
                  p.fromUtc.millisecondsSinceEpoch;
              final end =
                  widget.selectedHour?.endMs ?? p.toUtc.millisecondsSinceEpoch;
              double x(int ms) =>
                  100 +
                  ((ms - start) / math.max(1, end - start)).clamp(0, 1) *
                      (size.width - 100);
              label(
                canvas,
                '${DateTime.fromMillisecondsSinceEpoch(start).toLocal().toString().substring(5, 16)} → ${DateTime.fromMillisecondsSinceEpoch(end).toLocal().toString().substring(5, 16)}',
                const Offset(100, 0),
                palette.muted,
              );
              for (var i = 0; i < p.lanes.length; i++) {
                final lane = p.lanes[i];
                final y = 26.0 + i * 38;
                label(
                  canvas,
                  '${i + 1}. ${lane.source.title}',
                  Offset(0, y),
                  palette.foreground,
                  maxWidth: 94,
                );
                canvas.drawLine(
                  Offset(100, y + 10),
                  Offset(size.width, y + 10),
                  Paint()..color = palette.grid,
                );
                for (final interval in lane.intervals) {
                  canvas.drawRect(
                    Rect.fromLTRB(
                      x(interval.startMs),
                      y + 3,
                      math.max(x(interval.startMs) + 2, x(interval.endMs)),
                      y + 17,
                    ),
                    Paint()..color = palette.tool,
                  );
                }
                if (lane.activityMs == null) {
                  label(
                    canvas,
                    AppCopy.of(context)
                        .text('analysis.activityUnknownTurnCanBeInspected'),
                    Offset(104, y),
                    palette.muted,
                  );
                }
                if (selected != null &&
                    flat[selected].$1.key == lane.source.key) {
                  final t = flat[selected].$2;
                  canvas.drawCircle(
                    Offset(
                      x(t.completedAtMs ?? t.startedAtMs ?? start),
                      y + 10,
                    ),
                    5,
                    Paint()..color = palette.foreground,
                  );
                }
              }
            }),
            readout: (i) => Text(
              i == null
                  ? AppCopy.of(context)
                        .text('analysis.hoverArrowsInspectClickEnterSelects')
                  : '${flat[i].$1.title} · ${flat[i].$2.turnId} · ${rhythmStatusLabel(flat[i].$2.status, copy: AppCopy.of(context))} · ${rhythmSeconds(flat[i].$2.durationMs, copy: AppCopy.of(context))}',
            ),
            onSelect: (i) => widget.onTurn(flat[i].$1, flat[i].$2),
          ),
        ),
        const SizedBox(height: 12),
        MonitorChartFrame(
          key: const ValueKey('rhythm-distribution'),
          title: AppCopy.of(context)
              .text('analysis.completeTurnDurationBoxPlotAndSamples'),
          icon: FLucideIcons.chartNoAxesColumn,
          footnotes: d.showBox
              ? const []
              : [
                  AppCopy.of(context)
                      .text('analysis.fewerThanSamplesPointsOnly'),
                ],
          child: RhythmInspection(
            key: ValueKey(
              'rhythm-samples-${p.fromUtc}-${widget.selectedHour?.key}-${d.count}',
            ),
            count: d.pointsMs.length,
            height: 84,
            hit: (offset, size) {
              if (d.pointsMs.isEmpty) return null;
              double distance(int i) {
                final x = 12 + d.pointsMs[i] / maxDuration * (size.width - 24);
                final y = 54 + (i % 3) * 4;
                return (Offset(x, y.toDouble()) - offset).distanceSquared;
              }

              var best = 0;
              for (var i = 1; i < d.pointsMs.length; i++) {
                if (distance(i) < distance(best)) {
                  best = i;
                }
              }
              return best;
            },
            painter: (selected) => _RhythmPainter((canvas, size) {
              double x(num v) => 12 + v / maxDuration * (size.width - 24);
              final paint = Paint()..color = palette.dataBlue;
              if (d.showBox) {
                canvas.drawLine(
                  Offset(x(d.minimumMs!), 28),
                  Offset(x(d.maximumMs!), 28),
                  paint..strokeWidth = 2,
                );
                for (final v in [d.minimumMs!, d.maximumMs!]) {
                  canvas.drawLine(Offset(x(v), 20), Offset(x(v), 36), paint);
                }
                canvas.drawRect(
                  Rect.fromLTRB(x(d.q1Ms!), 16, x(d.q3Ms!), 40),
                  Paint()..color = palette.dataBlue.withValues(alpha: 0.3),
                );
                canvas.drawLine(
                  Offset(x(d.medianMs!), 16),
                  Offset(x(d.medianMs!), 40),
                  paint,
                );
              }
              for (var i = 0; i < d.pointsMs.length; i++) {
                canvas.drawCircle(
                  Offset(x(d.pointsMs[i]), 54 + (i % 3) * 4),
                  i == selected ? 5 : 2.5,
                  Paint()
                    ..color = i == selected
                        ? palette.foreground
                        : palette.dataBlue,
                );
              }
              label(canvas, '0.00 s', const Offset(0, 68), palette.muted);
              label(
                canvas,
                rhythmSeconds(d.maximumMs, copy: AppCopy.of(context)),
                Offset(math.max(80, size.width - 100), 68),
                palette.muted,
              );
            }),
            readout: (i) => Text(
              AppCopy.of(context).text(
                'analysis.samplesMedian',
                args: {
                  'p0': d.count,
                  'p1': rhythmSeconds(d.medianMs, copy: AppCopy.of(context)),
                  'p2': i == null
                      ? ''
                      : ' · ${plottedSamples[i]?.$1.title ?? ''} ${plottedSamples[i]?.$2.turnId ?? ''} · ${rhythmSeconds(d.pointsMs[i], copy: AppCopy.of(context))}',
                },
              ),
            ),
            onSelect: (i) {
              final pair = plottedSamples[i];
              if (pair != null) widget.onTurn(pair.$1, pair.$2);
            },
          ),
        ),
      ],
    );
  }
}

class _RhythmPainter extends CustomPainter {
  _RhythmPainter(this.draw);
  final void Function(Canvas, Size) draw;
  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);
  @override
  bool shouldRepaint(covariant _RhythmPainter oldDelegate) => true;
}

void _text(
  Canvas canvas,
  String text,
  Offset offset,
  Color color, {
  double maxWidth = double.infinity,
  TextScaler scale = TextScaler.noScaling,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Microsoft YaHei UI',
        fontSize: 11,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
    textScaler: scale,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, offset);
}
