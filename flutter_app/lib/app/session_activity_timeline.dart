import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_activity_timeline.dart';

/// The last completed turn's persisted item activity, never a live token chart.
class SessionActivityTimeline extends StatefulWidget {
  const SessionActivityTimeline({
    super.key,
    required this.data,
    required this.identity,
  });
  final SessionActivityTimelineData data;
  final Object? identity;
  @override
  State<SessionActivityTimeline> createState() =>
      _SessionActivityTimelineState();
}

class _SessionActivityTimelineState extends State<SessionActivityTimeline> {
  bool _expanded = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant SessionActivityTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _time(int? value) =>
      value == null ? '未知' : '${(value / 1000).toStringAsFixed(3)} s';

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (!data.available) return Text(data.reasonText);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text('最近完成的所选回合 · 日志区间 · 约 1 s 精度'),
        const Text('四类可重叠 · 阴影为近似边界'),
        if (data.sourcePartial) const Text('来源不完整：仅展示已记录事实'),
        if (data.spanMs != null) ...[
          const SizedBox(height: 8),
          _TimelineBands(data: data),
        ] else
          const Text('缺少可核验回合边界，仅列出文字事实，不绘制位置。'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            expanded: _expanded,
            child: FButton(
              key: const ValueKey('session-timeline-toggle'),
              mainAxisSize: MainAxisSize.min,
              variant: FButtonVariant.ghost,
              onPress: () => setState(() => _expanded = !_expanded),
              prefix: Icon(
                _expanded
                    ? FLucideIcons.chevronDown
                    : FLucideIcons.chevronRight,
              ),
              child: const Text('原始活动记录'),
            ),
          ),
        ),
        Offstage(
          offstage: !_expanded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(data.reasonText),
              const Text('四类可重叠，不能相加为回合阶段；空白不代表等待或网络耗时。'),
              if (data.omittedItems > 0)
                Text(
                  '按时间先后展示 ${data.rows.length} 项，省略 ${data.omittedItems} 项；汇总仍使用全部有效项。',
                ),
              if (data.coverageInterpretation == 'unavailable')
                const Text('覆盖范围无法解释：不计算空白占比，也不推断未显示区间的活动。'),
              if (data.spanMs != null)
                const Text('近似窗口与实际回合耗时不同；首尾阴影为边界不确定区（各至多 1.000 s）。'),
              const Text('对应文字记录（可滚动）：记录起止为 Unix epoch 毫秒；偏移相对于近似窗口；未绘制项保留原因。'),
              SizedBox(
                height: 210,
                child: ListView.builder(
                  key: const ValueKey('session-timeline-list'),
                  controller: _scroll,
                  itemCount: data.rows.length,
                  itemBuilder: (context, i) {
                    final row = data.rows[i];
                    final offset =
                        '偏移 ${_time(row.offsetStartMs)} → ${_time(row.offsetEndMs)}';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        '${row.label} · 记录开始：${row.startedAtMs ?? '未知'} · 记录结束：${row.completedAtMs ?? '未知'} · Unix epoch 毫秒\n'
                        '$offset · 项时长 ${_time(row.durationMs)}'
                        '${row.drawable ? '' : ' · 未绘制'}'
                        '${row.reasonText.isEmpty ? '' : ' · ${row.reasonText}'}',
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimelineBands extends StatelessWidget {
  const _TimelineBands({required this.data});
  final SessionActivityTimelineData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final span = data.spanMs!;
    final uncertainty = (data.boundsResolutionMs / span).clamp(0.0, 1.0);
    const categories = ['message', 'reasoning', 'tool', 'other'];
    const labels = ['消息', '推理', '工具', '其他'];
    // Labels and equivalent text records carry meaning independently of color.
    const accents = [
      Color(0xff3b82f6),
      Color(0xffa855f7),
      Color(0xff14b8a6),
      Color(0xfff59e0b),
    ];
    return Semantics(
      label: '四类日志项近似时间轴，活动可重叠；详见下方对应文字记录',
      child: Column(
        key: const ValueKey('session-timeline-chart'),
        children: [
          for (var c = 0; c < categories.length; c++)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                children: [
                  SizedBox(width: 66, child: Text('${labels[c]} 项')),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        return SizedBox(
                          height: 30,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.muted.withValues(alpha: 0.45),
                              border: Border.all(color: colors.border),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: ClipRect(
                              child: Stack(
                                children: [
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: width * uncertainty,
                                    child: ColoredBox(
                                      color: colors.foreground.withValues(
                                        alpha: 0.15,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: width * uncertainty,
                                    child: ColoredBox(
                                      color: colors.foreground.withValues(
                                        alpha: 0.15,
                                      ),
                                    ),
                                  ),
                                  for (final row in data.rows.where(
                                    (r) =>
                                        r.category == categories[c] &&
                                        r.drawable,
                                  ))
                                    Positioned(
                                      left: width * row.offsetStartMs! / span,
                                      width:
                                          width *
                                          (row.offsetEndMs! -
                                              row.offsetStartMs!) /
                                          span,
                                      top: 4 + (row.ordinal % 3) * 6,
                                      height: 8,
                                      child: Semantics(
                                        label: row.label,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: accents[c].withValues(
                                              alpha: 0.8,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 66),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                const Text('0.000 s'),
                Text('${(span / 1000).toStringAsFixed(3)} s · 近似窗口'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
