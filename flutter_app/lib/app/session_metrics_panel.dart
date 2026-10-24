import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/session_metrics_controller.dart';
import '../services/session_activity_timeline.dart';
import '../services/session_chart_data.dart';
import '../services/session_measurement_quality.dart';
import 'monitor_information.dart';
import 'monitor_presentation.dart';
import 'session_chart_panels.dart';
import 'dashboard_style.dart';

class SessionMetricsPanel extends StatefulWidget {
  const SessionMetricsPanel({super.key, required this.controller});
  final SessionMetricsController controller;
  @override
  State<SessionMetricsPanel> createState() => _SessionMetricsPanelState();
}

class _SessionMetricsPanelState extends State<SessionMetricsPanel> {
  // One preference state per chart; data/identity changes never reset choices.
  ({String metric, int range}) _recent = (metric: 'duration', range: 16);
  String _configuration = 'rate',
      _activity = 'interval',
      _response = 'composition';
  SessionMetricsController get controller => widget.controller;
  String _short(Object? value, [int limit = 28]) {
    final text = (value ?? '未知').toString();
    return text.length > limit ? '${text.substring(0, limit - 1)}…' : text;
  }

  String _project(Object? value) => _short(
    value
        ?.toString()
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .lastOrNull,
    18,
  );
  Map<String, String> _choices() {
    final result = <String, String>{};
    for (final s in controller.sessions) {
      final id = (s['id'] ?? '').toString();
      final tag = id.length > 8 ? id.substring(id.length - 8) : id;
      final base =
          '${_short(controller.sessionName(s))} · ${_project(s['cwd'])} · $tag';
      var label = base;
      var suffix = 2;
      while (result.containsKey(label)) {
        label = '$base · ${suffix++}';
      }
      result[label] = s['path'] as String;
    }
    return result;
  }

