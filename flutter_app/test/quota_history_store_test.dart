import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

QueryHistoryRecord row(
  String id,
  DateTime time, {
  String source = 'profile-a',
  QueryHistoryOutcome outcome = QueryHistoryOutcome.success,
}) => QueryHistoryRecord(
  attemptId: id,
  sourceId: source,
  segmentId: 'segment-fixture',
  startedAtMs: time.millisecondsSinceEpoch - 100,
  completedAtMs: time.millisecondsSinceEpoch,
  timeQuality: UsageObservationTimeQuality.nativeCompletion,
  expectedIntervalSec: 120,
  outcome: outcome,
  errorKind: outcome == QueryHistoryOutcome.failure ? 'network' : null,
  windows: outcome == QueryHistoryOutcome.success
      ? [
          const QuotaHistoryWindow(
            bucketId: 'codex',
            role: UsageWindowRole.primary,
            usedPercent: 50,
            durationMinutes: 300,
            quality: QuotaHistoryWindowQuality.valid,
          ),
        ]
      : [],
);
QuotaHistoryFilter range({
  String source = 'profile-a',
  DateTime? from,
  DateTime? to,
}) => QuotaHistoryFilter(
  sourceId: source,
  fromUtc: from ?? DateTime.utc(2026, 9, 1),
  toUtc: to ?? DateTime.utc(2026, 11, 1),
  segmentId: 'deliberately-absent',
  bucketId: 'absent',
  role: UsageWindowRole.secondary,
  durationMinutes: 7,
);
void main() {
  late Directory temp;
  final now = DateTime.utc(2026, 10, 25);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('quota-history-owned-');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'UTC day append and read keep barriers and deduplicate attempt IDs',
    () async {
      final store = QuotaHistoryStore(temp, now: () => now);
      final first = row('run:1', DateTime.utc(2026, 10, 24, 23, 59));
      await store.append(first);
      await store.append(first);
      await store.append(
        row('run:2', now, outcome: QueryHistoryOutcome.failure),
      );
      await store.append(
        row(
          'run:3',
          now.add(const Duration(minutes: 2)),
          outcome: QueryHistoryOutcome.noLimits,
        ),
      );
      await store.append(row('run:4', now.add(const Duration(minutes: 4))));
      await store.append(row('other:1', now, source: 'profile-b'));
      await store.flush();
      final read = await store.read(range());
      expect(read.records.map((r) => r.attemptId), [
        'run:1',
        'run:2',
        'run:3',
        'run:4',
      ]);
      expect(read.records[1].windows, isEmpty);
      expect(read.hasStorageGaps, isFalse);
      expect(
        await File('${temp.path}/profile-a/2026-10-24.jsonl').exists(),
        isTrue,
      );
      expect(
        await File('${temp.path}/profile-a/2026-10-25.jsonl').exists(),
        isTrue,
      );
      expect(
        (await store.read(
          range(from: now, to: now.add(const Duration(minutes: 3))),
        )).records.map((r) => r.attemptId),
        ['run:2', 'run:3'],
      );
    },
  );
  test(
    'broken tail is preserved and new increasing parts remain readable',
    () async {
      final directory = Directory('${temp.path}/profile-a');
      await directory.create();
      final main = File('${directory.path}/2026-10-25.jsonl');
      final original = '${jsonEncode(row('run:1', now).toJson())}\n{broken';
      await main.writeAsString(original);
      final store = QuotaHistoryStore(temp, now: () => now);
      await store.append(row('run:2', now.add(const Duration(minutes: 2))));
      expect(await main.readAsString(), original);
      final part = File('${directory.path}/2026-10-25.part-001.jsonl');
      expect(await part.exists(), isTrue);
      await part.writeAsString('{bad-tail', mode: FileMode.append);
      await store.append(row('run:3', now.add(const Duration(minutes: 4))));
      expect(
        await File('${directory.path}/2026-10-25.part-002.jsonl').exists(),
        isTrue,
      );
      final read = await store.read(range());
      expect(read.records.map((r) => r.attemptId), ['run:1', 'run:2', 'run:3']);
      expect(read.hasStorageGaps, isTrue);
      expect(read.records[1].storageGapBefore, isTrue);
      expect(read.records[2].storageGapBefore, isTrue);
    },
  );
  test('bad middle line and duplicate after corruption cannot hide storage barrier', () async {
    final directory = Directory('${temp.path}/profile-a');
    await directory.create();
    final a = jsonEncode(row('run:1', now).toJson());
    final b = jsonEncode(
      row('run:2', now.add(const Duration(minutes: 2))).toJson(),
    );
    await File('${directory.path}/2026-10-25.jsonl')
        .writeAsString('$a\nnot json\n$a\n$b\n');
    final read = await QuotaHistoryStore(temp, now: () => now).read(range());
    expect(read.hasStorageGaps, isTrue);
    expect(read.records, hasLength(2));
    expect(read.records.last.storageGapBefore, isTrue);
  });
  test('invalid UTF8 row preserves neighboring facts and creates a storage barrier', () async {
    final source = Directory('${temp.path}/profile-a');
    await source.create();
    await File('${source.path}/2026-10-25.jsonl').writeAsBytes([
      ...utf8.encode('${jsonEncode(row('run:1', now).toJson())}\n'),
      0xff,
      10,
      ...utf8.encode(
        '${jsonEncode(row('run:2', now.add(const Duration(minutes: 2))).toJson())}\n',
      ),
    ]);
    final read = await QuotaHistoryStore(temp, now: () => now).read(range());
    expect(read.records.map((r) => r.attemptId), ['run:1', 'run:2']);
    expect(read.hasStorageGaps, isTrue);
    expect(read.records.last.storageGapBefore, isTrue);
  });
  test('startup retention includes current plus 29 UTC days and whole-day count targets', () async {
    for (final (day, ids) in [
      (25, ['run:1']),
      (26, ['run:2']),
      (27, ['run:3', 'run:4']),
    ]) {
      final directory = Directory('${temp.path}/profile-a');
      await directory.create(recursive: true);
      final time = DateTime.utc(2026, 9, day);
      await File('${directory.path}/2026-09-$day.jsonl').writeAsString(
        '${ids.map((id) => jsonEncode(row(id, time).toJson())).join('\n')}\n',
      );
    }
    final store = QuotaHistoryStore(
      temp,
      now: () => now,
      perSourceTarget: 2,
      globalTarget: 100,
    );
    await store.flush();
    final read = await store.read(range());
    expect(read.records.map((r) => r.attemptId), ['run:3', 'run:4']);
    expect(
      await File('${temp.path}/profile-a/2026-09-25.jsonl').exists(),
      isFalse,
    );
    expect(
      await File('${temp.path}/profile-a/2026-09-26.jsonl').exists(),
      isFalse,
    );
  });
  for (final memory in [false, true]) {
    test('UTC date retention alone drops day 31 and keeps day 30 memory=$memory', () async {
      var clock = DateTime.utc(2026, 9, 25);
      final store = memory
          ? QuotaHistoryStore.memory(
              now: () => clock,
              perSourceTarget: 1000,
              globalTarget: 10000,
            )
          : QuotaHistoryStore(
              temp,
              now: () => now,
              perSourceTarget: 1000,
              globalTarget: 10000,
            );
      final rows = [
        row('run:1', DateTime.utc(2026, 9, 25, 23, 59, 59)),
        row('run:2', DateTime.utc(2026, 9, 26)),
        row('run:3', now),
      ];
      if (memory) {
        for (final record in rows) {
          await store.append(record);
        }
        clock = now;
      } else {
        final source = Directory('${temp.path}/profile-a');
        await source.create();
        for (final (index, date) in [
          '2026-09-25',
          '2026-09-26',
          '2026-10-25',
        ].indexed) {
          await File('${source.path}/$date.jsonl')
              .writeAsString('${jsonEncode(rows[index].toJson())}\n');
        }
      }
      await store.flush();
      expect(
        (await store.read(range())).records.map((r) => r.attemptId),
        ['run:2', 'run:3'],
        reason:
            'Date-only retention must use UTC midnight; actual Dart local offset at fixture date is ${DateTime(2026, 10, 25).timeZoneOffset}',
      );
      if (!memory) {
        expect(
          await File('${temp.path}/profile-a/2026-09-25.jsonl').exists(),
          isFalse,
        );
        expect(
          await File('${temp.path}/profile-a/2026-09-26.jsonl').exists(),
          isTrue,
        );
      }
    });
  }
  test('same-day parts count together and global trimming deletes oldest whole days', () async {
    final directory = Directory('${temp.path}/profile-a');
    await directory.create();
    final old = now.subtract(const Duration(days: 1));
    await File('${directory.path}/2026-10-24.jsonl')
        .writeAsString('${jsonEncode(row('run:1', old).toJson())}\n');
    await File('${directory.path}/2026-10-24.part-001.jsonl')
        .writeAsString('${jsonEncode(row('run:2', old).toJson())}\n');
    final b = Directory('${temp.path}/profile-b');
    await b.create();
    await File('${b.path}/2026-10-25.jsonl').writeAsString(
      '${jsonEncode(row('run:3', now, source: 'profile-b').toJson())}\n',
    );
    final store = QuotaHistoryStore(
      temp,
      now: () => now,
      perSourceTarget: 100,
      globalTarget: 2,
    );
    await store.flush();
    expect((await store.read(range())).records, isEmpty);
    expect(
      await File('${directory.path}/2026-10-24.part-001.jsonl').exists(),
      isFalse,
    );
    expect(
      (await store.read(range(source: 'profile-b'))).records,
      hasLength(1),
    );
  });
  test(
    'targets may temporarily overflow but UTC rollover cleans oldest days',
    () async {
      var clock = now;
      final store = QuotaHistoryStore(
        temp,
        now: () => clock,
        perSourceTarget: 2,
        globalTarget: 100,
      );
      for (var i = 1; i <= 3; i++) {
        await store.append(row('run:$i', now));
      }
      expect((await store.read(range())).records, hasLength(3));
      clock = now.add(const Duration(days: 1));
      await store.append(row('run:4', clock));
      expect((await store.read(range())).records.map((r) => r.attemptId), [
        'run:4',
      ]);
    },
  );
  test(
    'failed write does not poison queue and next append can recover',
    () async {
      final blocker = File('${temp.path}/profile-a');
      await blocker.writeAsString('owned blocker');
      final store = QuotaHistoryStore(temp, now: () => now);
      await expectLater(
        store.append(row('run:1', now)),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      await store.append(row('run:2', now));
      expect((await store.read(range())).records.single.attemptId, 'run:2');
      await store.flush();
    },
  );
  test(
    'remove queues after accepted appends and does not touch sibling source',
    () async {
      final store = QuotaHistoryStore(temp, now: () => now);
      final appending = store.append(row('run:1', now));
      final remove = store.removeSource('profile-a');
      final other = store.append(row('run:2', now, source: 'profile-b'));
      await Future.wait([appending, remove, other]);
      expect(await Directory('${temp.path}/profile-a').exists(), isFalse);
      expect(
        (await store.read(range(source: 'profile-b'))).records,
        hasLength(1),
      );
      await expectLater(store.removeSource('../outside'), throwsArgumentError);
    },
  );
  test('memory store follows same dedup range and removal semantics', () async {
    final store = QuotaHistoryStore.memory(now: () => now);
    await store.append(row('run:1', now));
    await store.append(row('run:1', now));
    expect((await store.read(range())).records, hasLength(1));
    await store.removeSource('profile-a');
    expect((await store.read(range())).records, isEmpty);
  });
}
