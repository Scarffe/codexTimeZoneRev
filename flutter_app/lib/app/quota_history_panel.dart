import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/account_usage.dart';
import '../services/quota_history.dart';
import '../state/account_sources_controller.dart';
import '../state/quota_history_controller.dart';
import 'inspection_format.dart';
import 'monitor_charts.dart';
import 'quota_history_charts.dart';

/// Local filtering only. AccountSourcesPanel, outside this panel, owns source management.
class QuotaHistoryPanel extends StatefulWidget {
  const QuotaHistoryPanel({
    super.key,
    required this.controller,
    required this.owner,
  });
  final QuotaHistoryController controller;
  final AccountSourcesController? owner;
  @override
  State<QuotaHistoryPanel> createState() => _QuotaHistoryPanelState();
}

class _QuotaHistoryPanelState extends State<QuotaHistoryPanel> {
  String? _source, _current, _segment, _bucket;
  UsageWindowRole? _role;
  int? _duration;
  int _days = 7;
  bool _used = false;
  var _metric = QuotaHistoryHeatmapMetric.minimumRemaining;
  List<String> _segments = [];
  List<QuotaHistorySeries> _series = [];
  (DateTime, DateTime)? _highlight;
  int _loadSerial = 0;
  int _completedAttempts = -1;
  @override
  void initState() {
    super.initState();
    widget.owner?.addListener(_ownerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ownerChanged();
    });
  }

  @override
  void dispose() {
    widget.owner?.removeListener(_ownerChanged);
    _loadSerial++;
    super.dispose();
  }

  void _ownerChanged() {
    if (!mounted) return;
    final selected = widget.owner?.selected;
    if (_source != selected?.id || _current != selected?.historySegmentId) {
      setState(() {
        _completedAttempts = selected == null
            ? -1
            : selected.attempts - (selected.busy ? 1 : 0);
        _source = selected?.id;
        _current = selected?.historySegmentId;
        _segment = _current;
        _bucket = null;
        _role = null;
        _duration = null;
        _series = [];
        _segments = [];
        _highlight = null;
      });
      _load();
    } else {
      setState(() {});
      if (selected != null &&
          !selected.busy &&
          selected.attempts != _completedAttempts) {
        _completedAttempts = selected.attempts;
        _load();
      }
    }
  }

  Future<void> _load() async {
    if (_source == null) return;
    final serial = ++_loadSerial;
    final now = widget.owner!.currentTime.toUtc();
    await widget.controller.load(
      QuotaHistoryFilter(
        sourceId: _source!,
        segmentId: _segment ?? '__unrecorded_current_segment__',
        bucketId: _bucket,
        role: _role,
        durationMinutes: _duration,
        fromUtc: now.subtract(Duration(days: _days)),
        toUtc: now,
        heatmapMetric: _metric,
      ),
    );
    if (!mounted || serial != _loadSerial) return;
    final p = widget.controller.projection;
    if (p == null) return;
    setState(() {
      _segments = p.availableSegmentIds;
      _series = p.availableSeries;
    });
    if (_bucket == null) {
      final available = _series
          .where((s) => s.segmentId == _segment)
          .firstOrNull;
      if (available != null) {
        _bucket = available.bucketId;
        _role = available.role;
        _duration = available.durationMinutes;
        await _load();
      }
    }
  }

  void _change(VoidCallback change) {
    setState(() {
      change();
      _highlight = null;
    });
    _load();
  }

  String _windowLabel(QuotaHistorySeries s) {
    final duration = switch (s.durationMinutes) {
      300 => AppCopy.of(context).text('history.fiveHours'),
      10080 => AppCopy.of(context).text('history.weekly'),
      null => AppCopy.of(context).text('history.unknownDuration'),
      final n => AppCopy.of(
        context,
      ).text('history.minutes', args: {'count': n}),
    };
    return '$duration · ${s.role.name}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      if (_source == null) {
        return Text(AppCopy.of(context).text('history.addFirst'));
      }
      final c = widget.controller, p = c.projection;
      final series = _series.where((s) => s.segmentId == _segment).toList();
      final buckets = series.map((s) => s.bucketId).toSet();
      final windows = series.where((s) => s.bucketId == _bucket).toList();
      Widget choice(
        String key,
        String label,
        String value,
        Map<String, String> items,
        ValueChanged<String> change,
      ) => SizedBox(
        width: 210,
        child: MonitorChoice(
          key: ValueKey(key),
          label: label,
          value: value,
          items: items,
          onChanged: change,
        ),
      );
      final range = c.filter == null
          ? ''
          : '${historyDate(c.filter!.fromUtc)}–${historyDate(c.filter!.toUtc)}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 14,
            children: [
              choice(
                'history-bucket',
                AppCopy.of(context).text('history.bucket'),
                _bucket ?? '',
                {for (final b in buckets) b: b},
                (v) => _change(() {
                  _bucket = v;
                  final s = series.firstWhere((s) => s.bucketId == v);
                  _role = s.role;
                  _duration = s.durationMinutes;
                }),
              ),
              choice(
                'history-window',
                AppCopy.of(context).text('history.window'),
                '${_role?.name}:$_duration',
                {
                  for (final s in windows)
                    _windowLabel(s): '${s.role.name}:${s.durationMinutes}',
                },
                (v) => _change(() {
                  final s = windows.firstWhere(
                    (s) => '${s.role.name}:${s.durationMinutes}' == v,
                  );
                  _role = s.role;
                  _duration = s.durationMinutes;
                }),
              ),
              choice(
                'history-range',
                AppCopy.of(context).text('history.time'),
                '$_days',
                {
                  AppCopy.of(context).text('history.day'): '1',
                  AppCopy.of(context).text('history.week'): '7',
                  AppCopy.of(context).text('history.month'): '30',
                },
                (v) => _change(() => _days = int.parse(v)),
              ),
              choice(
                'history-segment',
                AppCopy.of(context).text('history.segment'),
                _segment ?? '__current__',
                {
                  AppCopy.of(context).text('history.currentSegment'):
                      _current ?? '__current__',
                  for (var i = 0; i < _segments.length; i++)
                    if (_segments[i] != _current)
                      AppCopy.of(context).text(
                        'history.oldSegment',
                        args: {'index': i + 1, 'range': range},
                      ): _segments[i],
                },
                (v) => _change(() {
                  _segment = v == '__current__' ? null : v;
                  _bucket = null;
                  _role = null;
                  _duration = null;
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                AppCopy.of(context)
                    .text('history.localRange', args: {'range': range}),
              ),
              FButton(
                key: const ValueKey('history-reload'),
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.outline,
                onPress: _load,
                child: Text(AppCopy.of(context).text('history.reload')),
              ),
            ],
          ),
          if (widget.owner?.historyError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _historyStorageError(context, widget.owner!.historyError!),
              ),
            ),
          if (c.hasStorageGaps)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(AppCopy.of(context).text('history.storageGaps')),
            ),
          const SizedBox(height: 16),
          if (c.isLoading)
            Text(AppCopy.of(context).text('history.loading'))
          else if (c.error != null)
            Text(AppCopy.of(context).text('history.readError'))
          else if (p != null && p.requiresSelection && p.events.isNotEmpty)
            Text(AppCopy.of(context).text('history.noWindow'))
          else if (p == null || p.sampleCount == 0)
            Text(
              _segment == _current
                  ? AppCopy.of(context).text('history.emptyCurrent')
                  : AppCopy.of(context).text('history.emptyRange'),
            ),
          if (p != null && !c.isLoading) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                _stat(
                  AppCopy.of(context).text('history.latestRemaining'),
                  _percent(p.latestPoint?.remainingPercent),
                ),
                _stat(
                  AppCopy.of(context).text('history.remainingRange'),
                  '${_percent(p.minimumRemaining)} – ${_percent(p.maximumRemaining)}',
                ),
                _stat(
                  AppCopy.of(context).text('history.sampleCount'),
                  '${p.sampleCount}',
                ),
                _stat(
                  AppCopy.of(context).text('history.lastSuccess'),
                  historyTime(p.lastObservedUtc, copy: AppCopy.of(context)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            MonitorChartFrame(
              key: const ValueKey('quota-history-trend'),
              title: AppCopy.of(context).text(
                'history.trendTitle',
                args: {
                  'view': AppCopy.of(context)
                      .text(_used ? 'accounts.used' : 'accounts.remaining'),
                },
              ),
              icon: FLucideIcons.chartLine,
              controls: [
                MonitorChoice(
                  label: AppCopy.of(context).text('history.readout'),
                  value: _used ? 'used' : 'remaining',
                  items: {
                    AppCopy.of(context).text('accounts.remaining'): 'remaining',
                    AppCopy.of(context).text('accounts.used'): 'used',
                  },
                  onChanged: (v) => setState(() => _used = v == 'used'),
                ),
              ],
              footnotes: [
                AppCopy.of(context).text(
                  'history.segmentSamples',
                  args: {
                    'first': historyTime(
                      p.firstObservedUtc,
                      copy: AppCopy.of(context),
                    ),
                    'last': historyTime(
                      p.lastObservedUtc,
                      copy: AppCopy.of(context),
                    ),
                  },
                ),
                if (p.actualFromUtc != p.firstObservedUtc ||
                    p.actualToUtc != p.lastObservedUtc)
                  AppCopy.of(context).text(
                    'history.readableRecords',
                    args: {
                      'first': historyTime(
                        p.actualFromUtc,
                        copy: AppCopy.of(context),
                      ),
                      'last': historyTime(
                        p.actualToUtc,
                        copy: AppCopy.of(context),
                      ),
                    },
                  ),
              ],
              child: QuotaHistoryTrendChart(
                projection: p,
                filter: c.filter!,
                used: _used,
                highlightedInterval: _highlight,
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final heatmap = MonitorChartFrame(
                  key: const ValueKey('quota-history-heatmap'),
                  title: AppCopy.of(context).text('history.heatmapTitle'),
                  icon: FLucideIcons.grid2X2,
                  controls: [
                    MonitorChoice(
                      label: AppCopy.of(context).text('history.hourMetric'),
                      value: _metric.name,
                      items: {
                        AppCopy.of(context).text('history.minimumRemaining'):
                            'minimumRemaining',
                        AppCopy.of(context).text('history.lastRemaining'):
                            'lastRemaining',
                      },
                      onChanged: (v) => _change(
                        () => _metric = QuotaHistoryHeatmapMetric.values.byName(
                          v,
                        ),
                      ),
                    ),
                  ],
                  footnotes: [
                    AppCopy.of(context).text('history.heatmapLegend'),
                    AppCopy.of(context).text('history.heatmapBoundary'),
                  ],
                  child: QuotaHistoryHeatmap(cells: p.hourCells),
                );
                final events = MonitorChartFrame(
                  key: const ValueKey('quota-history-events'),
                  title: AppCopy.of(context).text('history.eventsTitle'),
                  icon: FLucideIcons.list,
                  child: QuotaHistoryTimeline(
                    projection: p,
                    selected: _highlight,
                    onSelect: (interval) =>
                        setState(() => _highlight = interval),
                  ),
                );
                return constraints.maxWidth >= 1000
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: heatmap),
                          const SizedBox(width: 16),
                          Expanded(flex: 2, child: events),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [heatmap, const SizedBox(height: 16), events],
                      );
              },
            ),
          ],
        ],
      );
    },
  );
  String _percent(double? value) => value == null
      ? AppCopy.of(context).text('common.unknown')
      : '${inspectionNumber(value)}%';
  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}

String _historyStorageError(BuildContext context, String raw) => switch (raw) {
  '历史保存失败。' => AppCopy.of(context).text('history.writeError'),
  '历史本地清理失败。' => AppCopy.of(context).text('history.cleanupError'),
  _ => raw,
};
