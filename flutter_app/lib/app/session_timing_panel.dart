import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_activity_timeline.dart';
import 'session_activity_timeline.dart';

/// Persisted item intervals describe client activity, not decoder execution.
class SessionTimingPanel extends StatefulWidget {
  const SessionTimingPanel({
    super.key,
    required this.analysis,
    this.durationMs,
    this.firstTokenMs,
    this.turnIdentity,
  });
  final Map<String, dynamic>? analysis;
  final Object? durationMs, firstTokenMs, turnIdentity;
  @override
  State<SessionTimingPanel> createState() => _SessionTimingPanelState();
}

class _SessionTimingPanelState extends State<SessionTimingPanel> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final validDuration = SessionActivityTimelineData.isSafeMilliseconds(
      widget.durationMs,
    );
    final validFirst =
        validDuration &&
        SessionActivityTimelineData.isSafeMilliseconds(widget.firstTokenMs) &&
        (widget.firstTokenMs as int) <= (widget.durationMs as int);
    String milliseconds(int value) => '${(value / 1000).toStringAsFixed(3)} s';
    String time(String key) => a?[key] is num
        ? '${((a![key] as num) / 1000).toStringAsFixed(3)} s'
        : '不可用';
    final match = a?['usageMatchesTurn'];
    final reconciliation = match == true
        ? '一致'
        : match == false
        ? '不一致'
        : '不可核对';
    final responses = (a?['recentResponses'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text('只读耗时分析 · 上轮', style: context.theme.typography.display.sm),
        Text(
          '首模型 token 等待：${validFirst ? milliseconds(widget.firstTokenMs as int) : '不可用'}',
          key: const ValueKey('session-first-model-wait'),
        ),
        Text(
          '首模型 token 后的回合耗时：${validFirst ? milliseconds((widget.durationMs as int) - (widget.firstTokenMs as int)) : '不可用'}',
          key: const ValueKey('session-after-first-duration'),
        ),
        const Text('首模型 token 可能属于推理，并不保证是可见正文；其后仍可包含工具、等待和其他活动，不代表纯生成时长。'),
        Text(
          '已记录响应：${a?['responseCount'] ?? '不可用'} 次 · 输出合计：${a?['responseOutputTokens'] ?? '不可用'} tokens · 与回合总数：$reconciliation',
        ),
        Text('消息项：${time('messageMs')} · 推理项：${time('reasoningMs')}'),
        Text('工具项：${time('toolMs')} · 其他项：${time('otherMs')}'),
        Text('活动区间合并：${time('observedMs')} · 类别间重叠：${time('overlapMs')}'),
        Text('未归类时间：${time('unclassifiedMs')}'),
        const Text('各类别内部已合并重叠，类别之间仍可能重叠，不能直接相加。未归类时间不等于模型生成或等待时间。'),
        if (a == null || a['partial'] == true)
          Text(
            '计时数据不完整或不可核验：缺失/倒序 ${a?['invalidItems'] ?? 0} 项，零时长 ${a?['zeroItems'] ?? 0} 项，越界 ${a?['outOfBoundsItems'] ?? 0} 项，缺少身份 ${a?['missingIdentityRecords'] ?? 0} 条${a?['truncated'] == true ? '，已达采集上限' : ''}。',
          ),
        const Text('时间来自日志项起止记录，回合边界仅秒级；尚无完整流式计时，模型生成速度不可用。'),
        SessionActivityTimeline(
          data: SessionActivityTimelineData.fromAnalysis(a),
          identity: widget.turnIdentity,
        ),
        if (responses.isNotEmpty) ...[
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => setState(() => expanded = !expanded),
            child: Text(expanded ? '收起响应用量' : '查看最近响应用量（最多 12 条）'),
          ),
          if (expanded)
            for (final response in responses)
              Text(
                '${response['responseId']} · 输出 ${response['outputTokens'] ?? '不可用'} · 推理 ${response['reasoningTokens'] ?? '不可用'} tokens',
              ),
        ],
      ],
    );
  }
}
