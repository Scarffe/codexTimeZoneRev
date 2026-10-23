import 'package:codex_timezone/services/session_activity_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_activity_fixture.dart';

void main() {
  SessionActivityTimelineData parse(Map<String, dynamic> value) =>
      SessionActivityTimelineData.fromAnalysis({'timeline': value});

  test('old DLL missing timeline stays unavailable without invented zero', () {
    for (final analysis in [
      null,
      <String, dynamic>{},
      {'timeline': 'bad'},
    ]) {
      final data = SessionActivityTimelineData.fromAnalysis(analysis);
      expect(data.available, false);
      expect(data.spanMs, isNull);
      expect(data.rows, isEmpty);
      expect(data.reasonText, contains('不可用'));
    }
  });

  test('overlapping categories preserve logged intervals and real counts', () {
    final data = parse(timelineFixture());
    expect(data.available, true);
    expect(data.rows.length, 4);
    expect(data.rows[0].offsetStartMs, 1000);
    expect(data.rows[1].offsetEndMs, 6010);
    expect(data.spanMs, 10000);
    expect(data.boundsResolutionMs, 1000);
    expect(data.coverageInterpretation, 'approximate');
  });

  test(
    'malformed and unsafe timeline fails closed without sanitizing counts',
    () {
      final mutations = <void Function(Map<String, dynamic>)>[
        (t) => t['version'] = 2,
        (t) => t['version'] = 1.0,
        (t) => t['coordinateKind'] = 'live_tokens',
        (t) => t['spanMs'] = 9007199254740992,
        (t) => t['spanMs'] = 10000.5,
        (t) => t['shownItems'] = 3,
        (t) => t['totalItems'] = 5,
        (t) => t['limit'] = 201,
        (t) => t['items'][0]['category'] = 'secret-category',
        (t) => t['items'][0]['offsetEndMs'] = 11000,
        (t) => t['items'][0]['durationMs'] = -1,
        (t) => t['items'][0]['ordinal'] = 0,
        (t) => t['items'][0]['ordinal'] = 1.0,
        (t) => t['items'][0]['startedAtMs'] = 109000,
        (t) => t['items'][0]['drawable'] = 'yes',
        (t) => t['items'] = 'bad',
        (t) => t['sourcePartial'] = null,
        (t) => t['coverageInterpretation'] = 'exact',
        (t) => t['items'][0]['reasons'] = ['x' * 1000],
        (t) => t['items'] = List.filled(201, t['items'][0]),
      ];
      for (final mutate in mutations) {
        final value = timelineFixture();
        mutate(value);
        expect(parse(value).available, false, reason: value.toString());
      }
    },
  );

  test(
    'out of order rows and incomplete approximate coverage are rejected',
    () {
      final unsorted = timelineFixture();
      final rows = unsorted['items'] as List;
      final first = rows.removeAt(0);
      rows.add(first);
      expect(parse(unsorted).available, false);
      for (final property in ['sourcePartial', 'omittedItems']) {
        final value = timelineFixture();
        value[property] = property == 'sourcePartial' ? true : 1;
        if (property == 'omittedItems') value['totalItems'] = 5;
        expect(parse(value).available, false);
      }
    },
  );

  test(
    'partial omitted and zero rows remain facts with safe reason labels',
    () {
      final value = timelineFixture(count: 200)
        ..['sourcePartial'] = true
        ..['coverageInterpretation'] = 'unavailable'
        ..['totalItems'] = 203
        ..['omittedItems'] = 3;
      final row = value['items'][199] as Map;
      row['completedAtMs'] = row['startedAtMs'];
      row['offsetEndMs'] = row['offsetStartMs'];
      row['durationMs'] = 0;
      row['drawable'] = false;
      row['reasons'] = ['zero_duration', 'secret_future_code'];
      final data = parse(value);
      expect(data.available, true);
      expect(data.sourcePartial, true);
      expect(data.omittedItems, 3);
      expect(data.rows.last.durationMs, 0);
      expect(data.rows.last.reasonText, contains('零时长'));
      expect(data.rows.last.reasonText, isNot(contains('secret_future_code')));
    },
  );

  test(
    'missing conservative bounds allow text facts but never drawable bars',
    () {
      final value = timelineFixture(count: 1)
        ..['startEpochMs'] = null
        ..['endEpochMsExclusive'] = null
        ..['spanMs'] = null
        ..['coverageInterpretation'] = 'unavailable';
      final row = value['items'][0] as Map;
      row['offsetStartMs'] = null;
      row['offsetEndMs'] = null;
      row['drawable'] = false;
      row['reasons'] = ['missing_turn_bounds'];
      final data = parse(value);
      expect(data.available, true);
      expect(data.spanMs, isNull);
      expect(data.rows.single.reasonText, contains('缺少回合边界'));
      row['drawable'] = true;
      expect(parse(value).available, false);
    },
  );

  test(
    'interval ending at exclusive axis edge and zero fact there are valid',
    () {
      final value = timelineFixture(count: 1);
      value['items'][0]['completedAtMs'] = 110000;
      value['items'][0]['offsetEndMs'] = 10000;
      value['items'][0]['durationMs'] = 9000;
      expect(parse(value).available, true);
      value['items'][0]['startedAtMs'] = 110000;
      value['items'][0]['offsetStartMs'] = 10000;
      value['items'][0]['durationMs'] = 0;
      value['items'][0]['drawable'] = false;
      value['items'][0]['reasons'] = ['zero_duration'];
      expect(parse(value).available, true);
    },
  );

  test(
    'all text rows reject duration contradictions regardless of drawability',
    () {
      for (final endpoints in <(int?, int?)>[
        (101000, 101000),
        (101000, 106000),
        (null, 106000),
        (101000, null),
        (106000, 101000),
      ]) {
        final value = timelineFixture(count: 1);
        final row = value['items'][0] as Map;
        row['startedAtMs'] = endpoints.$1;
        row['completedAtMs'] = endpoints.$2;
        row['offsetStartMs'] = null;
        row['offsetEndMs'] = null;
        row['drawable'] = false;
        row['durationMs'] = endpoints == (101000, 106000) ? 0 : 5000;
        row['reasons'] = ['zero_duration'];
        expect(
          parse(value).available,
          false,
          reason: 'contradictory text $endpoints',
        );
      }
    },
  );

  test('valid non-drawable zero outside reversed and missing endpoint facts survive', () {
    final cases = <(int?, int?, int?, String)>[
      (101000, 101000, 0, 'zero_duration'),
      (99000, 102000, 3000, 'outside_bounds'),
      (106000, 101000, null, 'reversed'),
      (null, 106000, null, 'missing_start'),
      (101000, null, null, 'missing_end'),
    ];
    for (final c in cases) {
      final value = timelineFixture(count: 1)
        ..['sourcePartial'] = true
        ..['coverageInterpretation'] = 'unavailable';
      final row = value['items'][0] as Map;
      row['startedAtMs'] = c.$1;
      row['completedAtMs'] = c.$2;
      row['durationMs'] = c.$3;
      row['offsetStartMs'] = null;
      row['offsetEndMs'] = null;
      row['drawable'] = false;
      row['reasons'] = [c.$4];
      final data = parse(value);
      expect(data.available, true, reason: '$c');
      expect(data.rows.single.startedAtMs, c.$1);
      expect(data.rows.single.completedAtMs, c.$2);
      expect(data.rows.single.durationMs, c.$3);
      expect(data.rows.single.drawable, false);
    }
  });
}
