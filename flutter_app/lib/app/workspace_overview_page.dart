import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../services/session_attention.dart';
import '../state/session_metrics_controller.dart';
import '../state/session_attention_controller.dart';
import 'workspace_shell.dart';
import 'account_usage_panel.dart' show quotaWindowLabel;
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
        unit: AppCopy.of(context).text('overview.sourcesUnit'),
        caption: usage.sources?.selected == null
            ? AppCopy.of(context).text('overview.noAccount')
            : AppCopy.of(context).text(
                'overview.selected',
                args: {'alias': usage.sources!.selected!.alias},
              ),
        onOpen: onSelect,
        details: [
          if (usage.data == null)
            Text(AppCopy.of(context).text('overview.quotaUnknown'))
          else ...[
            for (final bucket in usage.data!.buckets)
              for (final window in bucket.windows)
                Text(
                  AppCopy.of(context).text(
                    'overview.windowRemaining',
                    args: {
                      'bucket': bucket.label,
                      'window': quotaWindowLabel(AppCopy.of(context), window),
                      'value': _remaining(
                        AppCopy.of(context),
                        window.usedPercent,
                      ),
                    },
                  ),
                ),
            Text(
              '${usage.busy
                  ? AppCopy.of(context).text('overview.refreshing')
                  : usage.stale
                  ? AppCopy.of(context).text('overview.previousObservation')
                  : AppCopy.of(context).text('overview.latestObservation')} · ${_observedAt(AppCopy.of(context), usage.data!.fetchedAt)}',
              style: context.theme.typography.body.xs.copyWith(
                color: palette.muted,
              ),
            ),
            if (usage.error != null)
              Text(AppCopy.of(context).text('overview.refreshFailed')),
          ],
        ],
      ),
      _OverviewCard(
        destination: WorkspaceDestination.sessions,
        headline: '${attention.unreadCount}',
        unit: AppCopy.of(context).text('overview.unreadUnit'),
        caption: AppCopy.of(
          context,
        ).text('overview.watching', args: {'count': attention.watches.length}),
        onOpen: onSelect,
        details: [
          Text(
            AppCopy.of(context).text(
              'overview.runningCompleted',
              args: {
                'running': _count(SessionAttentionStatus.running),
                'completed': _count(SessionAttentionStatus.completed),
              },
            ),
          ),
          Text(
            AppCopy.of(context).text(
              'overview.cancelledUnknown',
              args: {
                'cancelled': _count(SessionAttentionStatus.cancelled),
                'unknown': _count(SessionAttentionStatus.unknown),
              },
            ),
            style: context.theme.typography.body.sm.copyWith(
              color: palette.muted,
            ),
          ),
        ],
      ),
      _OverviewCard(
        destination: WorkspaceDestination.analysis,
        headline: AppCopy.of(context).number(rate),
        unit: rate == null
            ? AppCopy.of(context).text('overview.noVerified')
            : 'tokens/s',
        caption: AppCopy.of(context).text('overview.average'),
        onOpen: onSelect,
        details: [
          Text(
            metrics.selected == null
                ? AppCopy.of(context).text('overview.noLog')
                : _metricsState(AppCopy.of(context)),
          ),
          Text(
            AppCopy.of(context).text('overview.charts'),
            style: context.theme.typography.body.sm.copyWith(
              color: palette.muted,
            ),
          ),
        ],
      ),
      _OverviewCard(
        destination: WorkspaceDestination.benchmark,
        headline: AppCopy.of(context).text('overview.offline'),
        unit: AppCopy.of(context).text('overview.independent'),
        caption: 'Chat Completions / Responses',
        onOpen: onSelect,
        details: [
          Text(AppCopy.of(context).text('overview.synthetic')),
          Text(
            AppCopy.of(context).text('overview.separate'),
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
              AppCopy.of(context).text('overview.intro'),
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
                  titleKey: 'overview.notices',
                  title: AppCopy.of(context).text('overview.notices'),
                  builder: (_) => Text(
                    recentNotice.isEmpty
                        ? AppCopy.of(context).text('overview.noNotices')
                        : recentNotice,
                  ),
                ),
                child: Text(AppCopy.of(context).text('overview.notices')),
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
                        titleKey: 'overview.guideTitle',
                        title: AppCopy.of(context).text('overview.guideTitle'),
                        builder: (_) => Text(
                          AppCopy.of(
                            context,
                          ).text('overview.guideError', args: {'error': error}),
                        ),
                      );
                    }
                  }
                },
                child: Text(AppCopy.of(context).text('overview.guide')),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  String _metricsState(AppCopy copy) {
    if (metrics.error != null) return copy.text('overview.state.readFailed');
    if (metrics.data?['catchingUp'] == true) {
      return copy.text('overview.state.history');
    }
    return copy.text(switch (metrics.data?['current']?['status']) {
      'running' => 'overview.state.running',
      'completed' => 'overview.state.completed',
      'cancelled' => 'overview.state.cancelled',
      _ => 'overview.state.unknown',
    });
  }

  int _count(SessionAttentionStatus status) => attention.items
      .where((item) => item.watch.enabled && item.status == status)
      .length;
  String _remaining(AppCopy copy, double? used) =>
      used == null || !used.isFinite || used < 0 || used > 100
      ? copy.text('common.unknown')
      : '${(100 - used).toStringAsFixed(2)}%';

  String _observedAt(AppCopy copy, DateTime time) {
    if (copy.isEnglish) return copy.dateTime(time, compact: true);
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
                    AppCopy.of(context).text('nav.${destination.name}'),
                    style: context.theme.typography.body.lg.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FButton(
                  key: ValueKey('overview-${destination.name}'),
                  semanticsLabel: AppCopy.of(context).text(
                    'overview.openDestination',
                    args: {
                      'name': AppCopy.of(context)
                          .text('nav.${destination.name}'),
                    },
                  ),
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => onOpen(destination),
                  suffix: const Icon(FLucideIcons.arrowUpRight, size: 16),
                  child: Text(AppCopy.of(context).text('overview.open')),
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
