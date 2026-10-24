import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_chart_data.dart';
import '../services/session_measurement_quality.dart';
import 'monitor_charts.dart';

/// Display-only assembly. Metric choices and collectors stay in the parent;
/// local state retains only the recent duration line/bar presentation.
class SessionChartPanels extends StatefulWidget {
  const SessionChartPanels({
    super.key,
    required this.data,
    required this.quality,
    required this.recentMetric,
    required this.recentRange,
    required this.configurationMetric,
    required this.activityView,
    required this.responseView,
    required this.onRecentMetric,
    required this.onRecentRange,
    required this.onConfigurationMetric,
    required this.onActivityView,
    required this.onResponseView,
    required this.completedIdentity,
    this.sessionIdentity,
  });
  final SessionChartData data;
  final SessionMeasurementQuality quality;
  final String recentMetric, configurationMetric, activityView, responseView;
  final int recentRange;
  final String? completedIdentity;
  final Object? sessionIdentity;
  final ValueChanged<String> onRecentMetric,
      onRecentRange,
      onConfigurationMetric,
      onActivityView,
      onResponseView;

  @override
  State<SessionChartPanels> createState() => _SessionChartPanelsState();
}

class _SessionChartPanelsState extends State<SessionChartPanels> {
  String _presentation = 'line';
  SessionChartData get data => widget.data;
  SessionMeasurementQuality get quality => widget.quality;
  String get recentMetric => widget.recentMetric;
  int get recentRange => widget.recentRange;
  String get configurationMetric => widget.configurationMetric;
  String get activityView => widget.activityView;
  String get responseView => widget.responseView;
  String? get completedIdentity => widget.completedIdentity;
  ValueChanged<String> get onRecentMetric => widget.onRecentMetric;
  ValueChanged<String> get onRecentRange => widget.onRecentRange;
  ValueChanged<String> get onConfigurationMetric =>
      widget.onConfigurationMetric;
  ValueChanged<String> get onActivityView => widget.onActivityView;
  ValueChanged<String> get onResponseView => widget.onResponseView;

  Widget _choice(
    String key,
    String label,
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged,
  ) => MonitorChoice(
    key: ValueKey(key),
    label: label,
    value: value,
    items: items,
    onChanged: onChanged,
  );

  Widget _empty() =>
      const SizedBox(height: 155, child: Center(child: Text('暂无样本')));

  Widget _recent(BuildContext context) {
    final rows = data.recentTerminals(recentRange);
    final status = recentMetric == 'status';
    return MonitorChartFrame(
      key: const ValueKey('session-recent-chart'),
      title: '最近回合',
      icon: FLucideIcons.chartColumn,
      controls: [
        _choice('session-recent-metric', '指标', recentMetric, const {
          '耗时': 'duration',
          '结束状态': 'status',
        }, onRecentMetric),
        if (!status)
          _choice('session-recent-presentation', '图形', _presentation, const {
            '折线': 'line',
            '柱形': 'bar',
          }, (value) => setState(() => _presentation = value)),
        _choice('session-recent-range', '回合范围', '$recentRange', const {
          '8 条': '8',
          '16 条': '16',
          '64 条': '64',
        }, onRecentRange),
      ],
      footnotes: [
        status ? '日志终结状态 · ${rows.length} 条' : '日志报告耗时 · × 取消 · 缺口为未知',
      ],
      child: rows.isEmpty
          ? _empty()
          : MonitorBarChart(
              inspectionIdentity: (
                widget.sessionIdentity,
                'recent',
                recentMetric,
                recentRange,
                _presentation,
              ),
              bars: status
                  ? [
                      ChartBar(
                        identity: 'completed',
                        label: '完成',
                        value: rows
                            .where((row) => !row.cancelled)
                            .length
                            .toDouble(),
                      ),
                      ChartBar(
                        identity: 'cancelled',
                        label: '取消',
                        value: rows
                            .where((row) => row.cancelled)
                            .length
                            .toDouble(),
                      ),
                    ]
                  : [
                      for (var i = 0; i < rows.length; i++)
                        ChartBar(
                          identity: rows[i].id,
                          label: '${i + 1}',
                          value: rows[i].cancelled
                              ? null
                              : rows[i].durationMs == null
                              ? null
                              : rows[i].durationMs! / 1000,
                          cancelled: rows[i].cancelled,
                          detail:
                              '回合 ${rows[i].id} · ${rows[i].cancelled ? '取消' : '完成'}',
                        ),
                    ],
              line: !status && _presentation == 'line',
              height: MediaQuery.sizeOf(context).width <= 620 ? 236 : 225,
              unit: status ? '回合' : 's',
              horizontal: status,
              integers: status,
              xLabel: status ? '结束状态 · 所选范围' : '回合顺序',
            ),
    );
  }

  Widget _configuration() {
    final rows = data.catchingUp
        ? <ConfigurationChartSample>[]
        : ConfigurationChartSample.fromQuality(quality);
    final unit = switch (configurationMetric) {
      'output' => 'tokens',
      'duration' => 's',
      'count' => '回合',
      _ => 'tokens/s',
    };
    return MonitorChartFrame(
      key: const ValueKey('session-configuration-chart'),
      title: '配置对比',
      icon: FLucideIcons.chartBar,
      controls: [
        _choice(
          'session-configuration-metric',
          '指标',
          configurationMetric,
          const {
            '回合均值': 'rate',
            '输出 token': 'output',
            '完整回合耗时': 'duration',
            '回合数': 'count',
          },
          onConfigurationMetric,
        ),
      ],
      footnotes: const ['已核验分组 · 会话 / 模型 / 推理强度 / 服务层级'],
      child: rows.isEmpty
          ? _empty()
          : MonitorBarChart(
              inspectionIdentity: (
                widget.sessionIdentity,
                'configuration',
                configurationMetric,
              ),
              bars: [
                for (final row in rows)
                  ChartBar(
                    identity: (row.model, row.effort, row.serviceTier),
                    label: row.label,
                    value: switch (configurationMetric) {
                      'output' => row.outputTokens.toDouble(),
                      'duration' => row.durationMs / 1000,
                      'count' => row.turnCount.toDouble(),
                      _ => row.tokensPerSecond,
                    },
                    detail: row.label,
                  ),
              ],
              unit: unit,
              horizontal: true,
              integers:
                  configurationMetric == 'count' ||
                  configurationMetric == 'output',
            ),
    );
  }

