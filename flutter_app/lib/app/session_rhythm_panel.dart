import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_rhythm.dart';
import '../state/session_rhythm_controller.dart';
import 'monitor_charts.dart';
import 'session_rhythm_charts.dart';

/// An explicit historical reference, independent of attention/notification state.
class RhythmAnalysisContext {
  const RhythmAnalysisContext(this.source, this.turn);
  final RhythmSource source;
  final RhythmTurn turn;
}

class SessionRhythmPanel extends StatefulWidget {
  const SessionRhythmPanel({
    super.key,
    required this.controller,
    this.available = const [],
    this.listing = false,
    this.listError,
    required this.onList,
    required this.onOpen,
  });
  final SessionRhythmController controller;
  final List<Map<String, dynamic>> available;
  final bool listing;
  final String? listError;
  final VoidCallback onList;
  final ValueChanged<RhythmAnalysisContext> onOpen;
  @override
  State<SessionRhythmPanel> createState() => _SessionRhythmPanelState();
}

class _SessionRhythmPanelState extends State<SessionRhythmPanel> {
  String choice = '';
  RhythmAnalysisContext? selected;
  bool showSources = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, p = c.projection;
      final available = [
        for (final s in widget.available)
          if (s['path'] is String && s['id'] is String)
            RhythmSource(
              path: s['path'] as String,
              sessionId: s['id'] as String,
              title: (s['title'] as String?) ?? '会话 ${s['id']}',
            ),
      ];
      final candidate = available.where((s) => s.key == choice).firstOrNull;
      final reference = selected;
      final current = reference == null
          ? null
          : c.turns
                .where(
                  (t) =>
                      t.sourceKey == reference.source.key &&
                      t.turnId == reference.turn.turnId,
                )
                .firstOrNull;
      final summary = current == null
          ? null
          : RhythmAnalysisContext(reference!.source, current);
      final validSummary =
          summary != null &&
          c.sources.any((s) => s.key == summary.source.key) &&
          c.turns.any(
            (t) =>
                t.sourceKey == summary.source.key &&
                t.turnId == summary.turn.turnId,
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                mainAxisSize: MainAxisSize.min,
                key: const ValueKey('rhythm-sources'),
                variant: FButtonVariant.outline,
                onPress: () => setState(() => showSources = !showSources),
                child: Text('来源 ${c.sources.length}/8'),
              ),
              FButton(
                mainAxisSize: MainAxisSize.min,
                key: const ValueKey('rhythm-refresh'),
                variant: FButtonVariant.outline,
                onPress: c.busy || c.sources.isEmpty ? null : () => c.refresh(),
                child: const Text('重读本地日志'),
              ),
              if (c.busy)
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: c.cancel,
                  child: const Text('取消读取'),
                ),
              SizedBox(
                width: 170,
                child: MonitorChoice(
                  label: '统计范围',
                  value: c.range.name,
                  items: const {
                    '近 24 小时': 'hours24',
                    '近 7 天': 'days7',
                    '近 30 天': 'days30',
                  },
                  onChanged: (v) {
                    setState(() => selected = null);
                    c.setRange(RhythmRange.values.byName(v));
                  },
                ),
              ),
              if (c.selectedHour != null)
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  key: const ValueKey('rhythm-clear-hour'),
                  variant: FButtonVariant.outline,
                  onPress: c.clearHour,
                  child: const Text('清除小时筛选'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!c.cacheReady) const Text('正在恢复缓存…'),
          Text(
            '完成 ${p.completedCount} · 取消 ${p.cancelledCount} · 样本 ${p.distribution.count} · 已记录活动 ${rhythmSeconds(p.activityMs)}',
          ),
          Text(
            '${c.cacheStale ? '缓存待重读 · ' : ''}时间未知 ${p.unknownTimeCount} · 部分 ${p.partialCount}${p.truncated ? ' · 已截断' : ''}',
          ),
          if (c.lastRead != null)
            Text('上次读取 ${c.lastRead!.toLocal().toString().split('.').first}'),
          if (c.selectedHour != null) Text('小时筛选：${c.selectedHour!.label}'),
          if (c.error != null) Text('读取错误：${c.error}'),
          if (c.storageError != null) Text('缓存错误：${c.storageError}'),
          if (showSources || c.sources.isEmpty) ...[
            const SizedBox(height: 8),
            FButton(
              mainAxisSize: MainAxisSize.min,
              key: const ValueKey('rhythm-list'),
              variant: FButtonVariant.outline,
              onPress: widget.listing ? null : widget.onList,
              child: Text(widget.listing ? '正在列出…' : '列出可用本地会话'),
            ),
            if (widget.listError != null) Text('来源列表：${widget.listError}'),
            if (available.isNotEmpty) ...[
              const SizedBox(height: 8),
              MonitorChoice(
                key: const ValueKey('rhythm-source-choice'),
                label: '明确选择来源',
                value: choice,
                items: {
                  for (final s in available)
                    '${s.title} · ${s.sessionId} · ${s.path}': s.key,
                },
                onChanged: (v) => setState(() => choice = v),
              ),
              FButton(
                mainAxisSize: MainAxisSize.min,
                key: const ValueKey('rhythm-add'),
                onPress:
                    !c.cacheReady ||
                        candidate == null ||
                        c.sources.any((s) => s.key == candidate.key) ||
                        c.sources.length >= 8
                    ? null
                    : () => c.addSource(candidate),
                child: const Text('加入来源'),
              ),
            ],
            for (final s in c.sources)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title),
                          Text('${s.sessionId} · ${s.path}'),
                          if (c.sourceErrors[s.key] != null)
                            Text('读取错误：${c.sourceErrors[s.key]}'),
                          if (c.lastReadMsBySource[s.key] != null)
                            Text(
                              '上次读取 ${DateTime.fromMillisecondsSinceEpoch(c.lastReadMsBySource[s.key]!)}',
                            ),
                        ],
                      ),
                    ),
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      key: ValueKey('rhythm-remove-${s.sessionId}'),
                      variant: FButtonVariant.ghost,
                      onPress: () => c.removeSource(s.key),
                      child: const Text('移除'),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          if (c.sources.isEmpty)
            const Text('明确加入来源后显示会话节奏')
          else ...[
            SessionRhythmCharts(
              projection: p,
              selectedHour: c.selectedHour,
              onHour: c.selectHour,
              onTurn: (s, t) =>
                  setState(() => selected = RhythmAnalysisContext(s, t)),
            ),
            const SizedBox(height: 12),
            if (validSummary)
              FCard(
                key: const ValueKey('rhythm-turn-summary'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${summary.source.title} · ${summary.turn.turnId}'),
                      Text(
                        '来源 ${summary.source.sessionId} · ${summary.source.path}',
                      ),
                      Text(
                        '状态 ${rhythmStatusLabel(summary.turn.status)} · 完整回合 ${rhythmSeconds(summary.turn.durationMs)} · 首模型 token ${rhythmSeconds(summary.turn.firstTokenMs)}',
                      ),
                      Text(
                        '活动${summary.turn.activityAvailable ? '已记录' : '未知'}${summary.turn.partial ? ' · 部分' : ''} · 时间精度 ${rhythmSeconds(summary.turn.timeResolutionMs)}',
                      ),
                      if (summary.turn.reasons.isNotEmpty)
                        Text(summary.turn.reasons.join(' · ')),
                      FButton(
                        mainAxisSize: MainAxisSize.min,
                        key: const ValueKey('rhythm-open-source'),
                        variant: FButtonVariant.outline,
                        onPress: () => widget.onOpen(summary),
                        child: const Text('打开来源分析'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      );
    },
  );
}
