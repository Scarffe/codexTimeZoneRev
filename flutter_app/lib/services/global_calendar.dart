import 'session_rhythm_projection.dart' show RhythmCalendar;

class GlobalCivilBuckets {
  GlobalCivilBuckets(List<int> edges, this.daysPerBucket)
    : edges = List.unmodifiable(edges);
  final List<int> edges;
  final int daysPerBucket;
}

/// Cover the indexed extent with at most90 local-calendar groups. Boundaries
/// use civil-midnight construction; elapsed24h steps are incorrect across DST.
GlobalCivilBuckets globalCivilBuckets(
  int fromMs,
  int toMs, {
  RhythmCalendar? calendar,
}) {
  if (fromMs >= toMs) throw ArgumentError('invalid_global_extent');
  final cal = calendar ?? RhythmCalendar.system();
  final first = cal.toLocal(
    DateTime.fromMillisecondsSinceEpoch(fromMs, isUtc: true),
  );
  final last = cal.toLocal(
    DateTime.fromMillisecondsSinceEpoch(toMs - 1, isUtc: true),
  );
  final startDate = DateTime.utc(first.year, first.month, first.day);
  final endDate = DateTime.utc(last.year, last.month, last.day + 1);
  final days = endDate.difference(startDate).inDays;
  final step = (days + 89) ~/ 90;
  final edges = <int>[];
  void add(DateTime midnight) {
    // Native log timestamps are unsigned. A partial first calendar day can
    // begin at the epoch; skipped civil dates must not duplicate an edge.
    final milliseconds = midnight.millisecondsSinceEpoch;
    final edge = milliseconds < 0 ? 0 : milliseconds;
    if (edges.isEmpty || edge > edges.last) edges.add(edge);
  }

  for (var offset = 0; offset < days; offset += step) {
    add(cal.localDate(first.year, first.month, first.day + offset));
  }
  add(cal.localDate(last.year, last.month, last.day + 1));
  return GlobalCivilBuckets(edges, step);
}
