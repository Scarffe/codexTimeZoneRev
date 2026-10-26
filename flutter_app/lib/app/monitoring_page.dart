import '../l10n/app_copy.dart';

import 'dart:async';

import '../state/session_rhythm_controller.dart';
import 'session_rhythm_panel.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import '../state/session_metrics_controller.dart';
import '../services/session_attention.dart';
import 'account_usage_panel.dart';
import 'session_metrics_panel.dart';
import 'monitor_charts.dart';
import 'dashboard_style.dart';

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
    this.rhythm,
    this.onOpenRhythm,
    this.historyContext,
    this.onDismissHistory,
    this.currentViewRevision = 0,
  });
  final SessionRhythmController? rhythm;
  final ValueChanged<RhythmAnalysisContext>? onOpenRhythm;
  final RhythmAnalysisContext? historyContext;
  final VoidCallback? onDismissHistory;
  final int currentViewRevision;
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
  bool _rhythmView = false;
  @override
  void didUpdateWidget(covariant MonitoringPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentViewRevision != widget.currentViewRevision) {
      _rhythmView = false;
    }
  }

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
    final palette = DashboardPalette.of(context);
    final secondary = context.theme.typography.body.sm.copyWith(
      color: palette.muted,
    );
    final matchesNotice =
        notice != null &&
        widget.metrics.selected == notice.path &&
        widget.metrics.sourceInfo?['id'] == notice.sessionId;
    return SingleChildScrollView(
      key: const PageStorageKey('analysis-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.rhythm != null) ...[
            Wrap(
              spacing: 8,
              children: [
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: !_rhythmView
                      ? FButtonVariant.primary
                      : FButtonVariant.outline,
                  onPress: () => setState(() => _rhythmView = false),
                  child: Text(
                    AppCopy.of(context).text('analysis.currentSession'),
                  ),
                ),
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: _rhythmView
                      ? FButtonVariant.primary
                      : FButtonVariant.outline,
                  onPress: () => setState(() => _rhythmView = true),
                  child: Text(
                    AppCopy.of(context).text('analysis.sessionRhythm'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (_rhythmView && widget.rhythm != null)
            SessionRhythmPanel(
              controller: widget.rhythm!,
              available: widget.metrics.sessions,
              listing: widget.metrics.listing,
              listError: widget.metrics.listError,
              onList: widget.metrics.list,
              onOpen: widget.onOpenRhythm ?? (_) {},
            ),
          if (!_rhythmView) ...[
            if (widget.historyContext case final history?) ...[
              FCard(
                key: widget.noticeContextKey,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppCopy.of(context).text(
                          'analysis.historicalSourceAnalysisCachedTurnContext',
                        ),
                      ),
                      Text(
                        AppCopy.of(context).text(
                          'analysis.sessionOriginalTurn',
                          args: {
                            'p0': history.source.title,
                            'p1': history.source.sessionId,
                            'p2': history.turn.turnId,
                          },
                        ),
                      ),
                      Text(history.source.path),
                      Text(
                        widget.metrics.selected != history.source.path ||
                                widget.metrics.sourceInfo?['id'] !=
                                    history.source.sessionId
                            ? AppCopy.of(context).text(
                                'analysis.originalSourceIdentityHasNotBeenVerified',
                              )
                            : widget.metrics.last?['turnId'] ==
                                  history.turn.turnId
                            ? AppCopy.of(context).text(
                                'analysis.theLatestSampleMatchesTheHistoricalTurn',
                              )
                            : AppCopy.of(context).text(
                                'analysis.theHistoricalTurnChartsCannotBeReplayed',
                              ),
                      ),
                      FButton(
                        variant: FButtonVariant.ghost,
                        onPress: widget.onDismissHistory,
                        child: Text(
                          AppCopy.of(context)
                              .text('analysis.closeHistoricalContext'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
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
                        Text(
                          AppCopy.of(context).text(
                            'analysis.originalReminder',
                            args: {'p0': notice.title},
                          ),
                        ),
                        Text(
                          AppCopy.of(context).text(
                            'analysis.sessionOriginalTurn2',
                            args: {'p0': notice.sessionId, 'p1': notice.turnId},
                          ),
                        ),
                        Text(notice.path),
                        Text(
                          !matchesNotice
                              ? AppCopy.of(context).text(
                                  'analysis.originalSourceIdentityHasNotBeenVerified',
                                )
                              : widget.metrics.last?['turnId'] == notice.turnId
                              ? AppCopy.of(context).text(
                                  'analysis.theLatestSampleMatchesTheOriginalReminder',
                                )
                              : AppCopy.of(context).text(
                                  'analysis.theOriginalReminderTurnSampleIsUnavailable',
                                ),
                        ),
                        FButton(
                          variant: FButtonVariant.ghost,
                          mainAxisSize: MainAxisSize.min,
                          onPress: widget.onDismissNotice,
                          child: Text(
                            AppCopy.of(context)
                                .text('analysis.closeReminderContext'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (notice != null) const SizedBox(height: 16),
            FCard(
              key: const ValueKey('analysis-quota-card'),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          FLucideIcons.gauge,
                          size: 18,
                          color: palette.controlAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            AppCopy.of(context)
                                .text('analysis.accountQuotaIndependentSource'),
                            style: context.theme.typography.display.lg,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppCopy.of(context).text(
                        'analysis.eachWindowIsMeasuredSeparatelyAccountsAre',
                      ),
                      style: secondary,
                    ),
                    const SizedBox(height: 20),
                    if (owner != null && owner.selected != null) ...[
                      MonitorChoice(
                        key: const ValueKey('analysis-account-source'),
                        label: AppCopy.of(context).text('analysis.quotaSource'),
                        value: owner.selectedId,
                        items: {
                          for (final state in owner.states.where(
                            (s) => !s.pendingRemoval,
                          ))
                            '${state.alias} · ${state.id}': state.id,
                        },
                        onChanged: owner.select,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (owner != null && owner.selected == null)
                      Text(
                        AppCopy.of(context)
                            .text('analysis.addAnAccountOnTheAccountQuota'),
                      ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if (bucket != null)
                          MonitorChoice(
                            key: const ValueKey('analysis-quota-bucket'),
                            label: AppCopy.of(context)
                                .text('analysis.quotaType'),
                            value: bucket.id,
                            items: {for (final b in buckets) b.label: b.id},
                            onChanged: (value) =>
                                setState(() => _bucket = value),
                          ),
                        MonitorChoice(
                          key: const ValueKey('analysis-quota-view'),
                          label: AppCopy.of(context).text('analysis.quotaView'),
                          value: _view,
                          items: {
                            AppCopy.of(context).text('analysis.remaining'):
                                'remaining',
                            AppCopy.of(context).text('analysis.used'): 'used',
                            AppCopy.of(context).text('analysis.untilReset'):
                                'reset',
                          },
                          onChanged: (value) => setState(() => _view = value),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (usage.error != null)
                      Text(
                        AppCopy.of(context).text(
                          'analysis.quotaSource2',
                          args: {'p0': usage.error},
                        ),
                      ),
                    if (usage.data != null)
                      Text(
                        AppCopy.of(context).text(
                          'analysis.latestQuotaObservation',
                          args: {
                            'p0': AppCopy.of(context).isEnglish
                                ? AppCopy.of(context).dateTime(
                                    usage.data!.fetchedAt,
                                    includeSeconds: true,
                                  )
                                : usage.data!.fetchedAt.toLocal(),
                          },
                        ),
                        style: secondary,
                      ),
                    if (bucket == null)
                      Text(
                        AppCopy.of(context).text(
                          'analysis.quotaUnavailableQueryInTheAccountQuota',
                        ),
                      )
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
            const SizedBox(height: 24),
            Text(
              AppCopy.of(context)
                  .text('analysis.localSessionLogsIndependentOfAccountQuota'),
              style: secondary,
            ),
            const SizedBox(height: 8),
            SessionMetricsPanel(
              key: widget.sessionPanelKey,
              controller: widget.metrics,
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}
