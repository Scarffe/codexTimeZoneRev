import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/session_metrics_controller.dart';

class SessionMetricsPanel extends StatelessWidget {
  const SessionMetricsPanel({super.key, required this.controller});
  final SessionMetricsController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final last = controller.last;
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
                  label: const Text('选择主会话（时间 · 工作目录 · ID）'),
                  items: {
                    for (final s in controller.sessions)
                      '${s['timestamp']} · ${s['cwd']} · ${s['id']}':
                          s['path'] as String,
                  },
                  control: FSelectControl.lifted(
                    value: controller.selected,
                    onChange: controller.select,
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                controller.selected == null
                    ? '请选择会话；不会自动猜测当前对话。仅显示最近 100 个本地主会话。'
                    : controller.summary,
              ),
              if (controller.selected != null) ...[
                const SizedBox(height: 8),
                Text(
                  '输出：${last?['outputTokens'] ?? '不可用'} tokens · 推理：${last?['reasoningTokens'] ?? '不可用'} tokens',
                ),
                Text(
                  '完整回合：${ms('durationMs')} · 首模型 token：${ms('firstTokenMs')}',
                ),
                const Text(
                  '首模型 token 可能属于推理；推理 token 单列，不与输出重复相加。统计为日志尽力提供的观测值。',
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
