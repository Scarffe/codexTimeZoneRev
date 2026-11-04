import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/global_workbench.dart';
import '../state/account_usage_controller.dart';
import '../state/global_workbench_controller.dart';
import '../state/global_live_controller.dart';
import '../state/session_attention_controller.dart';
import '../state/session_metrics_controller.dart';
import 'dashboard_style.dart';
import 'global_session_list.dart';
import 'global_live_panel.dart';
import 'global_workbench_charts.dart';
import 'monitor_information.dart';
import 'workspace_shell.dart';

/// Global native-index view. Selected detail and account quota remain separate.
class WorkspaceOverviewPage extends StatefulWidget {
  const WorkspaceOverviewPage({
    super.key,
    required this.usage,
    required this.metrics,
    required this.attention,
    required this.onSelect,
    required this.recentNotice,
    this.global,
    this.onOpenSession,
    this.live,
  });
  final AccountUsageController usage;
  final SessionMetricsController metrics;
  final SessionAttentionController attention;
  final ValueChanged<WorkspaceDestination> onSelect;
  final String recentNotice;
  final GlobalWorkbenchController? global;
  final ValueChanged<GlobalSessionRow>? onOpenSession;
  final GlobalLiveController? live;
  @override
  State<WorkspaceOverviewPage> createState() => _WorkspaceOverviewPageState();
}

