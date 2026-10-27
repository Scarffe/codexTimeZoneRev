import 'package:codex_timezone/services/global_calendar.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';
import 'package:flutter_test/flutter_test.dart';

final _utc = RhythmCalendar(
  toLocal: (instant) => instant.toUtc(),
  localDate: (year, month, day) => DateTime.utc(year, month, day),
);

final _utcPlus8 = RhythmCalendar(
  toLocal: (instant) => instant.add(const Duration(hours: 8)),
  localDate: (year, month, day) =>
      DateTime.utc(year, month, day).subtract(const Duration(hours: 8)),
);

RhythmCalendar _newYorkSpring() {
  final transition = DateTime.utc(2026, 3, 8, 7);
  return RhythmCalendar(
    toLocal: (instant) =>
        instant.subtract(Duration(hours: instant.isBefore(transition) ? 5 : 4)),
    localDate: (year, month, day) {
      final date = DateTime.utc(year, month, day);
      return date.add(
        Duration(hours: date.isBefore(DateTime.utc(2026, 3, 9)) ? 5 : 4),
      );
    },
  );
}

RhythmCalendar _newYorkFall() {
  final transition = DateTime.utc(2026, 11, 1, 6);
  return RhythmCalendar(
    toLocal: (instant) =>
        instant.subtract(Duration(hours: instant.isBefore(transition) ? 4 : 5)),
    localDate: (year, month, day) {
      final date = DateTime.utc(year, month, day);
      return date.add(
        Duration(hours: date.isBefore(DateTime.utc(2026, 11, 2)) ? 4 : 5),
      );
    },
  );
}

List<DateTime> _utcEdges(GlobalCivilBuckets buckets) => [
  for (final edge in buckets.edges)
    DateTime.fromMillisecondsSinceEpoch(edge, isUtc: true),
];

void _expectLocalMidnights(
  GlobalCivilBuckets buckets,
  RhythmCalendar calendar,
) {
  expect(buckets.edges.length - 1, lessThanOrEqualTo(90));
  for (var index = 0; index < buckets.edges.length; index++) {
    if (index > 0) {
      expect(buckets.edges[index], greaterThan(buckets.edges[index - 1]));
    }
    final local = calendar.toLocal(
      DateTime.fromMillisecondsSinceEpoch(buckets.edges[index], isUtc: true),
    );
    expect(
      [local.hour, local.minute, local.second, local.millisecond],
      [0, 0, 0, 0],
    );
  }
}

