import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_activity_timeline.dart';
import 'monitor_presentation.dart';
import 'session_activity_timeline.dart';

/// Persisted item intervals describe client activity, not decoder execution.
class SessionTimingPanel extends StatelessWidget {
  const SessionTimingPanel({
    super.key,
    required this.analysis,
    this.durationMs,
    this.firstTokenMs,
    this.turnIdentity,
  });
  final Map<String, dynamic>? analysis;
  final Object? durationMs, firstTokenMs, turnIdentity;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    final validDuration = SessionActivityTimelineData.isSafeMilliseconds(
      durationMs,
    );
    final recordedFirst = SessionActivityTimelineData.isSafeMilliseconds(
      firstTokenMs,
    );
    final firstContradictsDuration =
        recordedFirst &&
        validDuration &&
        (firstTokenMs as int) > (durationMs as int);
    final validFirst = recordedFirst && !firstContradictsDuration;
    final canSubtractFirst = validDuration && validFirst;
    String milliseconds(int value) => '${(value / 1000).toStringAsFixed(3)} s';
    String time(String key) => a?[key] is num
        ? '${((a![key] as num) / 1000).toStringAsFixed(3)} s'
        : AppCopy.of(context).text('analysis.unavailable');
    final match = a?['usageMatchesTurn'];
    final reconciliation = match == true
        ? AppCopy.of(context).text('analysis.matched')
        : match == false
        ? AppCopy.of(context).text('analysis.mismatched')
        : AppCopy.of(context).text('analysis.notVerifiable');
    final responses = (a?['recentResponses'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text(
          AppCopy.of(context).text('analysis.activityTimelineLastTurn'),
          style: context.theme.typography.display.sm,
        ),
        if (a == null || a['partial'] == true)
          Text(
            AppCopy.of(context)
                .text('analysis.timingDataIncompleteOrUnverifiable'),
          ),
        if (match == false)
          Text(
            AppCopy.of(context)
                .text('analysis.responseUsageDoesNotMatchTheTurn'),
          ),
        Text(
          AppCopy.of(context).text(
            'analysis.overlapUnclassifiedDoesNotIdentifyWaiting',
            args: {'p0': time('overlapMs'), 'p1': time('unclassifiedMs')},
          ),
        ),
        SessionActivityTimeline(
          key: const ValueKey('session-activity-timeline'),
          data: SessionActivityTimelineData.fromAnalysis(a),
          identity: turnIdentity,
        ),
        MonitorDisclosure(
          key: const ValueKey('session-timing-disclosure'),
          label: AppCopy.of(context).text('analysis.timingAndDefinitions'),
          toggleKey: const ValueKey('session-timing-details'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                AppCopy.of(context)
                    .text('analysis.readOnlyTimingAnalysisLastTurn'),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.firstModelTokenWait2',
                  args: {
                    'p0': validFirst
                        ? milliseconds(firstTokenMs as int)
                        : firstContradictsDuration
                        ? AppCopy.of(context).text(
                            'analysis.unavailableExceedsCompleteTurnDuration',
                          )
                        : AppCopy.of(context).text('analysis.unavailable'),
                  },
                ),
                key: const ValueKey('session-first-model-wait'),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.turnDurationAfterFirstModelToken',
                  args: {
                    'p0': canSubtractFirst
                        ? milliseconds(
                            (durationMs as int) - (firstTokenMs as int),
                          )
                        : AppCopy.of(context).text('analysis.unavailable'),
                  },
                ),
                key: const ValueKey('session-after-first-duration'),
              ),
              Text(
                AppCopy.of(context)
                    .text('analysis.theFirstModelTokenMayBeReasoning'),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.recordedResponsesTotalOutputTokensTurnTotal',
                  args: {
                    'p0':
                        a?['responseCount'] ??
                        AppCopy.of(context).text('analysis.unavailable'),
                    'p1':
                        a?['responseOutputTokens'] ??
                        AppCopy.of(context).text('analysis.unavailable'),
                    'p2': reconciliation,
                  },
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.messageItemsReasoningItems',
                  args: {'p0': time('messageMs'), 'p1': time('reasoningMs')},
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.toolItemsOtherItems',
                  args: {'p0': time('toolMs'), 'p1': time('otherMs')},
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.activityIntervalUnionCrossCategoryOverlap',
                  args: {'p0': time('observedMs'), 'p1': time('overlapMs')},
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.unclassifiedTime',
                  args: {'p0': time('unclassifiedMs')},
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'analysis.overlapsAreMergedWithinEachCategoryCategories',
                ),
              ),
              if (a == null || a['partial'] == true)
                Text(
                  AppCopy.of(context).text(
                    'analysis.missingReversedItemsZeroDurationOutsideBounds',
                    args: {
                      'p0': a?['invalidItems'] ?? 0,
                      'p1': a?['zeroItems'] ?? 0,
                      'p2': a?['outOfBoundsItems'] ?? 0,
                      'p3': a?['missingIdentityRecords'] ?? 0,
                      'p4': a?['truncated'] == true
                          ? AppCopy.of(context)
                                .text('analysis.collectionLimitReached')
                          : '',
                    },
                  ),
                ),
              Text(
                AppCopy.of(context)
                    .text('analysis.timingComesFromLoggedItemBoundariesTurn'),
              ),
            ],
          ),
        ),
        if (responses.isNotEmpty)
          MonitorDisclosure(
            key: const ValueKey('session-response-disclosure'),
            label: AppCopy.of(context).text('analysis.recentResponseUsageUpTo'),
            toggleKey: const ValueKey('session-response-details'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final response in responses)
                  Text(
                    AppCopy.of(context).text(
                      'analysis.outputReasoningTokens',
                      args: {
                        'p0': response['responseId'],
                        'p1':
                            response['outputTokens'] ??
                            AppCopy.of(context).text('analysis.unavailable'),
                        'p2':
                            response['reasoningTokens'] ??
                            AppCopy.of(context).text('analysis.unavailable'),
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
