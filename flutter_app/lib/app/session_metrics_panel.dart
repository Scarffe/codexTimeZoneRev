import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/session_metrics_controller.dart';
import '../services/session_measurement_quality.dart';
import 'session_timing_panel.dart';

class SessionMetricsPanel extends StatelessWidget {
  const SessionMetricsPanel({super.key, required this.controller});
  final SessionMetricsController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final last = controller.last;
      final analysis = last?['analysis'] is Map<String, dynamic>
          ? last!['analysis'] as Map<String, dynamic>
          : null;
      final timeline = analysis?['timeline'];
      final turnIdentity = (
        controller.selected,
        controller.data?['logEpoch'],
        last?['turnId'] ??
            (
              timeline is Map ? timeline['startEpochMs'] : null,
              timeline is Map ? timeline['endEpochMsExclusive'] : null,
            ),
      );
      String ms(String key) => last?[key] is num
          ? '${((last![key] as num) / 1000).toStringAsFixed(3)} s'
          : '不可用';
      return FCard(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('会话回合统计', style: context.theme.typography.display.lg),
              const SizedBox(height: 8),
              Text(
                '会话状态：${controller.stateLabel}',
                key: const ValueKey('session-state'),
              ),
              const Text('只读本地日志；回合平均吞吐包含工具执行与等待，不代表模型解码速度。'),
              const SizedBox(height: 12),
              FButton(
                onPress: controller.listing ? null : controller.list,
                child: Text(controller.listing ? '正在列出…' : '刷新本机会话列表'),
              ),
              const SizedBox(height: 12),
              if (controller.sessions.isNotEmpty)
                FSelect<String>.search(
                  key: const ValueKey('session-selector'),
                  label: const Text('最近会话（日志写入时间 · 项目 · 会话）'),
                  items: {
                    for (final s in controller.sessions)
                      '${controller.activityLabel(s)} · ${s['cwd'] ?? '目录未知'} · ${controller.sessionName(s)} · ID ${s['id']} · ${s['path'] == controller.selectorValue ? controller.stateLabel : '未采集'}':
                          s['path'] as String,
                  },
                  control: FSelectControl.lifted(
                    value: controller.selectorValue,
                    onChange: controller.select,
                  ),
                ),
              if (controller.selected != null &&
                  controller.sessions.isNotEmpty &&
                  controller.selectorValue == null)
                const Text('当前采集会话不在最近列表中；仍继续采集，可选择其他会话。'),
              const SizedBox(height: 12),
              const Text('固定跟踪所选会话；列表按日志写入时间排序，不据此推断模型活动。无标题时使用会话 ID。'),
              if (controller.selected != null) ...[
                Text(
                  '来源项目：${controller.sourceInfo?['cwd'] ?? '未知（尚未成功读取）'}',
                  key: const ValueKey('session-source'),
                ),
                Text(
                  '会话：${controller.sourceInfo == null ? '等待核验' : controller.sessionName(controller.sourceInfo!)}',
                ),
                Text('日志：${controller.selected}'),
                Text(
                  '最近成功读取：${controller.lastRead?.toLocal().toString().split('.').first ?? '尚未成功读取'}',
                ),
              ],
              if (controller.listError != null)
                Text('列表刷新失败：${controller.listError}'),
              if (controller.selectionError != null)
                Text(controller.selectionError!),
              Text(
                controller.selected == null
                    ? '请选择会话；不会自动猜测当前对话。仅显示最近 100 个本地主会话。'
                    : controller.summary,
              ),
              if (controller.selected != null) ...[
                const SizedBox(height: 8),
                _MeasurementDetails(quality: controller.measurementQuality),
                Text(
                  '输出：${last?['outputTokens'] ?? '不可用'} tokens · 推理：${last?['reasoningTokens'] ?? '不可用'} tokens',
                ),
                Text(
                  '完整回合：${ms('durationMs')} · 首模型 token：${ms('firstTokenMs')}',
                ),
                const Text(
                  '首模型 token 可能属于推理；推理 token 单列，不与输出重复相加。统计为日志尽力提供的观测值。',
                ),
                if (controller.data?['catchingUp'] != true)
                  SessionTimingPanel(
                    analysis: analysis,
                    durationMs: last?['durationMs'],
                    firstTokenMs: last?['firstTokenMs'],
                    turnIdentity: turnIdentity,
                  ),
                FButton(
                  variant: FButtonVariant.outline,
                  onPress: () => controller.select(null),
                  child: const Text('停止会话采集'),
                ),
              ],
              if (controller.error != null)
                Text(
                  controller.error!,
                  style: TextStyle(color: context.theme.colors.destructive),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _MeasurementDetails extends StatefulWidget {
  const _MeasurementDetails({required this.quality});
  final SessionMeasurementQuality quality;
  @override
  State<_MeasurementDetails> createState() => _MeasurementDetailsState();
}

class _MeasurementDetailsState extends State<_MeasurementDetails> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final quality = widget.quality;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('样本质量：${quality.label}', key: const ValueKey('session-quality')),
        for (final reason in quality.reasons) Text(reason),
        const SizedBox(height: 8),
        FButton(
          key: const ValueKey('session-measurement-details'),
          variant: FButtonVariant.outline,
          onPress: () => setState(() => expanded = !expanded),
          child: Text(expanded ? '收起统计来源与核验详情' : '查看统计来源与核验详情'),
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          Text('统计来源：${quality.sourceLabel}'),
          const Text('口径：回合输出 token ÷ 完整回合耗时。包含工具与等待；推理已包含在输出中时不重复相加。'),
          Text(
            '日志报告值 · 未充分核验：${quality.reportedTokensPerSecond?.toStringAsFixed(2) ?? '不可用'}${quality.reportedTokensPerSecond == null ? '' : ' tokens/s'}',
          ),
          const Text('已核验汇总按会话、模型、推理强度与服务层级分组，以总输出除以总耗时计算。'),
          if (quality.verifiedGroups.isEmpty) const Text('暂无可用的已核验分组'),
          for (final group in quality.verifiedGroups)
            Text(
              '会话 ${group['sessionId']} · ${group['model']} · ${group['effort']} · ${group['serviceTier']}：${group['turnCount']} 回合，${group['outputTokens']} tokens / ${((group['durationMs'] as num) / 1000).toStringAsFixed(3)} s = ${(group['tokensPerSecond'] as num).toStringAsFixed(2)} tokens/s',
            ),
        ],
      ],
    );
  }
}
