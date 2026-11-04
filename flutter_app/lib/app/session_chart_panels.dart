import '../l10n/copy_analysis.dart';
import '../l10n/app_copy.dart';

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

  Widget _empty() => SizedBox(
    height: 155,
    child: Center(child: Text(AppCopy.of(context).text('analysis.noSamples'))),
  );

  Widget _recent(BuildContext context) {
    final rows = data.recentTerminals(recentRange);
    final status = recentMetric == 'status';
    return MonitorChartFrame(
      key: const ValueKey('session-recent-chart'),
      responsiveControls: true,
      title: AppCopy.of(context).text('analysis.recentTurns'),
      icon: FLucideIcons.chartColumn,
      controls: [
        _choice(
          'session-recent-metric',
          AppCopy.of(context).text('analysis.metric'),
          recentMetric,
          {
            AppCopy.of(context).text('analysis.duration'): 'duration',
            AppCopy.of(context).text('analysis.terminalStatus'): 'status',
          },
          onRecentMetric,
        ),
        if (!status)
          _choice(
            'session-recent-presentation',
            AppCopy.of(context).text('analysis.chart'),
            _presentation,
            {
              AppCopy.of(context).text('analysis.line'): 'line',
              AppCopy.of(context).text('analysis.bars'): 'bar',
            },
            (value) => setState(() => _presentation = value),
          ),
        _choice(
          'session-recent-range',
          AppCopy.of(context).text('analysis.turnRange'),
          '$recentRange',
          {
            AppCopy.of(context).text('analysis.turns'): '8',
            AppCopy.of(context).text('analysis.turns2'): '16',
            AppCopy.of(context).text('analysis.turns3'): '64',
          },
          onRecentRange,
        ),
      ],
      footnotes: [
        status
            ? AppCopy.of(context).text(
                'analysis.loggedTerminalStatusTurns',
                args: {'p0': rows.length},
              )
            : AppCopy.of(context)
                  .text('analysis.logReportedDurationCancelledGapsAreUnknown'),
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
                        label: AppCopy.of(context).text('analysis.completed'),
                        value: rows
                            .where((row) => !row.cancelled)
                            .length
                            .toDouble(),
                      ),
                      ChartBar(
                        identity: 'cancelled',
                        label: AppCopy.of(context).text('analysis.cancelled'),
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
                          detail: AppCopy.of(context).text(
                            'analysis.turn',
                            args: {
                              'p0': rows[i].id,
                              'p1': rows[i].cancelled
                                  ? AppCopy.of(context)
                                        .text('analysis.cancelled')
                                  : AppCopy.of(context)
                                        .text('analysis.completed'),
                            },
                          ),
                        ),
                    ],
              line: !status && _presentation == 'line',
              height: MediaQuery.sizeOf(context).width <= 620 ? 236 : 225,
              unit: status ? AppCopy.of(context).text('analysis.turns4') : 's',
              horizontal: status,
              integers: status,
              xLabel: status
                  ? AppCopy.of(context)
                        .text('analysis.terminalStatusSelectedRange')
                  : AppCopy.of(context).text('analysis.turnOrder'),
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
      'count' => AppCopy.of(context).text('analysis.turns4'),
      _ => 'tokens/s',
    };
    return MonitorChartFrame(
      key: const ValueKey('session-configuration-chart'),
      responsiveControls: true,
      title: AppCopy.of(context).text('analysis.configurationComparison'),
      icon: FLucideIcons.chartBar,
      controls: [
        _choice(
          'session-configuration-metric',
          AppCopy.of(context).text('analysis.metric'),
          configurationMetric,
          {
            AppCopy.of(context).text('analysis.turnAverage'): 'rate',
            AppCopy.of(context).text('analysis.outputTokens'): 'output',
            AppCopy.of(context).text('analysis.completeTurnDuration'):
                'duration',
            AppCopy.of(context).text('analysis.turnCount'): 'count',
          },
          onConfigurationMetric,
        ),
      ],
      footnotes: [
        AppCopy.of(context)
            .text('analysis.verifiedGroupsSessionModelReasoningEffortService'),
      ],
      child: rows.isEmpty
          ? _empty()
          : MonitorCategoryDotChart(
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
                    detail: AppCopy.of(context).text(
                      'analysis.turnsGroupAggregate',
                      args: {'p0': row.label, 'p1': row.turnCount},
                    ),
                  ),
              ],
              unit: unit,
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
          ? SizedBox(
              height: 155,
              child: Center(
                child: Text(
                  AppCopy.of(context).text('analysis.coverageUnverifiable'),
                ),
              ),
            )
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
                    label: AppCopy.of(context)
                        .activityCategoryLabel(row.category),
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
      responsiveControls: true,
      title: AppCopy.of(context).text('analysis.lastTurnActivity'),
      icon: FLucideIcons.activity,
      controls: [
        _choice(
          'session-activity-view',
          AppCopy.of(context).text('analysis.view'),
          activityView,
          {
            AppCopy.of(context).text('analysis.intervals'): 'interval',
            AppCopy.of(context).text('analysis.categoryDuration'): 'duration',
            AppCopy.of(context).text('analysis.coverage'): 'coverage',
          },
          onActivityView,
        ),
      ],
      footnotes: [
        if (completedIdentity != null)
          AppCopy.of(
            context,
          ).text('analysis.recentlyCompleted', args: {'p0': completedIdentity}),
        if (activityView == 'interval')
          AppCopy.of(context)
              .text('analysis.relativeLogWindowBoundaryResolutionAboutS'),
        if (activityView == 'duration')
          AppCopy.of(context)
              .text('analysis.unionWithinEachCategoryCategoriesMayOverlap'),
        if (activityView == 'coverage' && data.coverage != null)
          AppCopy.of(context).text('analysis.approximateLogCoverage'),
        AppCopy.of(context).text('analysis.unclassifiedWaiting'),
        if (data.timeline.sourcePartial)
          AppCopy.of(context).text('analysis.partialLog'),
        if (data.timeline.omittedItems > 0)
          AppCopy.of(context).text(
            'analysis.itemsOmitted',
            args: {'p0': data.timeline.omittedItems},
          ),
      ],
      child: child,
    );
  }

  Widget _response(BuildContext context) {
    final composition = responseView == 'composition';
    final legend = switch (responseView) {
      'total' => AppCopy.of(
        context,
      ).text('analysis.totalOutputIncludesReasoning'),
      'reasoning' => AppCopy.of(context).text('analysis.reasoning'),
      _ => AppCopy.of(context).text('analysis.nonReasoningOutputReasoning'),
    };
    return MonitorChartFrame(
      key: const ValueKey('session-response-chart'),
      responsiveControls: true,
      title: AppCopy.of(context)
          .text('analysis.lastTurnResponsesRecentResponses'),
      icon: FLucideIcons.chartColumnStacked,
      controls: [
        _choice(
          'session-response-view',
          AppCopy.of(context).text('analysis.view'),
          responseView,
          {
            AppCopy.of(context).text('analysis.outputComposition'):
                'composition',
            AppCopy.of(context).text('analysis.totalOutput'): 'total',
            AppCopy.of(context).text('analysis.reasoning'): 'reasoning',
          },
          onResponseView,
        ),
      ],
      footnotes: [
        legend,
        if (completedIdentity != null)
          AppCopy.of(
            context,
          ).text('analysis.recentlyCompleted', args: {'p0': completedIdentity}),
        data.usageMatchesTurn == true
            ? AppCopy.of(context)
                  .text('analysis.usageMatchedUpToRecentResponses')
            : data.usageMatchesTurn == false
            ? AppCopy.of(context)
                  .text('analysis.usageMismatchedLogReportedFacts')
            : AppCopy.of(context)
                  .text('analysis.notVerifiableLogReportedFacts'),
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
                    detail: AppCopy.of(context).text(
                      'analysis.response',
                      args: {'p0': data.responses[i].id},
                    ),
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
              xLabel: AppCopy.of(context).text('analysis.responseOrder'),
              primaryLabel: composition
                  ? AppCopy.of(context).text('analysis.nonReasoningOutput')
                  : legend,
              secondaryLabel: AppCopy.of(context).text('analysis.reasoning'),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth >= 900
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