class _WorkspaceOverviewPageState extends State<WorkspaceOverviewPage> {
  String metric = 'totalTokens';
  final _sessionRows = GlobalKey();
  late final _search = TextEditingController(
    text: widget.global?.query.search ?? '',
  );
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openLiveThread(String id) async {
    final controller = widget.global;
    if (controller == null) return;
    final row = controller.snapshot?.sessions
        .where((row) => row.threadId == id)
        .firstOrNull;
    if (row?.canOpenDetail == true && widget.onOpenSession != null) {
      widget.onOpenSession!(row!);
      return;
    }
    // Exact ID search is an index query, never an inferred local path.
    _search.text = id;
    await controller.clearFilters();
    if (!mounted) return;
    await controller.setSearch(id);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _sessionRows.currentContext;
      if (mounted && target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 180),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.global ?? const _NoGlobalListenable(),
    builder: (context, _) => _content(context),
  );
  Widget _content(BuildContext context) {
    final controller = widget.global,
        snapshot = controller?.snapshot,
        copy = AppCopy.of(context),
        palette = DashboardPalette.of(context);
    final coverage = snapshot?.coverage;
    return SingleChildScrollView(
      key: const PageStorageKey('overview-scroll'),
      child: Column(
        key: const ValueKey('global-workbench'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                copy.text('global.title'),
                style: context.theme.typography.body.lg.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (controller?.service.synthetic == true)
                Text(
                  copy.text('global.synthetic'),
                  style: context.theme.typography.body.xs.copyWith(
                    color: palette.muted,
                  ),
                ),
              FButton(
                key: const ValueKey('global-refresh'),
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: controller == null || controller.busy
                    ? null
                    : controller.refresh,
                child: Text(
                  copy.text(
                    controller?.busy == true
                        ? 'global.updating'
                        : 'global.refresh',
                  ),
                ),
              ),
              FButton(
                key: const ValueKey('global-background'),
                variant: FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: controller == null
                    ? null
                    : () => controller.setBackgroundObservation(
                        !controller.backgroundObservationEnabled,
                      ),
                child: Text(
                  copy.text(
                    controller?.backgroundObservationEnabled == true
                        ? 'global.backgroundOn'
                        : 'global.backgroundOff',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            copy.text('global.subtitle'),
            style: context.theme.typography.body.xs.copyWith(
              color: palette.muted,
            ),
          ),
          if (widget.live != null) ...[
            const SizedBox(height: 14),
            GlobalLivePanel(
              controller: widget.live!,
              onConnect: () => widget.onSelect(WorkspaceDestination.accounts),
              onOpenThread: controller == null || controller.busy
                  ? null
                  : _openLiveThread,
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final range in GlobalRange.values)
                FButton(
                  key: ValueKey('global-range-${range.name}'),
                  variant: controller?.range == range
                      ? FButtonVariant.primary
                      : FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: controller == null
                      ? null
                      : () => controller.setRange(range),
                  child: Text(copy.text('global.range.${range.name}')),
                ),
              FButton(
                key: const ValueKey('global-clear'),
                variant: FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: controller == null
                    ? null
                    : () {
                        _search.clear();
                        controller.clearFilters();
                      },
                child: Text(copy.text('global.clear')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: FTextField(
              key: const ValueKey('global-search'),
              hint: copy.text('global.search'),
              control: FTextFieldControl.managed(
                controller: _search,
                onChange: (value) => controller?.setSearch(value.text),
              ),
            ),
          ),
          if (controller?.query.project != null ||
              controller?.query.model != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (controller?.query.project case final project?)
                  FButton(
                    variant: FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => controller!.setProject(null),
                    child: Flexible(
                      child: Text(
                        copy.text(
                          'global.filterProject',
                          args: {'value': globalBucketName(copy, project)},
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                if (controller?.query.model case final model?)
                  FButton(
                    variant: FButtonVariant.outline,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => controller!.setModel(null),
                    child: Flexible(
                      child: Text(
                        copy.text(
                          'global.filterModel',
                          args: {'value': globalBucketName(copy, model)},
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final count = constraints.maxWidth >= 900 ? 4 : 2;
              final width = (constraints.maxWidth - (count - 1) * 10) / count;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _stat(
                    context,
                    width,
                    'global-stat-active',
                    'global.running',
                    snapshot == null ? null : snapshot.totals.states['running'],
                    controller == null
                        ? null
                        : () => controller.setStatus(
                            controller.query.status == 'running'
                                ? null
                                : 'running',
                          ),
                    selected: controller?.query.status == 'running',
                    detail:
                        snapshot?.totals.staleRunning == 0 || snapshot == null
                        ? null
                        : copy.text(
                            'global.staleRunning',
                            args: {'count': snapshot.totals.staleRunning},
                          ),
                  ),
                  _stat(
                    context,
                    width,
                    'global-stat-attention',
                    'global.attention',
                    snapshot?.totals.attentionCount,
                    null,
                    detail: snapshot?.totals.attentionCount == null
                        ? copy.text('global.attentionUnknown')
                        : null,
                  ),
                  _stat(
                    context,
                    width,
                    'global-stat-failed',
                    'global.failed',
                    snapshot == null ? null : snapshot.totals.states['failed'],
                    controller == null
                        ? null
                        : () => controller.setStatus(
                            controller.query.status == 'failed'
                                ? null
                                : 'failed',
                          ),
                    selected: controller?.query.status == 'failed',
                  ),
                  _stat(
                    context,
                    width,
                    'global-stat-tokens',
                    'global.tokens',
                    snapshot?.totals.tokens.metric(metric),
                    null,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                controller == null
                    ? copy.text('global.unavailable')
                    : snapshot == null
                    ? copy.text(
                        controller.busy
                            ? 'global.initial'
                            : 'global.unavailable',
                      )
                    : copy.text('global.phase.${snapshot.phase}'),
                style: context.theme.typography.body.xs.copyWith(
                  color: controller?.error == null
                      ? palette.muted
                      : palette.danger,
                ),
              ),
              if (coverage != null)
                Text(
                  copy.text(
                    'global.coverage',
                    args: {
                      'indexed': copy.integer(coverage.indexed),
                      'discovered': copy.integer(coverage.discovered),
                      'pending': copy.integer(coverage.pending),
                    },
                  ),
                  style: context.theme.typography.body.xs.copyWith(
                    color: palette.muted,
                  ),
                ),
              FButton(
                key: const ValueKey('global-diagnostics'),
                variant: FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () => _diagnostics(context),
                child: Text(copy.text('global.diagnostics')),
              ),
            ],
          ),
          if (controller?.error != null)
            Text(
              copy.text('global.error'),
              style: context.theme.typography.body.xs.copyWith(
                color: palette.danger,
              ),
            ),
          if (snapshot?.totals.partial == true)
            Text(
              copy.text('global.partialCounts'),
              key: const ValueKey('global-quality-warning'),
              style: context.theme.typography.body.xs.copyWith(
                color: palette.danger,
              ),
            ),
          if (controller?.preferenceError != null)
            Text(
              copy.text('global.preferenceError'),
              style: context.theme.typography.body.xs.copyWith(
                color: palette.danger,
              ),
            ),
          const SizedBox(height: 12),
          GlobalSessionList(
            key: _sessionRows,
            snapshot: snapshot,
            busy: controller?.busy ?? false,
            sort: controller?.query.sort ?? 'recent',
            onSort: (value) => controller?.setSort(value),
            onPrevious: controller == null || controller.query.offset == 0
                ? null
                : controller.previousPage,
            onNext: controller == null || snapshot?.hasMore != true
                ? null
                : controller.nextPage,
            onOpen: widget.onOpenSession,
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final value in [
                'totalTokens',
                'inputTokens',
                'cachedInputTokens',
                'outputTokens',
              ])
                FButton(
                  key: ValueKey('global-metric-$value'),
                  mainAxisSize: MainAxisSize.min,
                  variant: value == metric
                      ? FButtonVariant.primary
                      : FButtonVariant.ghost,
                  onPress: () => setState(() => metric = value),
                  child: Text(copy.text('global.metric.$value')),
                ),
            ],
          ),
          const SizedBox(height: 10),
          GlobalWorkbenchCharts(
            snapshot: snapshot,
            metric: metric,
            onProject: (value) => controller?.setProject(value),
            onModel: (value) => controller?.setModel(value),
          ),
          const SizedBox(height: 8),
          Text(
            copy.text('global.subsets'),
            style: context.theme.typography.body.xs.copyWith(
              color: palette.muted,
            ),
          ),
          const SizedBox(height: 16),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final destination in [
                WorkspaceDestination.accounts,
                WorkspaceDestination.sessions,
                WorkspaceDestination.analysis,
                WorkspaceDestination.benchmark,
              ])
                FButton(
                  key: ValueKey('overview-${destination.name}'),
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => widget.onSelect(destination),
                  child: Text(copy.text('nav.${destination.name}')),
                ),
              FButton(
                key: const ValueKey('recent-monitor-notice'),
                variant: FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () => showMonitorInformation(
                  context,
                  title: copy.text('overview.notices'),
                  builder: (_) => Text(
                    widget.recentNotice.isEmpty
                        ? copy.text('overview.noNotices')
                        : widget.recentNotice,
                  ),
                ),
                child: Text(copy.text('overview.notices')),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _stat(
    BuildContext context,
    double width,
    String key,
    String label,
    int? value,
    VoidCallback? onPress, {
    bool selected = false,
    String? detail,
  }) {
    final copy = AppCopy.of(context), palette = DashboardPalette.of(context);
    return SizedBox(
      width: width,
      child: FCard(
        key: ValueKey(key),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.text(label),
                style: context.theme.typography.body.xs.copyWith(
                  color: palette.muted,
                ),
              ),
              const SizedBox(height: 5),
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: selected
                    ? FButtonVariant.primary
                    : FButtonVariant.ghost,
                onPress: onPress,
                child: Text(
                  globalNumber(copy, value),
                  style: context.theme.typography.body.lg.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: context.theme.typography.body.xs.copyWith(
                    color: palette.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _diagnostics(BuildContext context) {
    final controller = widget.global;
    return showMonitorInformation(
      context,
      title: AppCopy.of(context).text('global.diagnostics'),
      titleKey: 'global.diagnostics',
      builder: (context) {
        final copy = AppCopy.of(context),
            snapshot = controller?.snapshot,
            coverage = snapshot?.coverage;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot != null) ...[
              Text(
                copy.text(
                  'global.observedAt',
                  args: {
                    'time': copy.dateTime(
                      snapshot.observedAtMs == 0
                          ? null
                          : DateTime.fromMillisecondsSinceEpoch(
                              snapshot.observedAtMs,
                            ),
                      compact: true,
                    ),
                    'revision': snapshot.revision,
                  },
                ),
              ),
              const SizedBox(height: 10),
              for (final root in snapshot.roots) Text(root),
              Text(
                copy.text(
                  'global.aggregateQuality',
                  args: {
                    'quality': snapshot.totals.quality,
                    'conflicts': snapshot.totals.excludedConflicts,
                    'unknownTime': snapshot.totals.unknownTime,
                  },
                ),
              ),
              if (coverage != null)
                Text(
                  copy.text(
                    'global.coverageGaps',
                    args: {
                      'unreadable': coverage.unreadable,
                      'unsupported': coverage.unsupported,
                      'missing': coverage.missing,
                    },
                  ),
                ),
              for (final warning in snapshot.warnings) Text(warning),
            ],
            if (controller?.error != null) Text(controller!.error!),
            if (controller?.preferenceError != null)
              Text(controller!.preferenceError!),
            if (controller == null) Text(copy.text('global.unavailable')),
          ],
        );
      },
    );
  }
}

class _NoGlobalListenable implements Listenable {
  const _NoGlobalListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
