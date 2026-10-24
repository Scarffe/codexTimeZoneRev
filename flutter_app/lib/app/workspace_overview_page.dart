import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../services/session_attention.dart';
import '../state/session_metrics_controller.dart';
import '../state/session_attention_controller.dart';
import 'workspace_shell.dart';
import 'monitor_information.dart';
import '../services/monitoring_guide.dart';

class WorkspaceOverviewPage extends StatelessWidget {
  const WorkspaceOverviewPage({
    super.key,
    required this.usage,
    required this.metrics,
    required this.attention,
    required this.onSelect,
    required this.recentNotice,
  });
  final AccountUsageController usage;
  final SessionMetricsController metrics;
  final SessionAttentionController attention;
  final ValueChanged<WorkspaceDestination> onSelect;
  final String recentNotice;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey('overview-scroll'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('各来源独立更新；切换工作区不会发起查询或启动任务。'),
        const SizedBox(height: 16),
        for (final (destination, detail) in [
          (
            WorkspaceDestination.accounts,
            '账号来源 ${usage.sources?.states.length ?? 1} · ${usage.monitoring ? '自动刷新中' : '自动刷新关闭'}',
          ),
          (
            WorkspaceDestination.sessions,
            '关注 ${attention.watches.length}/8 · 未读 ${attention.unreadCount}',
          ),
          (
            WorkspaceDestination.analysis,
            '本地日志：${metrics.selected == null ? '未选择' : metrics.stateLabel} · 五类图表',
          ),
          (WorkspaceDestination.benchmark, '独立测试请求 · 不使用会话日志作为 API 结果'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      destination.label,
                      style: context.theme.typography.display.sm,
                    ),
                    const SizedBox(height: 6),
                    Text(detail),
                    if (destination == WorkspaceDestination.accounts) ...[
                      Text('选中来源：${usage.sources?.selected?.alias ?? '默认来源'}'),
                      if (usage.data == null)
                        const Text('额度未知 · 尚无可用观测')
                      else ...[
                        for (final bucket in usage.data!.buckets)
                          for (final window in bucket.windows)
                            Text(
                              '${bucket.label} · ${window.label}剩余 ${_remaining(window.usedPercent)}',
                            ),
                        Text(
                          '${usage.busy
                              ? '刷新中'
                              : usage.stale
                              ? '上次观测'
                              : '最近观测'} · ${usage.data!.fetchedAt.toLocal()}',
                        ),
                        if (usage.error != null)
                          const Text('最近刷新失败 · 缓存未变为新读数'),
                      ],
                    ],
                    if (destination == WorkspaceDestination.sessions)
                      Text(
                        '进行中 ${_count(SessionAttentionStatus.running)} · 已完成 ${_count(SessionAttentionStatus.completed)} · 已取消 ${_count(SessionAttentionStatus.cancelled)} · 未知 ${_count(SessionAttentionStatus.unknown)}',
                      ),
                    const SizedBox(height: 8),
                    FButton(
                      key: ValueKey('overview-${destination.name}'),
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => onSelect(destination),
                      child: const Text('打开'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FButton(
              key: const ValueKey('recent-monitor-notice'),
              variant: FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => showMonitorInformation(
                context,
                title: '系统提醒记录',
                builder: (_) =>
                    Text(recentNotice.isEmpty ? '暂无提醒。' : recentNotice),
              ),
              child: const Text('系统提醒记录'),
            ),
            FButton(
              key: const ValueKey('monitor-local-guide'),
              variant: FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () async {
                try {
                  await openMonitoringGuide();
                } catch (error) {
                  if (context.mounted) {
                    await showMonitorInformation(
                      context,
                      title: '本地监控说明',
                      builder: (_) => Text('无法打开本地说明：$error'),
                    );
                  }
                }
              },
              child: const Text('监控说明'),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    ),
  );
  int _count(SessionAttentionStatus status) => attention.items
      .where((item) => item.watch.enabled && item.status == status)
      .length;
  String _remaining(double? used) =>
      used == null || !used.isFinite || used < 0 || used > 100
      ? '未知'
      : '${(100 - used).toStringAsFixed(2)}%';
}