void main() {
  test('UTC+8 extent crossing local midnight covers both civil dates', () {
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 10, 26, 15, 30).millisecondsSinceEpoch,
      DateTime.utc(2026, 10, 26, 16, 30).millisecondsSinceEpoch,
      calendar: _utcPlus8,
    );

    expect(buckets.daysPerBucket, 1);
    expect(_utcEdges(buckets), [
      DateTime.utc(2026, 10, 25, 16),
      DateTime.utc(2026, 10, 26, 16),
      DateTime.utc(2026, 10, 27, 16),
    ]);
    _expectLocalMidnights(buckets, _utcPlus8);
  });

  test('exactly 90 UTC dates retain 90 one-day groups', () {
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      DateTime.utc(2026, 4, 1).millisecondsSinceEpoch,
      calendar: _utc,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 1);
    expect(edges, hasLength(91));
    expect(edges.first, DateTime.utc(2026, 1, 1));
    expect(edges[1], DateTime.utc(2026, 1, 2));
    expect(edges[89], DateTime.utc(2026, 3, 31));
    expect(edges.last, DateTime.utc(2026, 4, 1));
    _expectLocalMidnights(buckets, _utc);
  });

  test('91 UTC dates form 46 two-day groups with a one-day last group', () {
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      DateTime.utc(2026, 4, 2).millisecondsSinceEpoch,
      calendar: _utc,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 2);
    expect(edges, hasLength(47));
    expect(edges.first, DateTime.utc(2026, 1, 1));
    expect(edges[1], DateTime.utc(2026, 1, 3));
    expect(edges[45], DateTime.utc(2026, 4, 1));
    expect(edges.last, DateTime.utc(2026, 4, 2));
    _expectLocalMidnights(buckets, _utc);
  });

  test('181 UTC dates form 61 three-day groups with a one-day last group', () {
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
      calendar: _utc,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 3);
    expect(edges, hasLength(62));
    expect(edges.first, DateTime.utc(2026, 1, 1));
    expect(edges[1], DateTime.utc(2026, 1, 4));
    expect(edges[60], DateTime.utc(2026, 6, 30));
    expect(edges.last, DateTime.utc(2026, 7, 1));
    _expectLocalMidnights(buckets, _utc);
  });

  test('New York spring civil day uses its literal 23-hour boundaries', () {
    final calendar = _newYorkSpring();
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 3, 8, 5).millisecondsSinceEpoch,
      DateTime.utc(2026, 3, 9, 4).millisecondsSinceEpoch,
      calendar: calendar,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 1);
    expect(edges, [DateTime.utc(2026, 3, 8, 5), DateTime.utc(2026, 3, 9, 4)]);
    expect(edges.last.difference(edges.first), const Duration(hours: 23));
    _expectLocalMidnights(buckets, calendar);
  });

  test('New York fall civil day uses its literal 25-hour boundaries', () {
    final calendar = _newYorkFall();
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 11, 1, 4).millisecondsSinceEpoch,
      DateTime.utc(2026, 11, 2, 5).millisecondsSinceEpoch,
      calendar: calendar,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 1);
    expect(edges, [DateTime.utc(2026, 11, 1, 4), DateTime.utc(2026, 11, 2, 5)]);
    expect(edges.last.difference(edges.first), const Duration(hours: 25));
    _expectLocalMidnights(buckets, calendar);
  });

  test('spring multi-day groups stay at midnight across the 47-hour pair', () {
    final calendar = _newYorkSpring();
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 1, 1, 5).millisecondsSinceEpoch,
      DateTime.utc(2026, 4, 2, 4).millisecondsSinceEpoch,
      calendar: calendar,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 2);
    expect(edges, hasLength(47));
    expect(edges.first, DateTime.utc(2026, 1, 1, 5));
    expect(edges[33], DateTime.utc(2026, 3, 8, 5));
    expect(edges[34], DateTime.utc(2026, 3, 10, 4));
    expect(edges[34].difference(edges[33]), const Duration(hours: 47));
    expect(edges.last, DateTime.utc(2026, 4, 2, 4));
    _expectLocalMidnights(buckets, calendar);
  });

  test('fall multi-day groups stay at midnight across the 49-hour pair', () {
    final calendar = _newYorkFall();
    final buckets = globalCivilBuckets(
      DateTime.utc(2026, 9, 1, 4).millisecondsSinceEpoch,
      DateTime.utc(2026, 12, 1, 5).millisecondsSinceEpoch,
      calendar: calendar,
    );
    final edges = _utcEdges(buckets);

    expect(buckets.daysPerBucket, 2);
    expect(edges, hasLength(47));
    expect(edges.first, DateTime.utc(2026, 9, 1, 4));
    expect(edges[30], DateTime.utc(2026, 10, 31, 4));
    expect(edges[31], DateTime.utc(2026, 11, 2, 5));
    expect(edges[31].difference(edges[30]), const Duration(hours: 49));
    expect(edges.last, DateTime.utc(2026, 12, 1, 5));
    _expectLocalMidnights(buckets, calendar);
  });

  test('partial first UTC+8 civil day clamps its pre-epoch start to zero', () {
    final buckets = globalCivilBuckets(0, 3600000, calendar: _utcPlus8);

    expect(buckets.daysPerBucket, 1);
    expect(buckets.edges, [0, 57600000]);
  });
}
