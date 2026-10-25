import 'session_rhythm.dart';

/// Conversion and civil midnight construction share one timezone implementation.
class RhythmCalendar {
  const RhythmCalendar({required this.toLocal, required this.localDate});
  factory RhythmCalendar.system() => RhythmCalendar(
    toLocal: (t) => t.toLocal(),
    localDate: (y, m, d) => DateTime(y, m, d).toUtc(),
  );
  final DateTime Function(DateTime utc) toLocal;
  final DateTime Function(int year, int month, int day) localDate;
}

class RhythmHour {
  const RhythmHour({
    required this.startMs,
    required this.endMs,
    required this.localStart,
    this.completedCount = 0,
    this.cancelledCount = 0,
    this.activityMs,
    this.incomplete = false,
  });
  final int startMs, endMs;
  final DateTime localStart;
  final int completedCount, cancelledCount;
  final int? activityMs;
  final bool incomplete;
  String get key => '$startMs';
  int get utcOffsetMinutes =>
      (DateTime.utc(
            localStart.year,
            localStart.month,
            localStart.day,
            localStart.hour,
            localStart.minute,
          ).millisecondsSinceEpoch -
          startMs) ~/
      60000;
  String get label {
    final offset = utcOffsetMinutes, absolute = offset.abs();
    return '${localStart.toIso8601String().substring(0, 13)} UTC${offset < 0 ? '-' : '+'}${(absolute ~/ 60).toString().padLeft(2, '0')}:${(absolute % 60).toString().padLeft(2, '0')}';
  }
}

class RhythmDistribution {
  RhythmDistribution({
    required this.count,
    required this.pointsMs,
    this.minimumMs,
    this.q1Ms,
    this.medianMs,
    this.q3Ms,
    this.maximumMs,
  });
  final int count;
  final List<int> pointsMs;
  final double? minimumMs, q1Ms, medianMs, q3Ms, maximumMs;
  bool get showBox => count >= 5;
}

class RhythmLane {
  RhythmLane({
    required this.source,
    required this.turns,
    required this.intervals,
    required this.activityMs,
  });
  final RhythmSource source;
  final List<RhythmTurn> turns;
  final List<RhythmInterval> intervals;
  final int? activityMs;
}

class RhythmProjection {
  RhythmProjection({
    required this.fromUtc,
    required this.toUtc,
    required this.hours,
    required this.lanes,
    required this.distribution,
    required this.completedCount,
    required this.cancelledCount,
    required this.unknownTimeCount,
    required this.partialCount,
    required this.activityMs,
    required this.truncated,
  });
  final DateTime fromUtc, toUtc;
  final List<RhythmHour> hours;
  final List<RhythmLane> lanes;
  final RhythmDistribution distribution;
  final int completedCount, cancelledCount, unknownTimeCount, partialCount;
  final int? activityMs;
  final bool truncated;
}

/// Shared projection/retention boundary: civil dates use timezone-aware
/// midnight construction, while the 24-hour view is an elapsed-time window.
DateTime rhythmRangeStartUtc(
  DateTime now,
  RhythmRange range, {
  RhythmCalendar? calendar,
}) {
  final cal = calendar ?? RhythmCalendar.system(), end = now.toUtc();
  if (range == RhythmRange.hours24) {
    return end.subtract(const Duration(hours: 24));
  }
  final local = cal.toLocal(end);
  return cal
      .localDate(
        local.year,
        local.month,
        local.day - (range == RhythmRange.days7 ? 6 : 29),
      )
      .toUtc();
}