  Widget _activity() {
    Widget child;
    if (activityView == 'coverage') {
      final coverage = data.coverage;
      child = coverage == null
          ? const SizedBox(height: 155, child: Center(child: Text('覆盖不可核验')))
          : MonitorCoverageChart(
              inspectionIdentity: (
                widget.sessionIdentity,
                'activity',
                activityView,
                completedIdentity,
              ),
              observedMs: coverage.observedMs,
              unclassifiedMs: coverage.unclassifiedMs,
            );
    } else if (activityView == 'duration') {
      child = data.activities.isEmpty
          ? _empty()
          : MonitorBarChart(
              inspectionIdentity: (
                widget.sessionIdentity,
                'activity',
                activityView,
                completedIdentity,
              ),
              bars: [
                for (final row in data.activities)
                  ChartBar(
                    identity: row.category,
                    label: row.label,
                    value: row.milliseconds == null
                        ? null
                        : row.milliseconds! / 1000,
                  ),
              ],
              unit: 's',
              horizontal: true,
            );
    } else {
      child = !data.timeline.available || data.timeline.rows.isEmpty
          ? _empty()
          : MonitorIntervalChart(
              inspectionIdentity: (
                widget.sessionIdentity,
                'activity',
                activityView,
                completedIdentity,
              ),
              key: const ValueKey('session-timeline-chart'),
              data: data.timeline,
            );
    }
    return MonitorChartFrame(
      key: const ValueKey('session-activity-chart'),
      title: '上轮活动',
      icon: FLucideIcons.activity,
      controls: [
        _choice('session-activity-view', '视图', activityView, const {
          '区间': 'interval',
          '分类时长': 'duration',
          '覆盖': 'coverage',
        }, onActivityView),
      ],
      footnotes: [
        if (completedIdentity != null) '最近完成 · $completedIdentity',
        if (activityView == 'interval') '相对日志窗口 · 边界精度约 1 s',
        if (activityView == 'duration') '各类内部并集 · 类别可能重叠',
        if (activityView == 'coverage' && data.coverage != null) '近似日志覆盖',
        '未归类 ≠ 等待',
        if (data.timeline.sourcePartial) '部分日志',
        if (data.timeline.omittedItems > 0)
          '省略 ${data.timeline.omittedItems} 项',
      ],
      child: child,
    );
  }

  Widget _response(BuildContext context) {
    final composition = responseView == 'composition';
    final legend = switch (responseView) {
      'total' => '总输出 · 含推理',
      'reasoning' => '推理',
      _ => '非推理输出 + 推理',
    };
    return MonitorChartFrame(
      key: const ValueKey('session-response-chart'),
      title: '上轮响应 · 最近响应',
      icon: FLucideIcons.chartColumnStacked,
      controls: [
        _choice('session-response-view', '视图', responseView, const {
          '输出构成': 'composition',
          '总输出': 'total',
          '推理': 'reasoning',
        }, onResponseView),
      ],
      footnotes: [
        legend,
        if (completedIdentity != null) '最近完成 · $completedIdentity',
        data.usageMatchesTurn == true
            ? '用量一致 · 最近最多 12 条'
            : data.usageMatchesTurn == false
            ? '用量不一致 · 日志报告事实'
            : '不可核对 · 日志报告事实',
      ],
      child: data.responses.isEmpty
          ? _empty()
          : MonitorBarChart(
              inspectionIdentity: (
                widget.sessionIdentity,
                'response',
                responseView,
                completedIdentity,
              ),
              bars: [
                for (var i = 0; i < data.responses.length; i++)
                  ChartBar(
                    identity: data.responses[i].id,
                    label: '${i + 1}',
                    detail: '响应 ${data.responses[i].id}',
                    value: composition
                        ? (data.responses[i].nonReasoningTokens != null &&
                                  data.responses[i].reasoningTokens != null
                              ? data.responses[i].nonReasoningTokens!.toDouble()
                              : null)
                        : (responseView == 'total'
                                  ? data.responses[i].outputTokens
                                  : data.responses[i].reasoningTokens)
                              ?.toDouble(),
                    secondaryValue:
                        composition &&
                            data.responses[i].nonReasoningTokens != null
                        ? data.responses[i].reasoningTokens?.toDouble()
                        : null,
                  ),
              ],
              height: MediaQuery.sizeOf(context).width <= 620 ? 236 : 225,
              unit: 'tokens',
              integers: true,
              stacked: composition,
              xLabel: '响应顺序',
              primaryLabel: composition ? '非推理输出' : legend,
              secondaryLabel: '推理',
            ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = MediaQuery.sizeOf(context).width > 620
          ? (constraints.maxWidth - 12) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final panel in [
            _recent(context),
            _configuration(),
            _activity(),
            _response(context),
          ])
            SizedBox(width: width, child: panel),
        ],
      );
    },
  );
}
