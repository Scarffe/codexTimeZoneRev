import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import '../state/session_metrics_controller.dart';
import '../services/monitoring_guide.dart';
import 'account_usage_panel.dart';
import 'account_sources_panel.dart';
import 'session_metrics_panel.dart';
import 'session_measurement_workspace.dart';
import 'monitor_presentation.dart';
import 'monitor_information.dart';
import '../state/benchmark_controller.dart';
import 'independent_benchmark_panel.dart';

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
    this.benchmark,
  });
  final LauncherController launcher;
  final AccountUsageController usage;
  final SessionMetricsController metrics;
  final Key sessionPanelKey;
  final Key? accountPanelKey;
  final String recentNotice;
  final ValueNotifier<bool>? independentApiSelected;
  final BenchmarkController? benchmark;

  @override
  Widget build(BuildContext context) => SessionMeasurementWorkspace(
    independentApiSelected: independentApiSelected,
    independentApi: benchmark?.enabled == true
        ? IndependentBenchmarkPanel(controller: benchmark!)
        : null,
    currentSession: SingleChildScrollView(
      key: const PageStorageKey('monitor-scroll'),
      child: Center(
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '额度：${usage.monitoring ? '自动刷新中' : '自动刷新关闭'}',
                    style: context.theme.typography.body.sm,
                  ),
                  Text(
                    '会话：${metrics.selected == null ? '未选择' : metrics.stateLabel}',
                    style: context.theme.typography.body.sm,
                  ),
                  if (recentNotice.isNotEmpty) const Text('最近提醒：有新提醒'),
                  MonitorIconAction(
                    key: const ValueKey('recent-monitor-notice'),
                    label: '查看历史提醒',
                    icon: FLucideIcons.bell,
                    onPress: () => showMonitorInformation(
                      context,
                      title: '历史提醒',
                      builder: (_) =>
                          Text(recentNotice.isEmpty ? '暂无提醒。' : recentNotice),
                    ),
                  ),
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.ghost,
                    key: const ValueKey('monitor-local-guide'),
                    prefix: const Icon(FLucideIcons.bookOpen, size: 16),
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
              const SizedBox(height: 12),
              if (usage.sources != null)
                AccountSourcesPanel(owner: usage.sources!),
              AccountUsagePanel(
                key: accountPanelKey,
                controller: usage,
                launcher: launcher,
              ),
              const SizedBox(height: 12),
              SessionMetricsPanel(key: sessionPanelKey, controller: metrics),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );
}
