import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import '../state/session_metrics_controller.dart';
import 'account_usage_panel.dart';
import 'session_metrics_panel.dart';

/// Account quota and local session observations retain separate data sources.
/// Information hierarchy follows Win-CodexBar's ProviderGrid/MenuCard (MIT),
/// nesszer/Win-CodexBar @ 0eae1ea5c65c35bf184f116b41c131550b22d2cb.
/// Behavioral reference only; the Flutter implementation does not copy TSX.
class MonitoringPage extends StatelessWidget {
  const MonitoringPage({
    super.key,
    required this.launcher,
    required this.usage,
    required this.metrics,
    required this.sessionPanelKey,
    required this.recentNotice,
  });
  final LauncherController launcher;
  final AccountUsageController usage;
  final SessionMetricsController metrics;
  final Key sessionPanelKey;
  final String recentNotice;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey('monitor-scroll'),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FCard(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('监控概览', style: context.theme.typography.display.lg),
                    const SizedBox(height: 8),
                    Text(
                      '账号额度：${usage.monitoring ? '自动监控中' : '自动监控已关闭'} · ${usage.busy
                          ? '正在刷新'
                          : usage.data == null
                          ? '尚无查询结果'
                          : '已有查询结果'}',
                    ),
                    Text(
                      '本地会话：${metrics.selected == null ? '未选择会话' : metrics.stateLabel}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      recentNotice.isEmpty
                          ? '最近提醒：暂无。系统通知可能受勿扰设置影响。'
                          : '最近提醒：$recentNotice',
                      key: const ValueKey('recent-monitor-notice'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            AccountUsagePanel(controller: usage, launcher: launcher),
            const SizedBox(height: 20),
            SessionMetricsPanel(key: sessionPanelKey, controller: metrics),
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  );
}
