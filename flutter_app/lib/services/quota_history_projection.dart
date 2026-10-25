import 'account_usage.dart';
import 'quota_history.dart';

DateTime _utc(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// Pure local projection. The input still contains unsuccessful/mismatched
/// observations: removing them before this call would erase continuity barriers.
QuotaHistoryProjection projectQuotaHistory(
  List<QueryHistoryRecord> records,
  QuotaHistoryFilter filter, {
  required DateTime Function(DateTime utc) toDisplayTime,
  int maxPlotColumns = 1200,
}) {
  final from = filter.fromUtc.toUtc(), to = filter.toUtc.toUtc();
  if (to.isBefore(from)) throw ArgumentError('Reversed history range');
  if (maxPlotColumns < 1) {
    throw ArgumentError.value(maxPlotColumns, 'maxPlotColumns');
  }
  final columns = maxPlotColumns.clamp(1, 1200);
  final seen = <String>{};
  final rows = records
      .where(
        (r) =>
            r.sourceId == filter.sourceId &&
            r.completedAtMs >= from.millisecondsSinceEpoch &&
            r.completedAtMs <= to.millisecondsSinceEpoch &&
            seen.add(r.attemptId),
      )
      .toList();
  final segments = <String>{}, series = <String, QuotaHistorySeries>{};
  int? actualMin, actualMax;
  for (final r in rows) {
    segments.add(r.segmentId);
    actualMin = actualMin == null || r.completedAtMs < actualMin
        ? r.completedAtMs
        : actualMin;
    actualMax = actualMax == null || r.completedAtMs > actualMax
        ? r.completedAtMs
        : actualMax;
    for (final w in r.windows) {
      final key =
          '${r.segmentId}\u0000${w.bucketId}\u0000${w.role.name}\u0000${w.durationMinutes}';
      series[key] = QuotaHistorySeries(
        r.segmentId,
        w.bucketId,
        w.role,
        w.durationMinutes,
      );
    }
  }
  final requiresSelection =
      filter.segmentId == null ||
      filter.bucketId == null ||
      filter.role == null;
  if (requiresSelection) {
    return QuotaHistoryProjection(
      requiresSelection: true,
      availableSegmentIds: segments.toList(),
      availableSeries: series.values.toList(),
      actualFromUtc: actualMin == null ? null : _utc(actualMin),
      actualToUtc: actualMax == null ? null : _utc(actualMax),
    );
  }

  // Day files are ordered by wall date, which can disagree with query order.
  // Reconstruct each run by monotonic sequence before examining its clock.
  // Runs remain separate: their wall clocks cannot establish continuity.
  final runs = <String, List<QueryHistoryRecord>>{};
  final sequences = <String, int>{};
  for (final r in rows) {
    final colon = r.attemptId.lastIndexOf(':');
    final sequence = colon < 1
        ? null
        : int.tryParse(r.attemptId.substring(colon + 1));
    final knownSequence = sequence != null && sequence > 0;
    final run = knownSequence
        ? 'run:${r.attemptId.substring(0, colon)}'
        : 'unknown:${r.attemptId}';
    sequences[r.attemptId] = sequence ?? 0;
    runs.putIfAbsent(run, () => []).add(r);
  }
  for (final run in runs.values) {
    run.sort(
      (a, b) => sequences[a.attemptId]!.compareTo(sequences[b.attemptId]!),
    );
  }

  final samples = <QuotaHistoryPoint>[],
      events = <QuotaHistoryEvent>[],
      gaps = <QuotaHistoryGap>[];
  final hours = <String, _Hour>{};
  _Hour hour(DateTime utc) {
    final local = toDisplayTime(utc);
    final date =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final offset = local.timeZoneOffset.inMinutes;
    final key = '$date/${local.hour}/$offset';
    final begin = utc.subtract(
      Duration(
        minutes: local.minute,
        seconds: local.second,
        milliseconds: local.millisecond,
        microseconds: local.microsecond,
      ),
    );
    return hours.putIfAbsent(key, () => _Hour(date, local.hour, offset, begin));
  }

  // Quarter-hour stepping also retains fractional-offset and half-hour DST
  // transitions; observations create their own exact offset cell as well.
  for (
    var cursor = from;
    !cursor.isAfter(to);
    cursor = cursor.add(const Duration(minutes: 15))
  ) {
    hour(cursor);
  }
  hour(to);
  var span = 0, failureCount = 0;
  DateTime? precedingRunTime;
  void gap(DateTime a, DateTime b, QuotaHistoryGapReason reason) => gaps.add(
    a.isAfter(b)
        ? QuotaHistoryGap(b, a, reason)
        : QuotaHistoryGap(a, b, reason),
  );

  for (final run in runs.values) {
    QueryHistoryRecord? previousRecord;
    QuotaHistoryPoint? previousSample;
    QuotaHistoryGapReason? pending;
    span++;
    for (final r in run) {
      final time = _utc(r.completedAtMs),
          previousTime = previousRecord == null
              ? null
              : _utc(previousRecord.completedAtMs);
      var breakBefore = false;
      if (previousRecord == null && precedingRunTime != null) {
        gap(precedingRunTime, time, QuotaHistoryGapReason.runChanged);
      }
      if (previousTime != null && time.isBefore(previousTime)) {
        gap(previousTime, time, QuotaHistoryGapReason.clockReversal);
        events.add(
          QuotaHistoryEvent(
            kind: QuotaHistoryEventKind.clockReversal,
            fromUtc: time,
            toUtc: previousTime,
          ),
        );
        breakBefore = true;
      }
      if (r.storageGapBefore) {
        gap(previousTime ?? time, time, QuotaHistoryGapReason.storage);
        breakBefore = true;
      }
      QuotaHistoryGapReason? invalid;
      QuotaHistoryWindow? window;
      if (r.segmentId != filter.segmentId) {
        invalid = QuotaHistoryGapReason.segmentChanged;
      } else if (r.outcome == QueryHistoryOutcome.failure) {
        invalid = QuotaHistoryGapReason.failure;
        failureCount++;
        hour(time).failures++;
        events.add(
          QuotaHistoryEvent(
            kind: QuotaHistoryEventKind.queryFailure,
            fromUtc: time,
            toUtc: time,
            errorKind: r.errorKind,
          ),
        );
      } else if (r.outcome == QueryHistoryOutcome.noLimits) {
        invalid = QuotaHistoryGapReason.noLimits;
        events.add(
          QuotaHistoryEvent(
            kind: QuotaHistoryEventKind.noLimits,
            fromUtc: time,
            toUtc: time,
          ),
        );
      } else {
        for (final w in r.windows) {
          if (w.bucketId == filter.bucketId &&
              w.role == filter.role &&
              w.durationMinutes == filter.durationMinutes &&
              w.role != UsageWindowRole.unknown &&
              w.quality == QuotaHistoryWindowQuality.valid &&
              w.usedPercent != null &&
              w.usedPercent!.isFinite &&
              w.usedPercent! >= 0 &&
              w.usedPercent! <= 100) {
            window = w;
            break;
          }
        }
        if (window == null) {
          invalid = QuotaHistoryGapReason.missingWindow;
          events.add(
            QuotaHistoryEvent(
              kind: QuotaHistoryEventKind.missingWindow,
              fromUtc: time,
              toUtc: time,
            ),
          );
        }
      }
      if (invalid != null) {
        gap(previousTime ?? time, time, invalid);
        previousSample = null;
        pending = invalid;
        span++;
      } else {
        if (pending != null) {
          gap(previousTime ?? time, time, pending);
          breakBefore = true;
        }
        if (previousSample != null && !breakBefore) {
          final distance = time
              .difference(previousSample.completedAtUtc)
              .inMilliseconds;
          final interval =
              r.expectedIntervalSec < previousSample.expectedIntervalSec
              ? r.expectedIntervalSec
              : previousSample.expectedIntervalSec;
          if (distance > interval * 2000) {
            gap(
              previousSample.completedAtUtc,
              time,
              QuotaHistoryGapReason.unobserved,
            );
            breakBefore = true;
          }
        }
        if (breakBefore) {
          span++;
          previousSample = null;
        }
        final point = QuotaHistoryPoint(
          attemptId: r.attemptId,
          completedAtUtc: time,
          usedPercent: window!.usedPercent!,
          spanId: span,
          timeQuality: r.timeQuality,
          expectedIntervalSec: r.expectedIntervalSec,
          resetsAtUtc: window.resetsAtMs == null
              ? null
              : _utc(window.resetsAtMs!),
        );
        if (previousSample != null) {
          final before = previousSample;
          final delta = point.usedPercent - before.usedPercent;
          if (delta != 0) {
            events.add(
              QuotaHistoryEvent(
                kind: delta > 0
                    ? QuotaHistoryEventKind.usedIncrease
                    : QuotaHistoryEventKind.usedDecrease,
                fromUtc: before.completedAtUtc,
                toUtc: time,
                deltaPercentagePoints: delta,
              ),
            );
          }
          if (before.resetsAtUtc != point.resetsAtUtc) {
            events.add(
              QuotaHistoryEvent(
                kind: QuotaHistoryEventKind.reportedResetChanged,
                fromUtc: before.completedAtUtc,
                toUtc: time,
                previousReportedResetUtc: before.resetsAtUtc,
                reportedResetUtc: point.resetsAtUtc,
              ),
            );
          }
          final reset = before.resetsAtUtc;
          if (reset != null &&
              reset.isAfter(before.completedAtUtc) &&
              !reset.isAfter(time)) {
            events.add(
              QuotaHistoryEvent(
                kind: QuotaHistoryEventKind.crossedReportedReset,
                fromUtc: before.completedAtUtc,
                toUtc: time,
                previousReportedResetUtc: reset,
                reportedResetUtc: point.resetsAtUtc,
              ),
            );
          }
        }
        samples.add(point);
        hour(time).add(point);
        previousSample = point;
        pending = null;
      }
      previousRecord = r;
    }
    precedingRunTime = previousRecord == null
        ? precedingRunTime
        : _utc(previousRecord.completedAtMs);
  }

  final sortedHours = hours.values.toList()
    ..sort((a, b) => a.from.compareTo(b.from));
  // Range additions mark gaps without scanning every hour for every event.
  final gapDelta = List<int>.filled(sortedHours.length + 1, 0);
  for (final g in gaps) {
    final first = _lowerBound(
      sortedHours.length,
      (i) =>
          sortedHours[i].from.add(const Duration(hours: 1)).isAfter(g.fromUtc),
    );
    final end = _lowerBound(
      sortedHours.length,
      (i) => sortedHours[i].from.isAfter(g.toUtc),
    );
    if (first < end) {
      gapDelta[first]++;
      gapDelta[end]--;
    }
  }
  var activeGaps = 0;
  final cells = <QuotaHistoryHourCell>[];
  for (var i = 0; i < sortedHours.length; i++) {
    activeGaps += gapDelta[i];
    cells.add(sortedHours[i].build(filter.heatmapMetric, activeGaps > 0));
  }
  final extent = to.millisecondsSinceEpoch - from.millisecondsSinceEpoch;
  int column(DateTime time) => extent == 0
      ? 0
      : (((time.millisecondsSinceEpoch - from.millisecondsSinceEpoch) *
                    columns) ~/
                extent)
            .clamp(0, columns - 1);
  final builders = <int, _Column>{};
  for (final point in samples) {
    builders.putIfAbsent(column(point.completedAtUtc), _Column.new).add(point);
  }
  final gapColumns = List<int>.filled(columns + 1, 0);
  for (final g in gaps) {
    gapColumns[column(g.fromUtc)]++;
    gapColumns[column(g.toUtc) + 1]--;
  }
  final marked = <int>{};
  var active = 0;
  for (var i = 0; i < columns; i++) {
    active += gapColumns[i];
    if (active > 0) marked.add(i);
  }
  final geometry = <QuotaHistoryTrendSegment>[];
  for (final key in builders.keys.toList()..sort()) {
    final builder = builders[key]!;
    final points = builder.points;
    final internal = builder.spans.length > 1 || marked.contains(key);
    final previous = geometry.lastOrNull;
    geometry.add(
      QuotaHistoryTrendSegment(
        column: key,
        points: points,
        spanCount: builder.spans.length,
        hasInternalGaps: internal,
        connectToPrevious:
            previous != null &&
            !internal &&
            !previous.hasInternalGaps &&
            previous.points.last.spanId == points.first.spanId,
      ),
    );
  }
  samples.sort((a, b) => a.completedAtUtc.compareTo(b.completedAtUtc));
  double? minimum, maximum;
  for (final point in samples) {
    final remaining = point.remainingPercent;
    minimum = minimum == null || remaining < minimum ? remaining : minimum;
    maximum = maximum == null || remaining > maximum ? remaining : maximum;
  }
  return QuotaHistoryProjection(
    requiresSelection: false,
    availableSegmentIds: segments.toList(),
    availableSeries: series.values.toList(),
    trendSegments: geometry,
    hourCells: cells,
    events: events,
    gaps: gaps,
    sampleCount: samples.length,
    failureCount: failureCount,
    actualFromUtc: actualMin == null ? null : _utc(actualMin),
    actualToUtc: actualMax == null ? null : _utc(actualMax),
    firstObservedUtc: samples.firstOrNull?.completedAtUtc,
    lastObservedUtc: samples.lastOrNull?.completedAtUtc,
    latestPoint: samples.lastOrNull,
    minimumRemaining: minimum,
    maximumRemaining: maximum,
  );
}

int _lowerBound(int length, bool Function(int) predicate) {
  var low = 0, high = length;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (predicate(mid)) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return low;
}

class _Hour {
  _Hour(this.date, this.hour, this.offset, this.from);
  final String date;
  final int hour, offset;
  final DateTime from;
  int count = 0, failures = 0;
  double? minimum, last;
  DateTime? firstTime, lastTime;
  void add(QuotaHistoryPoint point) {
    count++;
    final remaining = point.remainingPercent, time = point.completedAtUtc;
    if (minimum == null || remaining < minimum!) minimum = remaining;
    if (firstTime == null || time.isBefore(firstTime!)) firstTime = time;
    if (lastTime == null || !time.isBefore(lastTime!)) {
      lastTime = time;
      last = remaining;
    }
  }

  QuotaHistoryHourCell build(QuotaHistoryHeatmapMetric metric, bool gap) =>
      QuotaHistoryHourCell(
        localDate: date,
        localHour: hour,
        utcOffsetMinutes: offset,
        fromUtc: from,
        toUtc: from.add(const Duration(hours: 1)),
        sampleCount: count,
        failureCount: failures,
        hasGap: gap,
        observedRemaining: metric == QuotaHistoryHeatmapMetric.minimumRemaining
            ? minimum
            : last,
        firstObservedUtc: firstTime,
        lastObservedUtc: lastTime,
      );
}

class _Column {
  QuotaHistoryPoint? first, last, minimum, maximum;
  final spans = <int>{};
  void add(QuotaHistoryPoint point) {
    spans.add(point.spanId);
    if (first == null || point.completedAtUtc.isBefore(first!.completedAtUtc)) {
      first = point;
    }
    if (last == null || !point.completedAtUtc.isBefore(last!.completedAtUtc)) {
      last = point;
    }
    if (minimum == null || point.usedPercent < minimum!.usedPercent) {
      minimum = point;
    }
    if (maximum == null || point.usedPercent > maximum!.usedPercent) {
      maximum = point;
    }
  }

  List<QuotaHistoryPoint> get points {
    final unique = <String, QuotaHistoryPoint>{};
    for (final point in [first!, minimum!, maximum!, last!]) {
      unique[point.attemptId] = point;
    }
    return unique.values.toList()
      ..sort((a, b) => a.completedAtUtc.compareTo(b.completedAtUtc));
  }
}
