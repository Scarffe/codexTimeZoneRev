import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/global_workbench.dart';
import 'dashboard_style.dart';
import 'global_workbench_charts.dart';
import 'monitor_information.dart';

class GlobalSessionList extends StatelessWidget {
  const GlobalSessionList({
    super.key,
    required this.snapshot,
    required this.busy,
    required this.sort,
    required this.onSort,
    required this.onPrevious,
    required this.onNext,
    this.onOpen,
  });
  final GlobalSnapshot? snapshot;
  final bool busy;
  final String sort;
  final ValueChanged<String> onSort;
  final VoidCallback? onPrevious, onNext;
  final ValueChanged<GlobalSessionRow>? onOpen;
  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context), palette = DashboardPalette.of(context);
    final rows = snapshot?.sessions ?? const <GlobalSessionRow>[];
    return FCard(
      key: const ValueKey('global-session-list'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  copy.text('global.rows'),
                  style: context.theme.typography.body.lg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  copy.text(
                    'global.filtered',
                    args: {
                      'count': copy.integer(snapshot?.filteredCount ?? 0),
                      'shown': copy.integer(rows.length),
                    },
                  ),
                  style: context.theme.typography.body.xs.copyWith(
                    color: palette.muted,
                  ),
                ),
                FButton(
                  key: const ValueKey('global-sort'),
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: busy
                      ? null
                      : () => onSort(sort == 'recent' ? 'tokens' : 'recent'),
                  child: Text(
                    copy.text(
                      sort == 'recent'
                          ? 'global.sortRecent'
                          : 'global.sortTokens',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  copy.text('global.noSessions'),
                  style: context.theme.typography.body.sm.copyWith(
                    color: palette.muted,
                  ),
                ),
              ),
            for (final row in rows)
              Container(
                key: ValueKey('global-row-${row.key}'),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: palette.border)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 4,
                      height: 30,
                      margin: const EdgeInsets.only(top: 3, right: 12),
                      decoration: BoxDecoration(
                        color: row.lifecycleState == 'failed'
                            ? palette.danger
                            : row.lifecycleState == 'running' &&
                                  row.freshness == 'fresh'
                            ? palette.dataBlue
                            : palette.muted.withValues(alpha: .35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.shortId.isEmpty
                                ? copy.text('global.unassigned')
                                : row.shortId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.theme.typography.body.sm.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            globalBucketName(copy, row.project),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.theme.typography.body.xs.copyWith(
                              color: palette.muted,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Text(
                                globalBucketName(copy, row.model),
                                style: context.theme.typography.body.xs,
                              ),
                              Text(
                                copy.text('global.state.${row.lifecycleState}'),
                                style: context.theme.typography.body.xs,
                              ),
                              Text(
                                copy.text('global.freshness.${row.freshness}'),
                                style: context.theme.typography.body.xs
                                    .copyWith(color: palette.muted),
                              ),
                              Text(
                                '${globalNumber(copy, row.tokens.totalTokens)} token',
                                style: context.theme.typography.body.xs,
                              ),
                              Text(
                                copy.dateTime(
                                  row.lastEventMs == null
                                      ? null
                                      : DateTime.fromMillisecondsSinceEpoch(
                                          row.lastEventMs!,
                                        ),
                                  compact: true,
                                ),
                                style: context.theme.typography.body.xs
                                    .copyWith(color: palette.muted),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FButton(
                      key: ValueKey('global-open-${row.threadId}'),
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () {
                        if (row.canOpenDetail && onOpen != null) {
                          onOpen!(row);
                        } else {
                          _summary(context, row);
                        }
                      },
                      child: Text(
                        copy.text(
                          row.canOpenDetail && onOpen != null
                              ? 'global.open'
                              : 'global.summary',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  key: const ValueKey('global-previous'),
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: busy ? null : onPrevious,
                  child: Text(copy.text('global.previous')),
                ),
                FButton(
                  key: const ValueKey('global-next'),
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: busy ? null : onNext,
                  child: Text(copy.text('global.next')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _summary(
    BuildContext context,
    GlobalSessionRow row,
  ) => showMonitorInformation(
    context,
    title: AppCopy.of(context).text('global.summary'),
    titleKey: 'global.summary',
    builder: (context) {
      final copy = AppCopy.of(context);
      return Column(
        key: const ValueKey('global-summary-drawer'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(copy.text('global.summaryOnly')),
          const SizedBox(height: 16),
          for (final fact in [
            ('global.thread', row.threadId),
            ('global.transport', row.sessionId),
            ('global.project', row.project),
            ('global.model', row.model),
            ('global.path', row.path),
            ('global.basis', row.basis),
            ('global.quality', row.quality),
            ('global.reasons', row.reasons.join(' · ')),
          ])
            MonitorInformationFact(
              label: copy.text(fact.$1),
              value: fact.$2.isEmpty ? '—' : fact.$2,
              copyable: fact.$1 == 'global.path' || fact.$1 == 'global.thread',
            ),
          Text(
            '${copy.text('global.tokens')}: ${globalNumber(copy, row.tokens.totalTokens)}',
          ),
        ],
      );
    },
  );
}
