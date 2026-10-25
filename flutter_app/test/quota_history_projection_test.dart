import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_projection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final start = DateTime.utc(2026, 10, 1);
DateTime utcDisplay(DateTime time) => time.toUtc();

QuotaHistoryFilter filter({
  String? segment = 's',
  String? bucket = 'codex',
  UsageWindowRole? role = UsageWindowRole.primary,
  int? duration = 300,
  DateTime? from,
  DateTime? to,
  QuotaHistoryHeatmapMetric metric = QuotaHistoryHeatmapMetric.minimumRemaining,
}) => QuotaHistoryFilter(
  sourceId: 'profile-a',
  segmentId: segment,
  bucketId: bucket,
  role: role,
  durationMinutes: duration,
  fromUtc: from ?? start,
  toUtc: to ?? start.add(const Duration(hours: 4)),
  heatmapMetric: metric,
);

QueryHistoryRecord row(
  int seq,
  int seconds, {
  double used = 20,
  String source = 'profile-a',
  String segment = 's',
  String run = 'r',
  String? attemptId,
  int? duration = 300,
  UsageWindowRole role = UsageWindowRole.primary,
  String bucket = 'codex',
  QueryHistoryOutcome outcome = QueryHistoryOutcome.success,
  bool storageGap = false,
  int? resetSeconds,
  int interval = 120,
  QuotaHistoryWindowQuality quality = QuotaHistoryWindowQuality.valid,
}) => QueryHistoryRecord(
  attemptId: attemptId ?? '$run:$seq',
  sourceId: source,
  segmentId: segment,
  startedAtMs: start.add(Duration(seconds: seconds - 1)).millisecondsSinceEpoch,
  completedAtMs: start.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
  timeQuality: UsageObservationTimeQuality.nativeCompletion,
  expectedIntervalSec: interval,
  outcome: outcome,
  storageGapBefore: storageGap,
  windows: outcome == QueryHistoryOutcome.success
      ? [
          QuotaHistoryWindow(
            bucketId: bucket,
            role: role,
            durationMinutes: duration,
            usedPercent: used,
            resetsAtMs: resetSeconds == null
                ? null
                : start
                      .add(Duration(seconds: resetSeconds))
                      .millisecondsSinceEpoch,
            quality: quality,
          ),
        ]
      : [],
);

QuotaHistoryProjection project(
  List<QueryHistoryRecord> records, {
  QuotaHistoryFilter? selection,
  int columns = 1200,
}) => projectQuotaHistory(
  records,
  selection ?? filter(),
  toDisplayTime: utcDisplay,
  maxPlotColumns: columns,
);

