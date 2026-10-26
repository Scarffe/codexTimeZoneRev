import '../l10n/copy_analysis.dart';
import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_rhythm.dart';
import '../state/session_rhythm_controller.dart';
import 'monitor_charts.dart';
import 'session_rhythm_charts.dart';

/// An explicit historical reference, independent of attention/notification state.
class RhythmAnalysisContext {
  const RhythmAnalysisContext(this.source, this.turn);
  final RhythmSource source;
  final RhythmTurn turn;
}

class SessionRhythmPanel extends StatefulWidget {
  const SessionRhythmPanel({
    super.key,
    required this.controller,
    this.available = const [],
    this.listing = false,
    this.listError,
    required this.onList,
    required this.onOpen,
  });
  final SessionRhythmController controller;
  final List<Map<String, dynamic>> available;
  final bool listing;
  final String? listError;
  final VoidCallback onList;
  final ValueChanged<RhythmAnalysisContext> onOpen;
  @override
  State<SessionRhythmPanel> createState() => _SessionRhythmPanelState();
}

class _SessionRhythmPanelState extends State<SessionRhythmPanel> {
  String choice = '';
  RhythmAnalysisContext? selected;
  bool showSources = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, p = c.projection;
      final available = [
        for (final s in widget.available)
          if (s['path'] is String && s['id'] is String)
            RhythmSource(
              path: s['path'] as String,
              sessionId: s['id'] as String,
              title:
                  (s['title'] as String?) ??
                  AppCopy.of(context)
                      .text('analysis.session2', args: {'p0': s['id']}),
            ),
      ];
      final candidate = available.where((s) => s.key == choice).firstOrNull;
      final reference = selected;
      final current = reference == null
          ? null
          : c.turns
                .where(
                  (t) =>
                      t.sourceKey == reference.source.key &&
                      t.turnId == reference.turn.turnId,
                )
                .firstOrNull;
      final summary = current == null
          ? null
          : RhythmAnalysisContext(reference!.source, current);
      final validSummary =
          summary != null &&
          c.sources.any((s) => s.key == summary.source.key) &&
          c.turns.any(
            (t) =>
                t.sourceKey == summary.source.key &&
                t.turnId == summary.turn.turnId,
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                mainAxisSize: MainAxisSize.min,
                key: const ValueKey('rhythm-sources'),
                variant: FButtonVariant.outline,
                onPress: () => setState(() => showSources = !showSources),
                child: Text(
                  AppCopy.of(context)
                      .text('analysis.sources', args: {'p0': c.sources.length}),
                ),
              ),
              FButton(
                mainAxisSize: MainAxisSize.min,
                key: const ValueKey('rhythm-refresh'),
                variant: FButtonVariant.outline,
                onPress: c.busy || c.sources.isEmpty ? null : () => c.refresh(),
                child: Text(
                  AppCopy.of(context).text('analysis.rereadLocalLogs'),
                ),
              ),
              if (c.busy)
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: c.cancel,
                  child: Text(AppCopy.of(context).text('analysis.cancelRead')),
                ),
              SizedBox(
                width: 170,
                child: MonitorChoice(
                  label: AppCopy.of(context).text('analysis.timeRange'),
                  value: c.range.name,
                  items: {
                    AppCopy.of(context).text('analysis.lastHours'): 'hours24',
                    AppCopy.of(context).text('analysis.lastDays'): 'days7',
                    AppCopy.of(context).text('analysis.lastDays2'): 'days30',
                  },
                  onChanged: (v) {
                    setState(() => selected = null);
                    c.setRange(RhythmRange.values.byName(v));
                  },
                ),
              ),
              if (c.selectedHour != null)
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  key: const ValueKey('rhythm-clear-hour'),
                  variant: FButtonVariant.outline,
                  onPress: c.clearHour,
                  child: Text(
                    AppCopy.of(context).text('analysis.clearHourFilter'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!c.cacheReady)
            Text(AppCopy.of(context).text('analysis.restoringCache')),
          Text(
            AppCopy.of(context).text(
              'analysis.completedCancelledSamplesRecordedActivity',
              args: {
                'p0': p.completedCount,
                'p1': p.cancelledCount,
                'p2': p.distribution.count,
                'p3': rhythmSeconds(p.activityMs, copy: AppCopy.of(context)),
              },
            ),
          ),
          Text(
            AppCopy.of(context).text(
              'analysis.unknownTimePartial',
              args: {
                'p0': c.cacheStale
                    ? AppCopy.of(context).text('analysis.cacheNeedsReread')
                    : '',
                'p1': p.unknownTimeCount,
                'p2': p.partialCount,
                'p3': p.truncated
                    ? AppCopy.of(context).text('analysis.truncated')
                    : '',
              },
            ),
          ),
          if (c.lastRead != null)
            Text(
              AppCopy.of(context).text(
                'analysis.lastRead',
                args: {
                  'p0': (AppCopy.of(context).isEnglish
                      ? AppCopy.of(context)
                            .dateTime(c.lastRead, includeSeconds: true)
                      : c.lastRead!.toLocal().toString().split('.').first),
                },
              ),
            ),
          if (c.selectedHour != null)
            Text(
              AppCopy.of(context).text(
                'analysis.hourFilter',
                args: {'p0': c.selectedHour!.label},
              ),
            ),
          if (c.error != null)
            Text(
              AppCopy.of(context).text(
                'analysis.readError',
                args: {'p0': AppCopy.of(context).sessionDiagnostic(c.error!)},
              ),
            ),
          if (c.storageError != null)
            Text(
              AppCopy.of(context).text(
                'analysis.cacheError',
                args: {
                  'p0': AppCopy.of(context).sessionDiagnostic(c.storageError!),
                },
              ),
            ),
          if (showSources || c.sources.isEmpty) ...[
            const SizedBox(height: 8),
            FButton(
              mainAxisSize: MainAxisSize.min,
              key: const ValueKey('rhythm-list'),
              variant: FButtonVariant.outline,
              onPress: widget.listing ? null : widget.onList,
              child: Text(
                widget.listing
                    ? AppCopy.of(context).text('analysis.listing')
                    : AppCopy.of(context)
                          .text('analysis.listAvailableLocalSessions'),
              ),
            ),
            if (widget.listError != null)
              Text(
                AppCopy.of(
                  context,
                ).text('analysis.sourceList', args: {'p0': widget.listError}),
              ),
            if (available.isNotEmpty) ...[
              const SizedBox(height: 8),
              MonitorChoice(
                key: const ValueKey('rhythm-source-choice'),
                label: AppCopy.of(context)
                    .text('analysis.explicitSourceSelection'),
                value: choice,
                items: {
                  for (final s in available)
                    '${s.title} · ${s.sessionId} · ${s.path}': s.key,
                },
                onChanged: (v) => setState(() => choice = v),
              ),
              FButton(
                mainAxisSize: MainAxisSize.min,
                key: const ValueKey('rhythm-add'),
                onPress:
                    !c.cacheReady ||
                        candidate == null ||
                        c.sources.any((s) => s.key == candidate.key) ||
                        c.sources.length >= 8
                    ? null
                    : () => c.addSource(candidate),
                child: Text(AppCopy.of(context).text('analysis.addSource')),
              ),
            ],
            for (final s in c.sources)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title),
                          Text('${s.sessionId} · ${s.path}'),
                          if (c.sourceErrors[s.key] != null)
                            Text(
                              AppCopy.of(context).text(
                                'analysis.readError',
                                args: {
                                  'p0': AppCopy.of(
                                    context,
                                  ).sessionDiagnostic(c.sourceErrors[s.key]!),
                                },
                              ),
                            ),
                          if (c.lastReadMsBySource[s.key] != null)
                            Text(
                              AppCopy.of(context).text(
                                'analysis.lastRead',
                                args: {
                                  'p0': AppCopy.of(context).isEnglish
                                      ? AppCopy.of(context).dateTime(
                                          DateTime.fromMillisecondsSinceEpoch(
                                            c.lastReadMsBySource[s.key]!,
                                          ),
                                          includeSeconds: true,
                                        )
                                      : DateTime.fromMillisecondsSinceEpoch(
                                          c.lastReadMsBySource[s.key]!,
                                        ),
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      key: ValueKey('rhythm-remove-${s.sessionId}'),
                      variant: FButtonVariant.ghost,
                      onPress: () => c.removeSource(s.key),
                      child: Text(AppCopy.of(context).text('analysis.remove')),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          if (c.sources.isEmpty)
            Text(
              AppCopy.of(context)
                  .text('analysis.addExplicitSourcesToShowSessionRhythm'),
            )
          else ...[
            SessionRhythmCharts(
              projection: p,
              selectedHour: c.selectedHour,
              onHour: c.selectHour,
              onTurn: (s, t) =>
                  setState(() => selected = RhythmAnalysisContext(s, t)),
            ),
            const SizedBox(height: 12),
            if (validSummary)
              FCard(
                key: const ValueKey('rhythm-turn-summary'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${summary.source.title} · ${summary.turn.turnId}'),
                      Text(
                        AppCopy.of(context).text(
                          'analysis.source',
                          args: {
                            'p0': summary.source.sessionId,
                            'p1': summary.source.path,
                          },
                        ),
                      ),
                      Text(
                        AppCopy.of(context).text(
                          'analysis.statusCompleteTurnFirstModelToken',
                          args: {
                            'p0': rhythmStatusLabel(
                              summary.turn.status,
                              copy: AppCopy.of(context),
                            ),
                            'p1': rhythmSeconds(
                              summary.turn.durationMs,
                              copy: AppCopy.of(context),
                            ),
                            'p2': rhythmSeconds(
                              summary.turn.firstTokenMs,
                              copy: AppCopy.of(context),
                            ),
                          },
                        ),
                      ),
                      Text(
                        AppCopy.of(context).text(
                          'analysis.activityTimeResolution',
                          args: {
                            'p0': summary.turn.activityAvailable
                                ? AppCopy.of(context).text('analysis.recorded')
                                : AppCopy.of(context).text('analysis.unknown'),
                            'p1': summary.turn.partial
                                ? AppCopy.of(context).text('analysis.partial')
                                : '',
                            'p2': rhythmSeconds(
                              summary.turn.timeResolutionMs,
                              copy: AppCopy.of(context),
                            ),
                          },
                        ),
                      ),
                      if (summary.turn.reasons.isNotEmpty)
                        Text(summary.turn.reasons.join(' · ')),
                      FButton(
                        mainAxisSize: MainAxisSize.min,
                        key: const ValueKey('rhythm-open-source'),
                        variant: FButtonVariant.outline,
                        onPress: () => widget.onOpen(summary),
                        child: Text(
                          AppCopy.of(context)
                              .text('analysis.openSourceAnalysis'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      );
    },
  );
}