RhythmProjection projectSessionRhythm(
  RhythmCache cache, {
  required DateTime now,
  RhythmRange range = RhythmRange.days7,
  RhythmCalendar? calendar,
  RhythmHour? selectedHour,
  int maxPlotPoints = 512,
}) {
  if (maxPlotPoints < 2) {
    throw ArgumentError.value(maxPlotPoints, 'maxPlotPoints');
  }
  final cal = calendar ?? RhythmCalendar.system(), end = now.toUtc();
  final start = rhythmRangeStartUtc(end, range, calendar: cal);
  final startMs = start.millisecondsSinceEpoch,
      endMs = end.millisecondsSinceEpoch;
  final from = selectedHour == null
      ? startMs
      : selectedHour.startMs.clamp(startMs, endMs);
  final to = selectedHour == null
      ? endMs
      : selectedHour.endMs.clamp(startMs, endMs);
  bool dated(RhythmTurn t) =>
      t.completedAtMs != null &&
      t.completedAtMs! >= from &&
      t.completedAtMs! < to;
  bool related(RhythmTurn t) =>
      dated(t) ||
      (t.startedAtMs != null &&
          t.startedAtMs! >= from &&
          t.startedAtMs! < to) ||
      t.activityIntervals.any((i) => i.endMs > from && i.startMs < to);
  final seen = <String>{};
  final rows = cache.turns
      .where((t) => seen.add('${t.sourceKey}\u0000${t.turnId}'))
      .toList();
  final unknown = rows.where((t) => t.completedAtMs == null).length;
  // Undated quality facts cannot be placed in a date cell but must remain
  // selectable in the source lane for their status/missing-data summary.
  final inRange = rows
      .where(
        (t) => related(t) || (t.startedAtMs == null && t.completedAtMs == null),
      )
      .toList();
  final durations =
      rows
          .where(
            (t) =>
                dated(t) &&
                t.status == RhythmStatus.completed &&
                t.durationMs != null,
          )
          .map((t) => t.durationMs!)
          .toList()
        ..sort();
  final allIntervals = <RhythmInterval>[];
  final lanes = <RhythmLane>[];
  for (final source in cache.sources) {
    final sourceRows = inRange.where((t) => t.sourceKey == source.key).toList();
    final intervals = _union(
      [
        for (final row in sourceRows.where((t) => t.activityAvailable))
          ...row.activityIntervals,
      ],
      from,
      to,
    );
    allIntervals.addAll(intervals);
    lanes.add(
      RhythmLane(
        source: source,
        turns: List.unmodifiable(sourceRows),
        intervals: List.unmodifiable(intervals),
        activityMs: intervals.isEmpty ? null : _duration(intervals),
      ),
    );
  }
  final intervals = _union(allIntervals, from, to), hours = <RhythmHour>[];
  // Walk elapsed UTC hours, deriving each civil label afresh. Never add a
  // fixed 24h duration to a local midnight: fall-back days have 25 buckets.
  var cursor = startMs;
  final firstLocal = cal.toLocal(start);
  cursor -=
      (firstLocal.minute * 60000 +
      firstLocal.second * 1000 +
      firstLocal.millisecond);
  while (cursor < endMs) {
    final date = cal.toLocal(
      DateTime.fromMillisecondsSinceEpoch(cursor, isUtc: true),
    );
    final boundary =
        cursor +
        (60 - date.minute) * 60000 -
        date.second * 1000 -
        date.millisecond;
    final low = cursor < from ? from : cursor;
    final high = boundary > to ? to : boundary;
    final activity = low < high
        ? _union(intervals, low, high)
        : <RhythmInterval>[];
    final members = rows.where(
      (t) =>
          t.completedAtMs != null &&
          t.completedAtMs! >= low &&
          t.completedAtMs! < high,
    );
    hours.add(
      RhythmHour(
        startMs: cursor,
        endMs: boundary,
        localStart: date,
        completedCount: members
            .where((t) => t.status == RhythmStatus.completed)
            .length,
        cancelledCount: members
            .where((t) => t.status == RhythmStatus.cancelled)
            .length,
        activityMs: activity.isEmpty ? null : _duration(activity),
        incomplete:
            cache.truncatedSources.isNotEmpty ||
            rows.any(
              (t) =>
                  t.partial &&
                  (t.completedAtMs == null ||
                      (t.completedAtMs! >= cursor &&
                          t.completedAtMs! < boundary)),
            ),
      ),
    );
    cursor = boundary;
  }
  double? quantile(double fraction) {
    if (durations.isEmpty) return null;
    final index = (durations.length - 1) * fraction;
    final low = index.floor(), high = index.ceil();
    return durations[low] + (durations[high] - durations[low]) * (index - low);
  }

  // Evenly select drawing points only; quantiles and sample count use all facts.
  final points = durations.length <= maxPlotPoints
      ? durations
      : [
          for (var i = 0; i < maxPlotPoints; i++)
            durations[(i * (durations.length - 1) / (maxPlotPoints - 1))
                .round()],
        ];
  return RhythmProjection(
    fromUtc: DateTime.fromMillisecondsSinceEpoch(from, isUtc: true),
    toUtc: DateTime.fromMillisecondsSinceEpoch(to, isUtc: true),
    hours: List.unmodifiable(hours),
    lanes: List.unmodifiable(lanes),
    distribution: RhythmDistribution(
      count: durations.length,
      pointsMs: List.unmodifiable(points),
      minimumMs: quantile(0),
      q1Ms: quantile(.25),
      medianMs: quantile(.5),
      q3Ms: quantile(.75),
      maximumMs: quantile(1),
    ),
    completedCount: rows
        .where((t) => dated(t) && t.status == RhythmStatus.completed)
        .length,
    cancelledCount: rows
        .where((t) => dated(t) && t.status == RhythmStatus.cancelled)
        .length,
    unknownTimeCount: unknown,
    partialCount: rows.where((t) => t.partial).length,
    activityMs: intervals.isEmpty ? null : _duration(intervals),
    truncated: cache.truncatedSources.isNotEmpty,
  );
}

List<RhythmInterval> _union(List<RhythmInterval> input, int from, int to) {
  final clipped = [
    for (final i in input)
      if (i.endMs > from && i.startMs < to)
        RhythmInterval(
          i.startMs < from ? from : i.startMs,
          i.endMs > to ? to : i.endMs,
        ),
  ]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final result = <RhythmInterval>[];
  for (final interval in clipped) {
    if (result.isEmpty || interval.startMs > result.last.endMs) {
      result.add(interval);
    } else if (interval.endMs > result.last.endMs) {
      result[result.length - 1] = RhythmInterval(
        result.last.startMs,
        interval.endMs,
      );
    }
  }
  return result;
}

int _duration(List<RhythmInterval> intervals) =>
    intervals.fold(0, (sum, i) => sum + i.durationMs);
