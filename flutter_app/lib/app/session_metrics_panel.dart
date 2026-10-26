import '../l10n/copy_analysis.dart';
import '../l10n/app_copy.dart';

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
    final text = (value ?? AppCopy.of(context).text('analysis.unknown'))
        .toString();
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
          '${_short(AppCopy.of(context).sessionTitle(s))} · ${_project(s['cwd'])} · $tag';
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
    title: AppCopy.of(context).text('analysis.sessionInformation'),
    titleKey: 'analysis.sessionInformation',
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
              label: AppCopy.of(context).text('analysis.sourceProject'),
              value:
                  '${info?['cwd'] ?? AppCopy.of(context).text('analysis.unknownNoSuccessfulRead')}',
              copyable: info != null,
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.session'),
              value: info == null
                  ? AppCopy.of(context).text('analysis.awaitingVerification')
                  : AppCopy.of(context).sessionTitle(info),
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.sessionID'),
              value:
                  '${info?['id'] ?? AppCopy.of(context).text('analysis.unknown')}',
              copyable: info?['id'] != null,
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.log'),
              value:
                  controller.selected ??
                  AppCopy.of(context).text('analysis.notSelected'),
              copyable: controller.selected != null,
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.currentTurn'),
              value:
                  '${controller.data?['current']?['turnId'] ?? AppCopy.of(context).text('analysis.unknown')}',
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.lastTurnIdentity'),
              value:
                  '${last?['turnId'] ?? AppCopy.of(context).text('analysis.unknown')}',
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.logWriteTime'),
              value: AppCopy.of(context)
                  .sessionActivityLabel(selectedMetadata ?? const {}),
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.lastSuccessfulRead'),
              value:
                  (AppCopy.of(context).isEnglish && controller.lastRead != null
                      ? AppCopy.of(context)
                            .dateTime(controller.lastRead, includeSeconds: true)
                      : controller.lastRead
                            ?.toLocal()
                            .toString()
                            .split('.')
                            .first) ??
                  AppCopy.of(context).text('analysis.noSuccessfulRead'),
            ),
            MonitorInformationFact(
              label: AppCopy.of(context).text('analysis.measurementSource'),
              value: AppCopy.of(context).sessionSourceLabel(quality),
            ),
            for (final reason in AppCopy.of(
              context,
            ).sessionQualityReasons(quality, controller.data))
              Text(reason),
            Text(
              AppCopy.of(context).text(
                'analysis.logReportedValueNotFullyVerified',
                args: {
                  'p0':
                      quality.reportedTokensPerSecond?.toStringAsFixed(2) ??
                      AppCopy.of(context).text('analysis.unavailable'),
                  'p1': quality.reportedTokensPerSecond == null
                      ? ''
                      : ' tokens/s',
                },
              ),
            ),
            if (controller.listError != null)
              MonitorInformationFact(
                label: AppCopy.of(context).text('analysis.listRefreshFailed'),
                value: AppCopy.of(context)
                    .sessionDiagnostic(controller.listError!),
                copyable: true,
              ),
            if (controller.selectionError != null)
              MonitorInformationFact(
                label: AppCopy.of(context)
                    .text('analysis.selectionSaveRestore'),
                value: AppCopy.of(context)
                    .sessionDiagnostic(controller.selectionError!),
                copyable: true,
              ),
            if (controller.error != null)
              MonitorInformationFact(
                label: AppCopy.of(context).text('analysis.readFailed'),
                value: AppCopy.of(context).sessionDiagnostic(controller.error!),
                copyable: true,
              ),
            for (final group in quality.verifiedGroups)
              Text(
                AppCopy.of(context).text(
                  'analysis.sessionTurns',
                  args: {
                    'p0': group['sessionId'],
                    'p1': group['model'],
                    'p2': group['effort'],
                    'p3': group['serviceTier'],
                    'p4': group['turnCount'],
                  },
                ),
              ),
            if (analysis != null) ...[
              Text(
                AppCopy.of(context).text(
                  'analysis.recordedResponsesTotalOutputTokensTurnTotal',
                  args: {
                    'p0':
                        analysis['responseCount'] ??
                        AppCopy.of(context).text('analysis.unavailable'),
                    'p1':
                        analysis['responseOutputTokens'] ??
                        AppCopy.of(context).text('analysis.unavailable'),
                    'p2': analysis['usageMatchesTurn'] == true
                        ? AppCopy.of(context).text('analysis.matched')
                        : analysis['usageMatchesTurn'] == false
                        ? AppCopy.of(context).text('analysis.mismatched')
                        : AppCopy.of(context).text('analysis.notVerifiable'),
                  },
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.unclassifiedTime',
                  args: {'p0': _seconds(analysis['unclassifiedMs'])},
                ),
              ),
              for (final response in SessionChartData.fromData(
                controller.data,
              ).responses)
                Text(
                  AppCopy.of(context).text(
                    'analysis.outputReasoningTokens',
                    args: {
                      'p0': response.id,
                      'p1':
                          response.outputTokens ??
                          AppCopy.of(context).text('analysis.unavailable'),
                      'p2':
                          response.reasoningTokens ??
                          AppCopy.of(context).text('analysis.unavailable'),
                    },
                  ),
                ),
            ],
            if (!timeline.available)
              Text(
                AppCopy.of(context)
                    .text('analysis.timingDataIncompleteOrUnverifiable'),
              ),
            for (final row in timeline.rows.take(200))
              Text(
                AppCopy.of(context).text(
                  'analysis.offsetMsNRecordedStartRecordedEndUnix',
                  args: {
                    'p0': AppCopy.of(context).timelineRowLabel(row),
                    'p1':
                        row.offsetStartMs ??
                        AppCopy.of(context).text('analysis.unknown'),
                    'p2':
                        row.offsetEndMs ??
                        AppCopy.of(context).text('analysis.unknown'),
                    'p3': row.drawable
                        ? AppCopy.of(context).text('analysis.positioned')
                        : AppCopy.of(context).timelineRowReasons(row),
                    'p4':
                        row.startedAtMs ??
                        AppCopy.of(context).text('analysis.unknown'),
                    'p5':
                        row.completedAtMs ??
                        AppCopy.of(context).text('analysis.unknown'),
                  },
                ),
              ),
            if (timeline.omittedItems > 0)
              Text(
                AppCopy.of(context).text(
                  'analysis.itemsOmitted',
                  args: {'p0': timeline.omittedItems},
                ),
              ),
          ],
        );
      },
    ),
  );

  String _seconds(Object? value) =>
      SessionActivityTimelineData.isSafeMilliseconds(value)
      ? '${((value as int) / 1000).toStringAsFixed(3)} s'
      : AppCopy.of(context).text('analysis.unavailable');

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
                  Text(
                    AppCopy.of(context).text('analysis.sessionTurnStatistics'),
                    style: context.theme.typography.display.lg,
                  ),
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
                              label: AppCopy.of(context)
                                  .text('analysis.recentSessions'),
                              child: FSelect<String>.search(
                                key: const ValueKey('session-selector'),

                                items: _choices(),
                                filter: (query) {
                                  final q = query.trim().toLowerCase();
                                  return controller.sessions
                                      .where(
                                        (s) => [
                                          AppCopy.of(context).sessionTitle(s),
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
                          label: AppCopy.of(
                            context,
                          ).text('analysis.sessionInformationAndDiagnostics'),
                          icon: FLucideIcons.info,
                          onPress: _information,
                        ),
                        MonitorIconAction(
                          key: const ValueKey('session-refresh'),
                          label: controller.listing
                              ? AppCopy.of(context)
                                    .text('analysis.listingSessions')
                              : AppCopy.of(context)
                                    .text('analysis.refreshLocalSessionList'),
                          icon: FLucideIcons.refreshCw,
                          onPress: controller.listing ? null : controller.list,
                        ),
                        if (controller.selected != null)
                          FButton(
                            mainAxisSize: MainAxisSize.min,
                            variant: FButtonVariant.ghost,
                            onPress: () => controller.select(null),
                            prefix: const Icon(FLucideIcons.square, size: 14),
                            child: Text(
                              AppCopy.of(context)
                                  .text('analysis.stopSessionCollection'),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (controller.selected != null &&
                      controller.selectorValue == null)
                    Text(
                      AppCopy.of(
                        context,
                      ).text('analysis.theCollectedSessionIsOutsideTheRecent'),
                    ),
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
                              ? AppCopy.of(context).text(
                                  'analysis.sessionIdentityAwaitingVerification',
                                )
                              : '${AppCopy.of(context).sessionTitle(info)} · ${info['cwd'] ?? AppCopy.of(context).text('analysis.unknownProject')}',
                          child: Text(
                            AppCopy.of(context).text(
                              'analysis.sessionStatus',
                              args: {
                                'p0': AppCopy.of(context).sessionStateLabel(
                                  selected: controller.selected != null,
                                  readFailed: controller.error != null,
                                  catchingUp:
                                      controller.data?['catchingUp'] == true,
                                  status:
                                      controller.data?['current']?['status'],
                                ),
                              },
                            ),
                            key: const ValueKey('session-state'),
                          ),
                        ),
                        if (controller.selected != null) ...[
                          Text(
                            controller.data?['catchingUp'] == true
                                ? AppCopy.of(context).text(
                                    'analysis.readingHistoryNoRecentCompletedTurnAvailable',
                                  )
                                : last == null
                                ? AppCopy.of(
                                    context,
                                  ).text('analysis.recentlyCompletedNoSample')
                                : AppCopy.of(context).text(
                                    'analysis.recentlyCompletedIncludesToolsAndWaiting',
                                  ),
                            key: const ValueKey('session-completed-summary'),
                          ),
                          Text(
                            AppCopy.of(context).text(
                              'analysis.sampleQuality',
                              args: {
                                'p0': AppCopy.of(context)
                                    .sessionQualityLabel(quality),
                              },
                            ),
                            key: const ValueKey('session-quality'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (controller.listError != null)
                    Text(
                      AppCopy.of(context).text(
                        'analysis.listRefreshFailedSeeInformationForDiagnostics',
                      ),
                    ),
                  if (controller.selectionError != null)
                    Text(
                      AppCopy.of(context)
                          .sessionDiagnostic(controller.selectionError!),
                    ),
                  if (controller.error != null)
                    Text(
                      AppCopy.of(context).text(
                        'analysis.sessionReadFailedSeeInformationForDiagnostics',
                      ),
                      style: TextStyle(color: context.theme.colors.destructive),
                    ),
                  if (controller.selected == null)
                    Text(
                      AppCopy.of(
                        context,
                      ).text('analysis.selectASessionTheCurrentConversationIs'),
                    )
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
                                label: AppCopy.of(context)
                                    .text('analysis.turnAverage'),
                                value:
                                    publish &&
                                        quality.verifiedTokensPerSecond != null
                                    ? '${quality.verifiedTokensPerSecond!.toStringAsFixed(2)} tokens/s'
                                    : AppCopy.of(context)
                                          .text('analysis.unavailable'),
                                valueKey: 'session-rate-value',
                              ),
                              _Metric(
                                width: width,
                                label: AppCopy.of(context)
                                    .text('analysis.outputIncludesReasoning'),
                                value:
                                    last?['outputTokens'] is int &&
                                        (last!['outputTokens'] as int) >= 0 &&
                                        (last['outputTokens'] as int) <=
                                            9007199254740991
                                    ? '${last['outputTokens']} tokens'
                                    : AppCopy.of(context)
                                          .text('analysis.unavailable'),
                                valueKey: 'session-output-value',
                              ),
                              _Metric(
                                width: width,
                                label: AppCopy.of(context)
                                    .text('analysis.firstModelTokenWait'),
                                value: recordedFirst && !contradicts
                                    ? _seconds(first)
                                    : AppCopy.of(context)
                                          .text('analysis.unavailable'),
                                valueKey: 'session-first-token-value',
                                note: AppCopy.of(context)
                                    .text('analysis.mayIncludeReasoning'),
                              ),
                              _Metric(
                                width: width,
                                label: AppCopy.of(context)
                                    .text('analysis.completeTurn'),
                                value: validDuration
                                    ? _seconds(duration)
                                    : AppCopy.of(context)
                                          .text('analysis.unavailable'),
                                valueKey: 'session-duration-value',
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (contradicts)
                      Text(
                        AppCopy.of(context).text(
                          'analysis.firstModelTokenUnavailableExceedsCompleteTurn',
                        ),
                      ),
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