void main() {
  test('unrecognized attempt IDs cannot masquerade as a known run', () {
    final p = project([row(1, 0), row(1, 120, attemptId: 'r'), row(2, 240)]);
    expect(p.sampleCount, 3);
    expect(
      p.events.where((e) => e.kind == QuotaHistoryEventKind.clockReversal),
      isEmpty,
    );
    expect(
      p.gaps.map((g) => g.reason),
      contains(QuotaHistoryGapReason.runChanged),
    );
  });
  test(
    'selectors discover exact windows but never merge unselected curves',
    () {
      final records = [
        row(1, 0),
        row(2, 120, duration: null),
        row(3, 240, segment: 'old'),
        row(4, 360, role: UsageWindowRole.secondary),
      ];
      for (final selection in [
        filter(segment: null),
        filter(bucket: null),
        filter(role: null),
      ]) {
        final p = project(records, selection: selection);
        expect(p.requiresSelection, isTrue);
        expect(p.sampleCount, 0);
        expect(p.trendSegments, isEmpty);
        expect(p.availableSegmentIds, containsAll(['s', 'old']));
      }
      expect(
        project(records, selection: filter(duration: null)).sampleCount,
        1,
      );
      expect(project(records).sampleCount, 1);
    },
  );

  test(
    'failure no-limits changed-window segment role and storage remain barriers',
    () {
      final barriers = [
        row(2, 120, outcome: QueryHistoryOutcome.failure),
        row(2, 120, outcome: QueryHistoryOutcome.noLimits),
        row(2, 120, duration: 60),
        row(2, 120, duration: null),
        row(2, 120, segment: 'old'),
        row(2, 120, bucket: 'other'),
        row(2, 120, role: UsageWindowRole.secondary),
        row(2, 120, quality: QuotaHistoryWindowQuality.unknown),
      ];
      for (final barrier in barriers) {
        final p = project([row(1, 0), barrier, row(3, 240)]);
        expect(p.sampleCount, 2);
        expect(
          p.trendSegments.any((s) => s.connectToPrevious),
          isFalse,
          reason: '${barrier.outcome}/${barrier.windows}',
        );
        expect(p.gaps, isNotEmpty);
      }
      final p = project([row(1, 0), row(2, 120, storageGap: true)]);
      expect(p.trendSegments.any((s) => s.connectToPrevious), isFalse);
      expect(
        p.gaps.map((g) => g.reason),
        contains(QuotaHistoryGapReason.storage),
      );
    },
  );

  test(
    'facts describe adjacent observation intervals without declaring a reset',
    () {
      final p = project([
        row(1, 0, used: 80, resetSeconds: 100),
        row(2, 120, used: 10, resetSeconds: 900),
      ]);
      expect(
        p.events.map((e) => e.kind),
        containsAll([
          QuotaHistoryEventKind.usedDecrease,
          QuotaHistoryEventKind.reportedResetChanged,
          QuotaHistoryEventKind.crossedReportedReset,
        ]),
      );
      final decrease = p.events.firstWhere(
        (e) => e.kind == QuotaHistoryEventKind.usedDecrease,
      );
      expect(decrease.deltaPercentagePoints, -70);
      expect(decrease.fromUtc, start);
      expect(decrease.toUtc, start.add(const Duration(seconds: 120)));
      expect(project([row(1, 0), row(2, 240)]).gaps, isEmpty);
      expect(
        project([row(1, 0), row(2, 241)]).gaps.single.reason,
        QuotaHistoryGapReason.unobserved,
      );
    },
  );

  test(
    'sequence identifies clock reversal across day-file ordering before layout',
    () {
      // Store UTC-day order puts sequence 3 before sequence 1/2.
      final p = project([
        row(3, -10),
        row(1, 100),
        row(2, 220),
        row(4, 130),
      ], selection: filter(from: start.subtract(const Duration(days: 1))));
      expect(
        p.events.where((e) => e.kind == QuotaHistoryEventKind.clockReversal),
        hasLength(1),
      );
      expect(p.gaps.every((g) => !g.toUtc.isBefore(g.fromUtc)), isTrue);
      final points = {
        for (final point in p.trendSegments.expand((s) => s.points))
          point.attemptId: point,
      };
      expect(points['r:1']!.spanId, points['r:2']!.spanId);
      expect(points['r:3']!.spanId, points['r:4']!.spanId);
      expect(points['r:2']!.spanId, isNot(points['r:3']!.spanId));
      for (var i = 1; i < p.trendSegments.length; i++) {
        if (p.trendSegments[i].connectToPrevious) {
          expect(
            p.trendSegments[i - 1].points.last.spanId,
            p.trendSegments[i].points.first.spanId,
          );
        }
      }
      final restarted = project([row(1, 0), row(1, 120, run: 'restart')]);
      expect(restarted.trendSegments.any((s) => s.connectToPrevious), isFalse);
    },
  );

  test(
    'hour values use raw low or last and retain unknown and failure overlay',
    () {
      final records = [
        row(1, 0, used: 90),
        row(2, 120, used: 10),
        row(3, 240, outcome: QueryHistoryOutcome.failure),
        row(4, 7200, used: 35),
      ];
      final low = project(records);
      expect(low.hourCells.first.observedRemaining, 10);
      expect(low.hourCells.first.sampleCount, 2);
      expect(low.hourCells.first.failureCount, 1);
      expect(low.hourCells.first.hasGap, isTrue);
      expect(low.hourCells[1].observedRemaining, isNull);
      expect(low.hourCells[1].sampleCount, 0);
      expect(low.hourCells[2].sampleCount, 1);
      expect(
        low.hourCells[2].firstObservedUtc,
        start.add(const Duration(hours: 2)),
      );
      final last = project(
        records,
        selection: filter(metric: QuotaHistoryHeatmapMetric.lastRemaining),
      );
      expect(last.hourCells.first.observedRemaining, 90);
      expect(low.sampleCount, 3);
    },
  );

  test(
    'midnight and repeated daylight-saving hour retain distinct offset cells',
    () {
      tzdata.initializeTimeZones();
      final location = tz.getLocation('America/New_York');
      final from = DateTime.utc(2026, 11, 1, 3, 30);
      final to = DateTime.utc(2026, 11, 1, 7, 30);
      final records = [
        for (var i = 0; i < 3; i++)
          row(
            i + 1,
            DateTime.utc(2026, 11, 1, 4 + i, 30).difference(start).inSeconds,
          ),
      ];
      final p = projectQuotaHistory(
        records,
        filter(from: from, to: to),
        toDisplayTime: (u) => tz.TZDateTime.from(u, location),
      );
      expect(p.hourCells.first.localDate, '2026-10-31');
      final repeated = p.hourCells.where((c) => c.localHour == 1).toList();
      expect(repeated, hasLength(2));
      expect(repeated.map((c) => c.utcOffsetMinutes), [-240, -300]);
      expect(repeated.map((c) => c.sampleCount), [1, 1]);
    },
  );

  test(
    '100k multi-source observations preserve raw counts with bounded geometry',
    () {
      final records = [
        for (var i = 0; i < 100000; i++)
          row(
            i + 1,
            i * 25,
            source: i.isEven ? 'profile-a' : 'profile-b',
            used: i == 50000 ? 99 : (i % 90).toDouble(),
            interval: 120,
          ),
      ];
      final p = project(
        records,
        selection: filter(to: start.add(const Duration(days: 30))),
      );
      expect(p.sampleCount, 50000);
      expect(p.hourCells.fold<int>(0, (n, c) => n + c.sampleCount), 50000);
      expect(p.trendSegments.length, lessThanOrEqualTo(1200));
      expect(
        p.trendSegments.fold<int>(0, (n, s) => n + s.points.length),
        lessThanOrEqualTo(4800),
      );
      expect(
        p.trendSegments.expand((s) => s.points).map((p) => p.usedPercent),
        contains(99),
      );
      expect(p.trendSegments.first.points.first.completedAtUtc, start);
      expect(
        p.trendSegments.last.points.last.completedAtUtc,
        start.add(const Duration(seconds: 2499950)),
      );
    },
  );

  test('many disconnected spans in one column stay bounded and never join', () {
    final p = project([
      for (var i = 0; i < 10000; i++)
        row(
          i + 1,
          i,
          outcome: i.isEven
              ? QueryHistoryOutcome.success
              : QueryHistoryOutcome.failure,
        ),
    ], columns: 1);
    expect(p.sampleCount, 5000);
    expect(p.trendSegments, hasLength(1));
    expect(p.trendSegments.single.hasInternalGaps, isTrue);
    expect(p.trendSegments.single.spanCount, 5000);
    expect(p.trendSegments.single.points.length, lessThanOrEqualTo(4));
    expect(p.trendSegments.single.connectToPrevious, isFalse);
  });
}
