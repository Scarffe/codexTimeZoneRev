import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import '../state/session_metrics_controller.dart';
import '../services/session_attention.dart';
import 'account_usage_panel.dart';
import 'session_metrics_panel.dart';
import 'monitor_charts.dart';

/// Five display classes, with independent account and local-log source owners.
class MonitoringPage extends StatefulWidget {
  const MonitoringPage({
    super.key,
    required this.launcher,
    required this.usage,
    required this.metrics,
    this.sessionPanelKey,
    this.noticeContextKey,
    this.notice,
    this.onDismissNotice,
  });
  final LauncherController launcher;
  final AccountUsageController usage;
  final SessionMetricsController metrics;
  final Key? sessionPanelKey;
  final Key? noticeContextKey;
  final SessionAttentionNotice? notice;
  final VoidCallback? onDismissNotice;
  @override
  State<MonitoringPage> createState() => _MonitoringPageState();
}

class _MonitoringPageState extends State<MonitoringPage> {
  String _view = 'remaining';
  String? _bucket;
  Timer? _clock;
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = widget.usage;
    final owner = usage.sources;
    final buckets = usage.data?.buckets ?? [];
    final bucket =
        buckets.where((b) => b.id == _bucket).firstOrNull ??
        buckets.firstOrNull;
    final notice = widget.notice;
    final matchesNotice =
        notice != null &&
        widget.metrics.selected == notice.path &&
        widget.metrics.sourceInfo?['id'] == notice.sessionId;
    return SingleChildScrollView(
      key: const PageStorageKey('analysis-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notice != null)
            KeyedSubtree(
              key: widget.noticeContextKey,
              child: FCard(
                key: const ValueKey('notice-analysis-context'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('原提醒：${notice.title}'),
                      Text('会话 ${notice.sessionId} · 原回合 ${notice.turnId}'),
                      Text(notice.path),
                      Text(
                        !matchesNotice
                            ? '原来源尚未通过身份核验；不会替换为其他会话。'
                            : widget.metrics.last?['turnId'] == notice.turnId
                            ? '最近样本与原提醒回合一致。'
                            : '原提醒回合的完整样本不可用或已更新；下方显示此来源当前可用的观测。',
                      ),
                      FButton(
                        variant: FButtonVariant.ghost,
                        mainAxisSize: MainAxisSize.min,
                        onPress: widget.onDismissNotice,
                        child: const Text('关闭提醒上下文'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          FCard(
            key: const ValueKey('analysis-quota-card'),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '账号额度 · 独立来源',
                    style: context.theme.typography.display.sm,
                  ),
                  const Text('额度与本地日志不推断账号归属；各窗口百分比不相加。'),
                  const SizedBox(height: 12),
                  if (owner != null) ...[
                    MonitorChoice(
                      key: const ValueKey('analysis-account-source'),
                      label: '额度来源',
                      value: owner.selectedId,
                      items: {
                        for (final state in owner.states)
                          '${state.alias} · ${state.id}': state.id,
                      },
                      onChanged: owner.select,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (bucket != null)
                        MonitorChoice(
                          key: const ValueKey('analysis-quota-bucket'),
                          label: '额度类型',
                          value: bucket.id,
                          items: {for (final b in buckets) b.label: b.id},
                          onChanged: (value) => setState(() => _bucket = value),
                        ),
                      MonitorChoice(
                        key: const ValueKey('analysis-quota-view'),
                        label: '额度视图',
                        value: _view,
                        items: const {
                          '剩余': 'remaining',
                          '已用': 'used',
                          '距重置': 'reset',
                        },
                        onChanged: (value) => setState(() => _view = value),
                      ),
                    ],
                  ),
                  if (usage.error != null) Text('额度来源：${usage.error}'),
                  if (usage.data != null)
                    Text('最近额度观测：${usage.data!.fetchedAt.toLocal()}'),
                  if (bucket == null)
                    const Text('额度信息暂不可用 · 可在账号额度工作区查询')
                  else
                    AccountQuotaPresentation(
                      key: const ValueKey('account-quota-chart'),
                      bucket: bucket,
                      settings: widget.launcher.settings,
                      useLocalTime: usage.useLocalTime,
                      now: DateTime.now(),
                      view: _view,
                      inspectionIdentity: (
                        owner?.selectedId,
                        owner?.selected?.generation,
                        usage.data?.identity,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('本地会话日志 · 独立于账号额度与 API 测速'),
          SessionMetricsPanel(
            key: widget.sessionPanelKey,
            controller: widget.metrics,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
