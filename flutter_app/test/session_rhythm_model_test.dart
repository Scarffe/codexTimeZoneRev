import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:codex_timezone/services/session_rhythm.dart';

Map<String, dynamic> fact(
  int n, {
  int? end,
  int? start,
  String status = 'completed',
  int? duration = 1000,
  List<List<int>> intervals = const [],
  bool available = true,
}) => {
  'order': n,
  'turnId': 'turn$n',
  'status': status,
  'startedAtMs': start,
  'completedAtMs': end,
  'timeResolutionMs': 1,
  'durationMs': duration,
  'firstTokenMs': null,
  'activityIntervals': intervals,
  'activityAvailable': available,
  'partial': false,
  'reasons': <String>[],
};
const sourceA = RhythmSource(
  path: r'C:\synthetic\a.jsonl',
  sessionId: 'a',
  title: 'A',
);
const sourceB = RhythmSource(
  path: r'C:\synthetic\b.jsonl',
  sessionId: 'b',
  title: 'B',
);
RhythmTurn row(
  int n, {
  RhythmSource source = sourceA,
  int? end,
  int? start,
  String status = 'completed',
  int? duration = 1000,
  List<List<int>> intervals = const [],
  bool available = true,
}) => RhythmTurn.fromJson(
  fact(
    n,
    end: end,
    start: start,
    status: status,
    duration: duration,
    intervals: intervals,
    available: available,
  ),
  sourceKey: source.key,
);

void main() {
  test('unknown cache schema rejected', () {
    expect(
      () => RhythmCache.fromJson({'schemaVersion': 2}),
      throwsFormatException,
    );
  });
  test('native fact whitelist and unknown nulls survive roundtrip', () {
    final input = fact(1)
      ..addAll({
        'text': 'SECRET',
        'command': 'SECRET',
        'arguments': {'secret': true},
        'itemId': 'SECRET',
        'responseId': 'SECRET',
        'account': 'SECRET',
      });
    final value = RhythmTurn.fromJson(input, sourceKey: sourceA.key);
    expect(value.completedAtMs, isNull);
    expect(jsonEncode(value.toJson()), isNot(contains('SECRET')));
    expect(value.toJson().keys.toSet(), {
      'sourceKey',
      'order',
      'turnId',
      'status',
      'startedAtMs',
      'completedAtMs',
      'timeResolutionMs',
      'durationMs',
      'firstTokenMs',
      'activityIntervals',
      'activityAvailable',
      'partial',
      'reasons',
    });
    expect(RhythmTurn.fromJson(value.toJson()).turnId, 'turn1');
  });
  test('path normalization keeps expected identity separate', () {
    expect(
      const RhythmSource(
        path: r'c:\SYNTHETIC\x\..\a.jsonl',
        sessionId: 'a',
        title: 'rename',
      ).key,
      sourceA.key,
    );
    expect(
      const RhythmSource(
        path: r'C:\synthetic\a.jsonl',
        sessionId: 'new',
        title: 'A',
      ).key,
      isNot(sourceA.key),
    );
  });
  test('cache deduplicates by source and turn and rejects orphan facts', () {
    final json = {
      'schemaVersion': 1,
      'sources': [sourceA.toJson()],
      'turns': [row(1).toJson(), row(1).toJson()],
      'lastReadMs': <String, dynamic>{},
      'truncatedSources': <String>[],
    };
    expect(RhythmCache.fromJson(json).turns.length, 1);
    json['turns'] = [row(1, source: sourceB).toJson()];
    expect(() => RhythmCache.fromJson(json), throwsFormatException);
  });
  test('invalid intervals cannot become valid numeric activity', () {
    expect(
      () => RhythmTurn.fromJson(
        fact(
          1,
          intervals: [
            [10, 9],
          ],
        ),
        sourceKey: sourceA.key,
      ),
      throwsFormatException,
    );
    expect(
      () => RhythmTurn.fromJson(
        fact(1)..['durationMs'] = -1,
        sourceKey: sourceA.key,
      ),
      throwsFormatException,
    );
  });
}