  void _information() => showMonitorInformation(
    context,
    title: '会话信息',
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final info = controller.sourceInfo;
        final last = controller.error == null ? controller.last : null;
        final analysis = last?['analysis'] is Map<String, dynamic>
            ? last!['analysis'] as Map<String, dynamic>
            : null;
        final timeline = SessionActivityTimelineData.fromAnalysis(analysis);
        final quality = controller.measurementQuality;
        final selectedMetadata = controller.sessions
            .where((s) => s['path'] == controller.selectorValue)
            .firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MonitorInformationFact(
              label: '来源项目',
              value: '${info?['cwd'] ?? '未知（尚未成功读取）'}',
              copyable: info != null,
            ),
            MonitorInformationFact(
              label: '会话',
              value: info == null ? '等待核验' : controller.sessionName(info),
            ),
            MonitorInformationFact(
              label: '会话 ID',
              value: '${info?['id'] ?? '未知'}',
              copyable: info?['id'] != null,
            ),
            MonitorInformationFact(
              label: '日志',
              value: controller.selected ?? '未选择',
              copyable: controller.selected != null,
            ),
            MonitorInformationFact(
              label: '当前回合',
              value: '${controller.data?['current']?['turnId'] ?? '未知'}',
            ),
            MonitorInformationFact(
              label: '上轮身份',
              value: '${last?['turnId'] ?? '未知'}',
            ),
            MonitorInformationFact(
              label: '日志写入时间',
              value: controller.activityLabel(selectedMetadata ?? const {}),
            ),
            MonitorInformationFact(
              label: '最近成功读取',
              value:
                  controller.lastRead?.toLocal().toString().split('.').first ??
                  '尚未成功读取',
            ),
            MonitorInformationFact(label: '统计来源', value: quality.sourceLabel),
            for (final reason in quality.reasons) Text(reason),
            Text(
              '日志报告值 · 未充分核验：${quality.reportedTokensPerSecond?.toStringAsFixed(2) ?? '不可用'}${quality.reportedTokensPerSecond == null ? '' : ' tokens/s'}',
            ),
            if (controller.listError != null)
              MonitorInformationFact(
                label: '列表刷新失败',
                value: controller.listError!,
                copyable: true,
              ),
            if (controller.selectionError != null)
              MonitorInformationFact(
                label: '选择保存/恢复',
                value: controller.selectionError!,
                copyable: true,
              ),
            if (controller.error != null)
              MonitorInformationFact(
                label: '读取失败',
                value: controller.error!,
                copyable: true,
              ),
            for (final group in quality.verifiedGroups)
              Text(
                '会话 ${group['sessionId']} · ${group['model']} · ${group['effort']} · ${group['serviceTier']}：${group['turnCount']} 回合',
              ),
            if (analysis != null) ...[
              Text(
                '已记录响应：${analysis['responseCount'] ?? '不可用'} 次 · 输出合计：${analysis['responseOutputTokens'] ?? '不可用'} tokens · 与回合总数：${analysis['usageMatchesTurn'] == true
                    ? '一致'
                    : analysis['usageMatchesTurn'] == false
                    ? '不一致'
                    : '不可核对'}',
              ),
              Text('未归类时间：${_seconds(analysis['unclassifiedMs'])}'),
              for (final response in SessionChartData.fromData(
                controller.data,
              ).responses)
                Text(
                  '${response.id} · 输出 ${response.outputTokens ?? '不可用'} · 推理 ${response.reasoningTokens ?? '不可用'} tokens',
                ),
            ],
            if (!timeline.available) const Text('计时数据不完整或不可核验'),
            for (final row in timeline.rows.take(200))
              Text(
                '${row.label} · 偏移 ${row.offsetStartMs ?? '未知'} → ${row.offsetEndMs ?? '未知'} ms · ${row.drawable ? '可定位' : row.reasonText}\n记录开始：${row.startedAtMs ?? '未知'} · 记录结束：${row.completedAtMs ?? '未知'} · Unix epoch 毫秒',
              ),
            if (timeline.omittedItems > 0)
              Text('省略 ${timeline.omittedItems} 项'),
          ],
        );
      },
    ),
  );

  String _seconds(Object? value) =>
      SessionActivityTimelineData.isSafeMilliseconds(value)
      ? '${((value as int) / 1000).toStringAsFixed(3)} s'
      : '不可用';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final publish =
          controller.error == null && controller.data?['catchingUp'] != true;
      final last = publish ? controller.last : null;
      final quality = controller.measurementQuality;
      final charts = SessionChartData.fromData(
        publish ? controller.data : null,
      );
      final duration = last?['durationMs'], first = last?['firstTokenMs'];
      final validDuration = SessionActivityTimelineData.isSafeMilliseconds(
        duration,
      );
      final recordedFirst = SessionActivityTimelineData.isSafeMilliseconds(
        first,
      );
      final contradicts =
          recordedFirst && validDuration && (first as int) > (duration as int);
      final info = controller.sourceInfo;
      final completedIdentity = last?['turnId'] is String
          ? last!['turnId'] as String
          : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('会话回合统计', style: context.theme.typography.display.lg),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) => Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (controller.sessions.isNotEmpty)
                          SizedBox(
                            width: constraints.maxWidth > 650
                                ? 420
                                : constraints.maxWidth,
                            child: Semantics(
                              label: '最近会话',
                              child: FSelect<String>.search(
                                key: const ValueKey('session-selector'),

                                items: _choices(),
                                filter: (query) {
                                  final q = query.trim().toLowerCase();
                                  return controller.sessions
                                      .where(
                                        (s) => [
                                          controller.sessionName(s),
                                          s['cwd'],
                                          s['id'],
                                          s['path'],
                                        ].join(' ').toLowerCase().contains(q),
                                      )
                                      .map((s) => s['path'] as String);
                                },
                                control: FSelectControl.lifted(
                                  value: controller.selectorValue,
                                  onChange: controller.select,
                                ),
                              ),
                            ),
                          ),
                        MonitorIconAction(
                          key: const ValueKey('session-information'),
                          label: '会话信息与诊断',
                          icon: FLucideIcons.info,
                          onPress: _information,
                        ),
                        MonitorIconAction(
                          key: const ValueKey('session-refresh'),
                          label: controller.listing ? '正在列出会话' : '刷新本机会话列表',
                          icon: FLucideIcons.refreshCw,
                          onPress: controller.listing ? null : controller.list,
                        ),
                        if (controller.selected != null)
                          FButton(
                            mainAxisSize: MainAxisSize.min,
                            variant: FButtonVariant.ghost,
                            onPress: () => controller.select(null),
                            prefix: const Icon(FLucideIcons.square, size: 14),
                            child: const Text('停止会话采集'),
                          ),
                      ],
                    ),
                  ),
                  if (controller.selected != null &&
                      controller.selectorValue == null)
                    const Text('当前采集会话不在最近列表中；仍继续采集，可选择其他会话。'),
                  const SizedBox(height: 12),
                  DefaultTextStyle.merge(
                    style: context.theme.typography.body.sm.copyWith(
                      color: DashboardPalette.of(context).muted,
                    ),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Semantics(
                          key: controller.selected == null
                              ? null
                              : const ValueKey('session-short-identity'),
                          label: info == null
                              ? '会话身份等待核验'
                              : '${controller.sessionName(info)} · ${info['cwd'] ?? '未知项目'}',
                          child: Text(
                            '会话状态：${controller.stateLabel}',
                            key: const ValueKey('session-state'),
                          ),
                        ),
                        if (controller.selected != null) ...[
                          Text(
                            controller.data?['catchingUp'] == true
                                ? '正在读取历史 · 尚无可用最近完成回合'
                                : last == null
                                ? '最近完成 · 暂无样本'
                                : '最近完成 · 含工具与等待',
                            key: const ValueKey('session-completed-summary'),
                          ),
                          Text(
                            '样本质量：${quality.label}',
                            key: const ValueKey('session-quality'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (controller.listError != null)
                    const Text('列表刷新失败 · 信息中查看诊断'),
                  if (controller.selectionError != null)
                    Text(controller.selectionError!),
                  if (controller.error != null)
                    Text(
                      '会话读取失败 · 信息中查看诊断',
                      style: TextStyle(color: context.theme.colors.destructive),
                    ),
                  if (controller.selected == null)
                    const Text('请选择会话；不会自动猜测当前对话。')
                  else ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: DashboardPalette.of(context).soft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth >= 600
                              ? (constraints.maxWidth - 36) / 4
                              : (constraints.maxWidth >= 300
                                    ? (constraints.maxWidth - 12) / 2
                                    : constraints.maxWidth);
                          return Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              _Metric(
                                width: width,
                                label: '回合均值',
                                value:
                                    publish &&
                                        quality.verifiedTokensPerSecond != null
                                    ? '${quality.verifiedTokensPerSecond!.toStringAsFixed(2)} tokens/s'
                                    : '不可用',
                                valueKey: 'session-rate-value',
                              ),
                              _Metric(
                                width: width,
                                label: '输出 · 含推理',
                                value:
                                    last?['outputTokens'] is int &&
                                        (last!['outputTokens'] as int) >= 0 &&
                                        (last['outputTokens'] as int) <=
                                            9007199254740991
                                    ? '${last['outputTokens']} tokens'
                                    : '不可用',
                                valueKey: 'session-output-value',
                              ),
                              _Metric(
                                width: width,
                                label: '首模型 token 等待',
                                value: recordedFirst && !contradicts
                                    ? _seconds(first)
                                    : '不可用',
                                valueKey: 'session-first-token-value',
                                note: '可能含推理',
                              ),
                              _Metric(
                                width: width,
                                label: '完整回合',
                                value: validDuration
                                    ? _seconds(duration)
                                    : '不可用',
                                valueKey: 'session-duration-value',
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (contradicts) const Text('首模型 token 不可用：超过完整回合耗时'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SessionChartPanels(
            sessionIdentity: controller.selected,
            data: charts,
            quality: publish
                ? quality
                : SessionMeasurementQuality.fromData(null),
            completedIdentity: completedIdentity,
            recentMetric: _recent.metric,
            recentRange: _recent.range,
            configurationMetric: _configuration,
            activityView: _activity,
            responseView: _response,
            onRecentMetric: (value) =>
                setState(() => _recent = (metric: value, range: _recent.range)),
            onRecentRange: (value) => setState(
              () => _recent = (metric: _recent.metric, range: int.parse(value)),
            ),
            onConfigurationMetric: (value) =>
                setState(() => _configuration = value),
            onActivityView: (value) => setState(() => _activity = value),
            onResponseView: (value) => setState(() => _response = value),
          ),
        ],
      );
    },
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.width,
    required this.label,
    required this.value,
    required this.valueKey,
    this.note,
  });
  final double width;
  final String label, value, valueKey;
  final String? note;
  @override
  Widget build(BuildContext context) {
    final secondary = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final boundary = value.lastIndexOf(' ');
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: secondary),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: boundary < 0 ? value : value.substring(0, boundary),
                  style: context.theme.typography.body.md.copyWith(
                    fontSize: 24,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (boundary >= 0)
                  TextSpan(text: value.substring(boundary), style: secondary),
              ],
            ),
            key: ValueKey(valueKey),
          ),
          if (note != null) Text(note!, style: secondary),
        ],
      ),
    );
  }
}
