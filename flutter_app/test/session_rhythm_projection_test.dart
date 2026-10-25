import 'package:flutter_test/flutter_test.dart';

import 'package:codex_timezone/services/session_rhythm.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';

import 'session_rhythm_model_test.dart' show sourceA, sourceB, row;

final utcCalendar = RhythmCalendar(
  toLocal: (t) => t.toUtc(),
  localDate: (y, m, d) => DateTime.utc(y, m, d),
);
void main() {
  final now = DateTime.utc(2026, 10, 25, 12),
      midnight = DateTime.utc(2026, 10, 25).millisecondsSinceEpoch;
  test(
    'cross midnight clips hours and cross source activity is union not sum',
    () {
      final a = midnight - 300000, b = midnight + 300000;
      final result = projectSessionRhythm(
        RhythmCache(
          sources: [sourceA, sourceB],
          turns: [
            row(
              1,
              start: a,
              end: b,
              intervals: [
                [a, b],
              ],
            ),
            row(
              1,
              source: sourceB,
              start: a,
              end: b,
              intervals: [
                [a, b],
              ],
            ),
          ],
        ),
        now: now,
        calendar: utcCalendar,
      );
      expect(result.activityMs, 600000);
      expect(result.lanes.map((l) => l.activityMs), [600000, 600000]);
      expect(
        result.hours
            .where((h) => h.activityMs != null)
            .map((h) => h.activityMs),
        [300000, 300000],
      );
      expect(result.completedCount, 2);
    },
  );
  test('R7 distribution only completed; fewer than 5 only points', () {
    for (final count in [4, 5, 1000]) {
      final result = projectSessionRhythm(
        RhythmCache(
          sources: [sourceA],
          turns: [
            for (var n = 1; n <= count; n++)
              row(n, end: midnight, duration: n * 1000),
            row(1001, status: 'cancelled', end: midnight, duration: 999999),
          ],
        ),
        now: now,
        calendar: utcCalendar,
        maxPlotPoints: 16,
      );
      expect(result.distribution.count, count);
      expect(result.distribution.showBox, count >= 5);
      expect(result.distribution.medianMs, (count + 1) * 500.0);
      expect(result.distribution.q1Ms, (1 + (count - 1) * .25) * 1000);
      expect(result.distribution.q3Ms, (1 + (count - 1) * .75) * 1000);
      expect(result.distribution.pointsMs.length, lessThanOrEqualTo(16));
    }
  });
  test(
    'unknown date, invalid activity, cancel and truncation stay explicit',
    () {
      final result = projectSessionRhythm(
        RhythmCache(
          sources: [sourceA],
          turns: [
            row(1, end: midnight, status: 'cancelled'),
            row(2, available: false),
          ],
          truncatedSources: {sourceA.key},
        ),
        now: now,
        calendar: utcCalendar,
      );
      expect(result.cancelledCount, 1);
      expect(result.unknownTimeCount, 1);
    expect(result.lanes.single.turns.length, 2);
      expect(result.truncated, true);
      expect(result.activityMs, isNull);
      expect(result.hours.where((h) => h.completedCount > 0), isEmpty);
    },
  );
  test('hour selection clips lanes and duration membership without reread', () {
    final cache = RhythmCache(
      sources: [sourceA],
      turns: [
        row(
          1,
          start: midnight - 1000,
          end: midnight + 1000,
          intervals: [
            [midnight - 1000, midnight + 1000],
          ],
        ),
        row(2, end: midnight + 7200000),
      ],
    );
    final all = projectSessionRhythm(cache, now: now, calendar: utcCalendar);
    final selected = all.hours.firstWhere((h) => h.startMs == midnight);
    final result = projectSessionRhythm(
      cache,
      now: now,
      calendar: utcCalendar,
      selectedHour: selected,
    );
    expect(result.completedCount, 1);
    expect(result.activityMs, 1000);
    expect(result.distribution.count, 1);
  });
  test(
    'local calendar uses civil midnight and distinguishes repeated DST hour',
    () {
      // Synthetic New York fall-back: Nov1 06:00Z changes UTC-4 to UTC-5.
      final transition = DateTime.utc(2026, 11, 1, 6);
      final cal = RhythmCalendar(
        toLocal: (t) =>
            t.subtract(Duration(hours: t.isBefore(transition) ? 4 : 5)),
        localDate: (y, m, d) => DateTime.utc(y, m, d).add(
          Duration(
            hours: DateTime.utc(y, m, d).isBefore(DateTime.utc(2026, 11, 2))
                ? 4
                : 5,
          ),
        ),
      );
      final end = DateTime.utc(2026, 11, 2, 5);
      final result = projectSessionRhythm(
        RhythmCache(),
        now: end,
        calendar: cal,
      );
      final day = result.hours
          .where(
            (h) =>
                h.localStart.year == 2026 &&
                h.localStart.month == 11 &&
                h.localStart.day == 1,
          )
          .toList();
      expect(day.length, 25);
      final repeated = day.where((h) => h.localStart.hour == 1).toList();
      expect(repeated.length, 2);
      expect(repeated[0].key, isNot(repeated[1].key));
      expect(result.fromUtc, DateTime.utc(2026, 10, 27, 4));
      expect(repeated[0].label, contains('UTC-04:00'));
      expect(repeated[1].label, contains('UTC-05:00'));
    },
  );
  test(
    'spring DST civil day has 23 hours and never fabricates the missing hour',
    () {
      final transition = DateTime.utc(2026, 3, 8, 7);
      final cal = RhythmCalendar(
        toLocal: (t) =>
            t.subtract(Duration(hours: t.isBefore(transition) ? 5 : 4)),
        localDate: (y, m, d) => DateTime.utc(y, m, d).add(
          Duration(
            hours: DateTime.utc(y, m, d).isBefore(DateTime.utc(2026, 3, 9))
                ? 5
                : 4,
          ),
        ),
      );
      final result = projectSessionRhythm(
        RhythmCache(),
        now: DateTime.utc(2026, 3, 9, 4),
        calendar: cal,
      );
      final day = result.hours
          .where((h) => h.localStart.month == 3 && h.localStart.day == 8)
          .toList();
      expect(day.length, 23);
      expect(day.where((h) => h.localStart.hour == 2), isEmpty);
    },
  );
}
