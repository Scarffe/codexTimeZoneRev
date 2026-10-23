import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import '../state/session_metrics_controller.dart';
import 'account_usage_panel.dart';
import 'session_metrics_panel.dart';
import 'session_measurement_workspace.dart';
import 'monitor_presentation.dart';

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
    this.accountPanelKey,
    this.independentApiSelected,
  });
  final LauncherController launcher;
  final AccountUsageController usage;
  final SessionMetricsController metrics;
  final Key sessionPanelKey;
  final Key? accountPanelKey;
  final String recentNotice;
  final ValueNotifier<bool>? independentApiSelected;

  @override
  Widget build(BuildContext context) => SessionMeasurementWorkspace(
    independentApiSelected: independentApiSelected,
    currentSession: SingleChildScrollView(
      key: const PageStorageKey('monitor-scroll'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  Text(
                    '额度：${usage.monitoring ? '自动刷新中' : '自动刷新关闭'}',
                    style: context.theme.typography.body.sm,
                  ),
                  Text(
                    '会话：${metrics.selected == null ? '未选择' : metrics.stateLabel}',
                    style: context.theme.typography.body.sm,
                  ),
                ],
              ),
              MonitorDisclosure(
                label: recentNotice.isEmpty ? '最近提醒：暂无' : '最近提醒：有新提醒',
                toggleKey: const ValueKey('recent-monitor-notice'),
                child: Text(
                  '${recentNotice.isEmpty ? '暂无提醒。' : recentNotice}\n系统通知可能受勿扰设置影响。',
                  style: context.theme.typography.body.sm,
                ),
              ),
              const SizedBox(height: 12),
              AccountUsagePanel(
                key: accountPanelKey,
                controller: usage,
                launcher: launcher,
              ),
              const SizedBox(height: 20),
              SessionMetricsPanel(key: sessionPanelKey, controller: metrics),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    ),
  );
}
