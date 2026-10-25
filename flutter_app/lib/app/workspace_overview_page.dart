import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../services/session_attention.dart';
import '../state/session_metrics_controller.dart';
import '../state/session_attention_controller.dart';
import 'workspace_shell.dart';
import 'monitor_information.dart';
import 'dashboard_style.dart';
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
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context);
    final rate = metrics.verifiedTokensPerSecond;
    final cards = [
      _OverviewCard(
        destination: WorkspaceDestination.accounts,
        headline:
            '${usage.sources?.states.length ?? (usage.data == null ? 0 : 1)}',
        unit: '个独立来源',
        caption: usage.sources?.selected == null
            ? '尚未选择账号'
            : '已选 · ${usage.sources!.selected!.alias}',
        onOpen: onSelect,
        details: [
          if (usage.data == null)
            const Text('额度未知 · 尚无可用观测')
          else ...[
            for (final bucket in usage.data!.buckets)
              for (final window in bucket.windows)
                Text(
                  '${bucket.label} · ${window.label} · 剩余 ${_remaining(window.usedPercent)}',
                ),
            Text(
              '${usage.busy
                  ? '刷新中'
                  : usage.stale
                  ? '上次观测'
                  : '最近观测'} · ${_observedAt(usage.data!.fetchedAt)}',
              style: context.theme.typography.body.xs.copyWith(
                color: palette.muted,
              ),
            ),
            if (usage.error != null) const Text('刷新失败 · 数据未更新'),
          ],
        ],
      ),
      _OverviewCard(
        destination: WorkspaceDestination.sessions,
        headline: '${attention.unreadCount}',
        unit: '条未读事项',
        caption: '关注 ${attention.watches.length}/8 个会话',
        onOpen: onSelect,
        details: [
          Text(
            '进行中 ${_count(SessionAttentionStatus.running)} · 已完成 ${_count(SessionAttentionStatus.completed)}',
          ),
          Text(
            '已取消 ${_count(SessionAttentionStatus.cancelled)} · 未知 ${_count(SessionAttentionStatus.unknown)}',
            style: context.theme.typography.body.sm.copyWith(
              color: palette.muted,
            ),
          ),
        ],
      ),
      _OverviewCard(
        destination: WorkspaceDestination.analysis,
        headline: rate?.toStringAsFixed(2) ?? '—',
        unit: rate == null ? '暂无已核验样本' : 'tokens/s',
        caption: '最近完成回合 · 平均吞吐',
        onOpen: onSelect,
        details: [
          Text(metrics.selected == null ? '尚未选择本地日志' : metrics.stateLabel),
          Text(
            '额度、回合、配置、活动与响应',
            style: context.theme.typography.body.sm.copyWith(
              color: palette.muted,
            ),
          ),
        ],
      ),
      _OverviewCard(
        destination: WorkspaceDestination.benchmark,
        headline: '离线回放',
        unit: '独立来源',
        caption: 'Chat Completions / Responses',
        onOpen: onSelect,
        details: [
          const Text('用合成场景观察延迟与流式指标'),
          Text(
            '与当前会话统计分别记录',
            style: context.theme.typography.body.sm.copyWith(
              color: palette.muted,
            ),
          ),
        ],
      ),
    ];
    return SingleChildScrollView(
      key: const PageStorageKey('overview-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Text(
              '从额度到回合，查看你关心的进展。',
              style: context.theme.typography.body.md.copyWith(
                color: palette.muted,
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final card in cards)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: card,
                      ),
                  ],
                );
              }
              return Column(
                children: [
                  for (var i = 0; i < cards.length; i += 2)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: cards[i]),
                            const SizedBox(width: 16),
                            Expanded(child: cards[i + 1]),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
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
  }

  int _count(SessionAttentionStatus status) => attention.items
      .where((item) => item.watch.enabled && item.status == status)
      .length;
  String _remaining(double? used) =>
      used == null || !used.isFinite || used < 0 || used > 100
      ? '未知'
      : '${(100 - used).toStringAsFixed(2)}%';

  String _observedAt(DateTime time) {
    final local = time.toLocal();
    return '${local.month}/${local.day} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.destination,
    required this.headline,
    required this.unit,
    required this.caption,
    required this.details,
    required this.onOpen,
  });
  final WorkspaceDestination destination;
  final String headline, unit, caption;
  final List<Widget> details;
  final ValueChanged<WorkspaceDestination> onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context);
    return FCard(
      key: ValueKey('overview-card-${destination.name}'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: palette.selected,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    destination.icon,
                    size: 19,
                    color: palette.controlAccent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    destination.label,
                    style: context.theme.typography.body.lg.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FButton(
                  key: ValueKey('overview-${destination.name}'),
                  semanticsLabel: '打开${destination.label}',
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => onOpen(destination),
                  suffix: const Icon(FLucideIcons.arrowUpRight, size: 16),
                  child: const Text('打开'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(
                  headline,
                  style: context.theme.typography.display.xl2.copyWith(
                    fontSize: 32,
                    height: 1.15,
                    letterSpacing: -.6,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    unit,
                    style: context.theme.typography.body.sm.copyWith(
                      color: palette.muted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              caption,
              style: context.theme.typography.body.sm.copyWith(
                color: palette.muted,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Container(
                height: 1,
                color: palette.border.withValues(alpha: .55),
              ),
            ),
            ...details,
          ],
        ),
      ),
    );
  }
}
