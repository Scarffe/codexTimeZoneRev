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
      300 => '5 小时',
      10080 => '周额度',
      null => '时长未知',
      final n => '$n 分钟',
    };
    return '$duration · ${s.role.name}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      if (_source == null) return const Text('添加来源后可查看额度历史');
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
                '额度类型',
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
                '窗口',
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
              choice('history-range', '时间', '$_days', const {
                '24 小时': '1',
                '7 天': '7',
                '30 天': '30',
              }, (v) => _change(() => _days = int.parse(v))),
              choice(
                'history-segment',
                '登录分段',
                _segment ?? '__current__',
                {
                  '当前登录段': _current ?? '__current__',
                  for (var i = 0; i < _segments.length; i++)
                    if (_segments[i] != _current)
                      '旧段 ${i + 1} · 检索范围 $range': _segments[i],
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
              Text('本地观测 · $range'),
              FButton(
                key: const ValueKey('history-reload'),
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.outline,
                onPress: _load,
                child: const Text('重读本地历史'),
              ),
            ],
          ),
          if (widget.owner?.historyError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(widget.owner!.historyError!),
            ),
          if (c.hasStorageGaps)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('历史文件有缺失 · 已保留可读观测'),
            ),
          const SizedBox(height: 16),
          if (c.isLoading)
            const Text('读取本地历史…')
          else if (c.error != null)
            Text(c.error!)
          else if (p != null && p.requiresSelection && p.events.isNotEmpty)
            const Text('尚无已知窗口')
          else if (p == null || p.sampleCount == 0)
            Text(_segment == _current ? '当前登录段暂无观测' : '所选范围暂无有效观测'),
          if (p != null && !c.isLoading) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                _stat('范围内最新余量', _percent(p.latestPoint?.remainingPercent)),
                _stat(
                  '观测余量范围',
                  '${_percent(p.minimumRemaining)} – ${_percent(p.maximumRemaining)}',
                ),
                _stat('有效采样数', '${p.sampleCount}'),
                _stat('最近成功时间', historyTime(p.lastObservedUtc)),
              ],
            ),
            const SizedBox(height: 16),
            MonitorChartFrame(
              key: const ValueKey('quota-history-trend'),
              title: '额度趋势 · ${_used ? '已用' : '剩余'}',
              icon: FLucideIcons.chartLine,
              controls: [
                MonitorChoice(
                  label: '读数',
                  value: _used ? 'used' : 'remaining',
                  items: const {'剩余': 'remaining', '已用': 'used'},
                  onChanged: (v) => setState(() => _used = v == 'used'),
                ),
              ],
              footnotes: [
                '所选段有效采样：${historyTime(p.firstObservedUtc)} – ${historyTime(p.lastObservedUtc)}',
                if (p.actualFromUtc != p.firstObservedUtc ||
                    p.actualToUtc != p.lastObservedUtc)
                  '来源可读记录：${historyTime(p.actualFromUtc)} – ${historyTime(p.actualToUtc)}',
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
                  title: '日 × 小时 · 观测余量',
                  icon: FLucideIcons.grid2X2,
                  controls: [
                    MonitorChoice(
                      label: '小时指标',
                      value: _metric.name,
                      items: const {
                        '观测最低剩余': 'minimumRemaining',
                        '最后观测剩余': 'lastRemaining',
                      },
                      onChanged: (v) => _change(
                        () => _metric = QuotaHistoryHeatmapMetric.values.byName(
                          v,
                        ),
                      ),
                    ),
                  ],
                  footnotes: const [
                    '灰斜线：未知 · 红边 ×：失败 · 上沿虚线：缺口',
                    '仅总结已观测数据，非完整小时最低值',
                  ],
                  child: QuotaHistoryHeatmap(cells: p.hourCells),
                );
                final events = MonitorChartFrame(
                  key: const ValueKey('quota-history-events'),
                  title: '变化与查询异常',
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
  String _percent(double? value) =>
      value == null ? '未知' : '${inspectionNumber(value)}%';
  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}
