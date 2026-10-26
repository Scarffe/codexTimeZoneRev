import '../l10n/copy_analysis.dart';
import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_activity_timeline.dart';

/// The last completed turn's persisted item activity, never a live token chart.
class SessionActivityTimeline extends StatefulWidget {
  const SessionActivityTimeline({
    super.key,
    required this.data,
    required this.identity,
  });
  final SessionActivityTimelineData data;
  final Object? identity;
  @override
  State<SessionActivityTimeline> createState() =>
      _SessionActivityTimelineState();
}

class _SessionActivityTimelineState extends State<SessionActivityTimeline> {
  bool _expanded = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant SessionActivityTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _time(int? value) => value == null
      ? AppCopy.of(context).text('analysis.unknown')
      : '${(value / 1000).toStringAsFixed(3)} s';

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (!data.available) {
      return Text(AppCopy.of(context).timelineDescription(data));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          AppCopy.of(context)
              .text('analysis.lastCompletedSelectedTurnLoggedIntervalsAbout'),
        ),
        Text(
          AppCopy.of(context)
              .text('analysis.fourCategoriesMayOverlapShadingMarksApproximate'),
        ),
        if (data.sourcePartial)
          Text(
            AppCopy.of(context)
                .text('analysis.partialSourceOnlyRecordedFactsAreShown'),
          ),
        if (data.spanMs != null) ...[
          const SizedBox(height: 8),
          _TimelineBands(data: data),
        ] else
          Text(
            AppCopy.of(context)
                .text('analysis.turnBoundariesAreUnverifiableTextFactsAre'),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            expanded: _expanded,
            child: FButton(
              key: const ValueKey('session-timeline-toggle'),
              mainAxisSize: MainAxisSize.min,
              variant: FButtonVariant.ghost,
              onPress: () => setState(() => _expanded = !_expanded),
              prefix: Icon(
                _expanded
                    ? FLucideIcons.chevronDown
                    : FLucideIcons.chevronRight,
              ),
              child: Text(
                AppCopy.of(context).text('analysis.rawActivityRecords'),
              ),
            ),
          ),
        ),
        Offstage(
          offstage: !_expanded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppCopy.of(context).timelineDescription(data)),
              Text(
                AppCopy.of(context)
                    .text('analysis.theFourCategoriesCanOverlapAndCannot'),
              ),
              if (data.omittedItems > 0)
                Text(
                  AppCopy.of(context).text(
                    'analysis.showingItemsChronologicallyOmittedAggregatesStillUse',
                    args: {'p0': data.rows.length, 'p1': data.omittedItems},
                  ),
                ),
              if (data.coverageInterpretation == 'unavailable')
                Text(
                  AppCopy.of(context)
                      .text('analysis.coverageCannotBeInterpretedNoBlankSpace'),
                ),
              if (data.spanMs != null)
                Text(
                  AppCopy.of(
                    context,
                  ).text('analysis.theApproximateWindowDiffersFromActualTurn'),
                ),
              Text(
                AppCopy.of(
                  context,
                ).text('analysis.textRecordsScrollableBoundariesAreUnixEpoch'),
              ),
              SizedBox(
                height: 210,
                child: ListView.builder(
                  key: const ValueKey('session-timeline-list'),
                  controller: _scroll,
                  itemCount: data.rows.length,
                  itemBuilder: (context, i) {
                    final row = data.rows[i];
                    final offset = AppCopy.of(context).text(
                      'analysis.offset',
                      args: {
                        'p0': _time(row.offsetStartMs),
                        'p1': _time(row.offsetEndMs),
                      },
                    );
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        AppCopy.of(context).text(
                          'analysis.recordedStartRecordedEndUnixEpochMilliseconds',
                          args: {
                            'p0': AppCopy.of(context).timelineRowLabel(row),
                            'p1':
                                row.startedAtMs ??
                                AppCopy.of(context).text('analysis.unknown'),
                            'p2':
                                row.completedAtMs ??
                                AppCopy.of(context).text('analysis.unknown'),
                            'p3': offset,
                            'p4': _time(row.durationMs),
                            'p5': row.drawable
                                ? ''
                                : AppCopy.of(context).text('analysis.notDrawn'),
                            'p6':
                                AppCopy.of(context)
                                    .timelineRowReasons(row)
                                    .isEmpty
                                ? ''
                                : ' · ${AppCopy.of(context).timelineRowReasons(row)}',
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimelineBands extends StatelessWidget {
  const _TimelineBands({required this.data});
  final SessionActivityTimelineData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final span = data.spanMs!;
    final uncertainty = (data.boundsResolutionMs / span).clamp(0.0, 1.0);
    const categories = ['message', 'reasoning', 'tool', 'other'];
    final labels = [
      AppCopy.of(context).text('analysis.message'),
      AppCopy.of(context).text('analysis.reasoning'),
      AppCopy.of(context).text('analysis.tool'),
      AppCopy.of(context).text('analysis.other'),
    ];
    // Labels and equivalent text records carry meaning independently of color.
    const accents = [
      Color(0xff3b82f6),
      Color(0xffa855f7),
      Color(0xff14b8a6),
      Color(0xfff59e0b),
    ];
    return Semantics(
      label: AppCopy.of(context)
          .text('analysis.approximateTimelineOfFourLogCategoriesActivity'),
      child: Column(
        key: const ValueKey('session-timeline-chart'),
        children: [
          for (var c = 0; c < categories.length; c++)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 66,
                    child: Text(
                      AppCopy.of(context)
                          .text('analysis.items', args: {'p0': labels[c]}),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        return SizedBox(
                          height: 30,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.muted.withValues(alpha: 0.45),
                              border: Border.all(color: colors.border),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: ClipRect(
                              child: Stack(
                                children: [
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: width * uncertainty,
                                    child: ColoredBox(
                                      color: colors.foreground.withValues(
                                        alpha: 0.15,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: width * uncertainty,
                                    child: ColoredBox(
                                      color: colors.foreground.withValues(
                                        alpha: 0.15,
                                      ),
                                    ),
                                  ),
                                  for (final row in data.rows.where(
                                    (r) =>
                                        r.category == categories[c] &&
                                        r.drawable,
                                  ))
                                    Positioned(
                                      left: width * row.offsetStartMs! / span,
                                      width:
                                          width *
                                          (row.offsetEndMs! -
                                              row.offsetStartMs!) /
                                          span,
                                      top: 4 + (row.ordinal % 3) * 6,
                                      height: 8,
                                      child: Semantics(
                                        label: AppCopy.of(context)
                                            .timelineRowLabel(row),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: accents[c].withValues(
                                              alpha: 0.8,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 66),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                const Text('0.000 s'),
                Text(
                  AppCopy.of(context).text(
                    'analysis.sApproximateWindow',
                    args: {'p0': (span / 1000).toStringAsFixed(3)},
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
