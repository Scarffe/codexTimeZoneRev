import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/global_live.dart';
import '../state/global_live_controller.dart';
import 'dashboard_style.dart';

class GlobalLivePanel extends StatelessWidget {
  const GlobalLivePanel({
    super.key,
    required this.controller,
    this.onOpenThread,
    this.onConnect,
  });
  final GlobalLiveController controller;
  final ValueChanged<String>? onOpenThread;
  final VoidCallback? onConnect;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final copy = AppCopy.of(context), palette = DashboardPalette.of(context);
      final data = controller.snapshot;
      final available =
          data.connected && data.coverage == 'partial' && !controller.stale;
      final items = available ? data.items : const <GlobalLiveItem>[];
      final rows = items.toList()
        ..sort((a, b) {
          final rank = _priority(a).compareTo(_priority(b));
          return rank == 0 ? b.sequence.compareTo(a.sequence) : rank;
        });
      final statesKnown = items.any(
        (item) => !['unknown', 'not_loaded'].contains(item.state),
      );
      final attentionKnown = items.any((item) => item.attention != 'unknown');
      final body = context.theme.typography.body;
      int count(bool Function(GlobalLiveItem) predicate) =>
          items.where(predicate).length;
      return FCard(
        key: const ValueKey('global-live-panel'),
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
                    copy.text('live.title'),
                    style: body.lg.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (controller.service is SyntheticGlobalLiveService)
                    Text(
                      copy.text('live.synthetic'),
                      style: body.xs.copyWith(color: palette.muted),
                    ),
                  Text(
                    copy.text(
                      controller.stale
                          ? 'live.stale'
                          : available
                          ? 'live.partial'
                          : data.connected
                          ? 'live.observationUnavailable'
                          : 'live.unavailable',
                    ),
                    style: body.sm.copyWith(
                      color: controller.stale ? palette.danger : palette.muted,
                    ),
                  ),
                  FButton(
                    key: const ValueKey('global-live-refresh'),
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.ghost,
                    onPress: controller.busy ? null : controller.refresh,
                    child: Text(copy.text('live.refresh')),
                  ),
                  if (!data.connected && onConnect != null)
                    FButton(
                      key: const ValueKey('global-live-connect'),
                      mainAxisSize: MainAxisSize.min,
                      variant: FButtonVariant.outline,
                      onPress: onConnect,
                      child: Text(copy.text('live.connect')),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth < 650 ? 2 : 4;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 8) / columns;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (kind, value, color) in [
                        (
                          'active',
                          statesKnown
                              ? count((i) => i.state == 'running')
                              : null,
                          palette.dataBlue,
                        ),
                        (
                          'approval',
                          attentionKnown
                              ? count(
                                  (i) => [
                                    'approval',
                                    'approval_and_input',
                                  ].contains(i.attention),
                                )
                              : null,
                          palette.reasoning,
                        ),
                        (
                          'input',
                          attentionKnown
                              ? count(
                                  (i) => [
                                    'input',
                                    'approval_and_input',
                                  ].contains(i.attention),
                                )
                              : null,
                          palette.tool,
                        ),
                        (
                          'failed',
                          statesKnown
                              ? count((i) => i.state == 'failed')
                              : null,
                          palette.danger,
                        ),
                      ])
                        Container(
                          key: ValueKey('global-live-$kind'),
                          width: width,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: palette.soft,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                copy.text('live.$kind'),
                                style: body.sm.copyWith(color: palette.muted),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                value == null ? '—' : copy.integer(value),
                                style: body.lg.copyWith(color: color),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                copy.text('live.initialGap'),
                style: body.xs.copyWith(color: palette.muted),
              ),
              if (data.dropped > 0) ...[
                const SizedBox(height: 5),
                Text(
                  copy.text('live.dropped', args: {'count': data.dropped}),
                  key: const ValueKey('global-live-dropped'),
                  style: body.xs.copyWith(color: palette.danger),
                ),
              ],
              if (available && rows.isEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  copy.text('live.empty'),
                  style: body.sm.copyWith(color: palette.muted),
                ),
              ],
              for (final item in rows.take(5)) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: palette.border)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _shortId(item.threadId),
                              style: body.sm.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 10,
                              runSpacing: 4,
                              children: [
                                Text(
                                  copy.text('live.state.${item.state}'),
                                  style: body.xs,
                                ),
                                Text(
                                  copy.text('live.attention.${item.attention}'),
                                  style: body.xs.copyWith(color: palette.muted),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FButton(
                        key: ValueKey('global-live-open-${item.threadId}'),
                        mainAxisSize: MainAxisSize.min,
                        variant: FButtonVariant.outline,
                        onPress: onOpenThread == null
                            ? null
                            : () => onOpenThread!(item.threadId),
                        child: Text(copy.text('live.open')),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  String _shortId(String id) => id.length > 20
      ? '${id.substring(0, 8)}…${id.substring(id.length - 8)}'
      : id;
  int _priority(GlobalLiveItem item) => switch (item.attention) {
    'approval' || 'input' || 'approval_and_input' => 0,
    _ =>
      item.state == 'failed'
          ? 1
          : item.state == 'running'
          ? 2
          : 3,
  };
}
