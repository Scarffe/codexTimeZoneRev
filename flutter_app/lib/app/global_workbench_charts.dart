import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/global_workbench.dart';
import 'dashboard_style.dart';
import 'session_rhythm_charts.dart' show RhythmInspection;

String globalNumber(AppCopy copy, int? value) =>
    value == null ? '—' : copy.integer(value);
String globalBucketName(AppCopy copy, String value) =>
    value.isEmpty || value == 'unknown' || value == '__unknown__'
    ? copy.text('global.unassigned')
    : value;

class GlobalWorkbenchCharts extends StatelessWidget {
  const GlobalWorkbenchCharts({
    super.key,
    required this.snapshot,
    required this.metric,
    required this.onProject,
    required this.onModel,
  });
  final GlobalSnapshot? snapshot;
  final String metric;
  final ValueChanged<String> onProject, onModel;
  @override
  Widget build(BuildContext context) {
    final daily = _DailyChart(
      buckets: snapshot?.daily ?? const [],
      metric: metric,
      basis: snapshot?.dailyBasis ?? 'local',
      bucketDays: snapshot?.dailyBucketDays ?? 1,
    );
    final project = _CompositionChart(
      key: const ValueKey('global-project-chart'),
      titleKey: 'global.projects',
      buckets: snapshot?.projects ?? const [],
      metric: metric,
      ring: true,
      onSelect: onProject,
    );
    final model = _CompositionChart(
      key: const ValueKey('global-model-chart'),
      titleKey: 'global.models',
      buckets: snapshot?.models ?? const [],
      metric: metric,
      ring: false,
      onSelect: onModel,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1060) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 2, child: daily),
              const SizedBox(width: 12),
              Expanded(child: project),
              const SizedBox(width: 12),
              Expanded(child: model),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            daily,
            const SizedBox(height: 12),
            if (constraints.maxWidth >= 640)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: project),
                  const SizedBox(width: 12),
                  Expanded(child: model),
                ],
              )
            else ...[
              project,
              const SizedBox(height: 12),
              model,
            ],
          ],
        );
      },
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.titleKey, required this.child});
  final String titleKey;
  final Widget child;
  @override
  Widget build(BuildContext context) => FCard(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppCopy.of(context).text(titleKey),
            style: context.theme.typography.body.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _DailyChart extends StatelessWidget {
  const _DailyChart({
    required this.buckets,
    required this.metric,
    required this.basis,
    required this.bucketDays,
  });
  final List<GlobalBucket> buckets;
  final String metric, basis;
  final int bucketDays;
  String label(GlobalBucket bucket) {
    if (bucket.fromMs == null) return bucket.key;
    final start = DateTime.fromMillisecondsSinceEpoch(
      bucket.fromMs!,
      isUtc: true,
    );
    return (basis == 'utc' ? start : start.toLocal())
        .toIso8601String()
        .split('T')
        .first;
  }

  @override
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context), copy = AppCopy.of(context);
    final values = buckets.map((b) => b.tokens.metric(metric)).toList();
    return KeyedSubtree(
      key: const ValueKey('global-daily-chart'),
      child: _ChartCard(
        titleKey: 'global.daily',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              copy.text(
                basis == 'utc' ? 'global.dailyUtc' : 'global.dailyLocal',
                args: {'days': bucketDays},
              ),
              style: context.theme.typography.body.xs.copyWith(
                color: palette.muted,
              ),
            ),
            const SizedBox(height: 6),
            RhythmInspection(
              count: buckets.length,
              height: 154,
              painter: (selected) => _TrendPainter(values, palette, selected),
              hit: (position, size) => buckets.isEmpty
                  ? null
                  : (position.dx / size.width * buckets.length).floor().clamp(
                      0,
                      buckets.length - 1,
                    ),
              readout: (selected) {
                final bucket = selected == null
                    ? buckets.lastOrNull
                    : buckets[selected];
                return Text(
                  bucket == null
                      ? copy.text('global.noData')
                      : copy.text(
                          'global.chartReadout',
                          args: {
                            'label': label(bucket),
                            'value': globalNumber(
                              copy,
                              bucket.tokens.metric(metric),
                            ),
                            'count': copy.integer(bucket.sessions),
                          },
                        ),
                  style: context.theme.typography.body.xs.copyWith(
                    color: palette.muted,
                  ),
                );
              },
              onSelect: (_) {},
            ),
            if (buckets.isNotEmpty) ...[
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label(buckets.first),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.body.xs.copyWith(
                        color: palette.muted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      label(buckets.last),
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.body.xs.copyWith(
                        color: palette.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompositionChart extends StatelessWidget {
  const _CompositionChart({
    super.key,
    required this.titleKey,
    required this.buckets,
    required this.metric,
    required this.ring,
    required this.onSelect,
  });
  final String titleKey, metric;
  final List<GlobalBucket> buckets;
  final bool ring;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context), copy = AppCopy.of(context);
    final ordered = [...buckets]
      ..sort(
        (a, b) => (b.tokens.metric(metric) ?? -1).compareTo(
          a.tokens.metric(metric) ?? -1,
        ),
      );
    final colors = [
      palette.dataBlue,
      palette.reasoning,
      palette.tool,
      palette.chromeAccent,
      palette.muted,
    ];
    final top = ordered.take(4).toList();
    final values = [
      for (final b in top) b.tokens.metric(metric) ?? 0,
      if (ordered.length > 4)
        ordered
            .skip(4)
            .fold<int>(0, (sum, b) => sum + (b.tokens.metric(metric) ?? 0)),
    ];
    final known = values.fold<int>(0, (a, b) => a + b);
    return _ChartCard(
      titleKey: titleKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: copy.text(titleKey),
            child: SizedBox(
              height: ring ? 96 : 40,
              child: CustomPaint(
                painter: _CompositionPainter(
                  values,
                  colors,
                  palette.grid,
                  ring,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (known == 0)
            Text(
              copy.text('global.noData'),
              style: context.theme.typography.body.xs.copyWith(
                color: palette.muted,
              ),
            ),
          for (var i = 0; i < top.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FButton(
                variant: FButtonVariant.ghost,
                onPress: () => onSelect(top[i].key),
                prefix: Container(width: 7, height: 7, color: colors[i]),
                suffix: Text(
                  globalNumber(copy, top[i].tokens.metric(metric)),
                  style: context.theme.typography.body.xs,
                ),
                child: Expanded(
                  child: Text(
                    globalBucketName(copy, top[i].key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.typography.body.xs,
                  ),
                ),
              ),
            ),
          if (ordered.length > 4)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                copy.text(
                  'global.others',
                  args: {
                    'count': ordered.length - 4,
                    'value': globalNumber(copy, values.last),
                  },
                ),
                style: context.theme.typography.body.xs.copyWith(
                  color: palette.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.values, this.palette, this.selected);
  final List<int?> values;
  final DashboardPalette palette;
  final int? selected;
  @override
  void paint(Canvas canvas, Size size) {
    final bottom = size.height - 6, top = 8.0, span = bottom - top;
    final grid = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = top + span * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;
    final maximum = math.max(1, values.whereType<int>().fold<int>(0, math.max));
    Offset point(int index, int value) => Offset(
      values.length == 1
          ? size.width / 2
          : index / (values.length - 1) * size.width,
      bottom - value / maximum * span,
    );
    final line = Paint()
      ..color = palette.dataBlue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    Path? path;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final p = point(i, value);
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawCircle(p, 2.5, Paint()..color = palette.dataBlue);
    }
    if (path != null) canvas.drawPath(path, line);
    if (selected != null &&
        selected! < values.length &&
        values[selected!] != null) {
      final p = point(selected!, values[selected!]!);
      canvas.drawLine(
        Offset(p.dx, 0),
        Offset(p.dx, size.height),
        Paint()
          ..color = palette.controlAccent.withValues(alpha: .45)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(p, 5, Paint()..color = palette.controlAccent);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.palette != palette ||
      oldDelegate.selected != selected;
}

class _CompositionPainter extends CustomPainter {
  _CompositionPainter(this.values, this.colors, this.empty, this.ring);
  final List<int> values;
  final List<Color> colors;
  final Color empty;
  final bool ring;
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    if (ring) {
      final side = math.min(size.width, size.height) - 12,
          rect = Rect.fromCenter(
            center: size.center(Offset.zero),
            width: side,
            height: side,
          );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = empty;
      canvas.drawArc(rect, 0, math.pi * 2, false, paint);
      if (total == 0) return;
      var angle = -math.pi / 2;
      for (var i = 0; i < values.length; i++) {
        final sweep = values[i] / total * math.pi * 2;
        canvas.drawArc(
          rect,
          angle,
          sweep,
          false,
          paint..color = colors[i % colors.length],
        );
        angle += sweep;
      }
    } else {
      final rect = Rect.fromLTWH(0, 10, size.width, 18);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = empty,
      );
      if (total == 0) return;
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)));
      var x = 0.0;
      for (var i = 0; i < values.length; i++) {
        final width = size.width * values[i] / total;
        canvas.drawRect(
          Rect.fromLTWH(x, 10, width, 18),
          Paint()..color = colors[i % colors.length],
        );
        x += width;
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _CompositionPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.colors != colors ||
      oldDelegate.empty != empty ||
      oldDelegate.ring != ring;
}
