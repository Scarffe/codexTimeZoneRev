import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/session_rhythm.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';

import 'session_rhythm_model_test.dart' show sourceA, sourceB, fact, row;

class FakeRhythmBackend implements LauncherBackend {
  FakeRhythmBackend(this.handler);
  final FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>) handler;
  final calls = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    expect(command, 'session_metrics');
    expect(payload['action'], 'history');
    calls.add({...payload});
    return handler(payload);
  }
}

Map<String, dynamic> page({
  int epoch = 1,
  int revision = 1,
  bool catchingUp = false,
  bool changed = false,
  List<Map<String, dynamic>> records = const [],
  int? next,
  String id = 'a',
}) => {
  'historyVersion': 1,
  'sourceInfo': {'id': id},
  'logEpoch': epoch,
  'revision': revision,
  'catchingUp': catchingUp,
  'changed': changed,
  'records': records,
  'nextOrder': next,
};
final clock = DateTime.utc(2026, 10, 25, 12);
final end = clock.millisecondsSinceEpoch - 1000;
void main() {
  test('three explicit additions retain every serial read intent behind held A and B', () async {
    const sourceC = RhythmSource(
      path: r'C:\synthetic\c.jsonl',
      sessionId: 'c',
      title: 'C',
    );
    final heldA = Completer<Map<String, dynamic>>(),
        heldB = Completer<Map<String, dynamic>>();
    final aStarted = Completer<void>(), bStarted = Completer<void>();
    final backend = FakeRhythmBackend((p) {
      if (p['path'] == sourceA.path) {
        aStarted.complete();
        return heldA.future;
      }
      if (p['path'] == sourceB.path) {
        bStarted.complete();
        return heldB.future;
      }
      return page(
        id: 'c',
        records: [fact(3, end: end)],
      );
    });
    final c = SessionRhythmController(
      backend: backend,
      store: SessionRhythmStore.memory(),
      now: () => clock,
    );
    final first = c.addSource(sourceA);
    await aStarted.future;
    final second = c.addSource(sourceB);
    await Future<void>.delayed(Duration.zero);
    final third = c.addSource(sourceC);
    await Future<void>.delayed(Duration.zero);
    heldA.complete(page(records: [fact(1, end: end)]));
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls.map((p) => p['path']), [sourceA.path, sourceB.path]);
    expect(bStarted.isCompleted, true);
    heldB.complete(
      page(
        id: 'b',
        records: [fact(2, end: end)],
      ),
    );
    await Future.wait([first, second, third]);
    expect(backend.calls.map((p) => p['path']), [
      sourceA.path,
      sourceB.path,
      sourceC.path,
    ]);
    expect(c.turns.map((t) => t.sourceKey).toSet(), {
      sourceA.key,
      sourceB.key,
      sourceC.key,
    });
    expect(c.lastReadMsBySource.keys.toSet(), {
      sourceA.key,
      sourceB.key,
      sourceC.key,
    });
    expect(c.cacheStale, false);
    await c.shutdown();
  });
  test('concurrent same-path replacements are coherent while selection persistence is held', () async {
    final store = HeldWriteStore();
    final original = [
      sourceA,
      for (var n = 1; n <= 7; n++)
        RhythmSource(path: 'C:/synthetic/$n', sessionId: '$n', title: '$n'),
    ];
    await store.write(
      RhythmCache(
        sources: original,
        turns: [row(1, end: end)],
        lastReadMs: {sourceA.key: end},
        truncatedSources: {sourceA.key},
      ),
    );
    final c = SessionRhythmController(
      backend: FakeRhythmBackend((p) => page()),
      store: store,
      now: () => clock,
    );
    await c.initialize();
    final seen = <List<RhythmSource>>[];
    c.addListener(() => seen.add(c.sources.toList()));
    final gate = store.holdNext();
    const replacementB = RhythmSource(
      path: r'C:\synthetic\a.jsonl',
      sessionId: 'replacement-b',
      title: 'B',
    );
    const replacementC = RhythmSource(
      path: r'C:\synthetic\a.jsonl',
      sessionId: 'replacement-c',
      title: 'C',
    );
    final first = c.addSource(replacementB, refresh: false);
    await store.entered.future;
    final second = c.addSource(replacementC, refresh: false);
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([first, second]);
    expect(c.sources.length, 8);
    expect(
      c.sources.where((s) => s.path == sourceA.path).map((s) => s.sessionId),
      ['replacement-c'],
    );
    expect(c.turns, isEmpty);
    expect(c.lastReadMsBySource.containsKey(sourceA.key), false);
    expect(c.projection.truncated, false);
    expect(c.storageError, isNull);
    expect(seen.every((sources) => sources.length == 8), true);
    final saved = await store.read();
    expect(
      saved.sources.map((s) => s.key).toSet(),
      c.sources.map((s) => s.key).toSet(),
    );
    await c.shutdown();
  });
  test('refresh retains the first civil 30-day hour across fallback for projection and restart', () async {
    final transition = DateTime.utc(2026, 11, 1, 6);
    final calendar = RhythmCalendar(
      toLocal: (t) =>
          t.subtract(Duration(hours: t.isBefore(transition) ? 4 : 5)),
      localDate: (y, m, d) {
        final date = DateTime.utc(y, m, d);
        return date.add(
          Duration(hours: date.isBefore(DateTime.utc(2026, 11, 2)) ? 4 : 5),
        );
      },
    );
    final now = DateTime.utc(2026, 11, 3, 4, 30),
        start = DateTime.utc(2026, 10, 4, 4, 10).millisecondsSinceEpoch,
        terminal = DateTime.utc(2026, 10, 4, 4, 15).millisecondsSinceEpoch;
    final store = SessionRhythmStore.memory();
    final backend = FakeRhythmBackend(
      (p) => page(
        records: [
          fact(
            1,
            start: start,
            end: terminal,
            duration: 300000,
            available: false,
          ),
        ],
      ),
    );
    final c = SessionRhythmController(
      backend: backend,
      store: store,
      now: () => now,
      calendar: calendar,
    );
    await c.addSource(sourceA);
    c.setRange(RhythmRange.days30);
    expect(c.projection.fromUtc, DateTime.utc(2026, 10, 4, 4));
    expect(c.turns.length, 1);
    expect(c.projection.completedCount, 1);
    expect(c.projection.distribution.pointsMs, [300000]);
    expect(c.projection.hours.first.completedCount, 1);
    expect(c.projection.truncated, false);
    await c.shutdown();
    final restored = SessionRhythmController(
      backend: backend,
      store: store,
      now: () => now,
      calendar: calendar,
    );
    await restored.initialize();
    restored.setRange(RhythmRange.days30);
    expect(restored.projection.completedCount, 1);
    expect(backend.calls.length, 1);
    await restored.shutdown();
  });
  test(
    'cancel invalidates a source refresh queued behind another source',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final backend = FakeRhythmBackend((p) => gate.future);
      final c = SessionRhythmController(
        backend: backend,
        store: SessionRhythmStore.memory(),
        now: () => clock,
      );
      final first = c.addSource(sourceA);
      await Future<void>.delayed(Duration.zero);
      final second = c.addSource(sourceB);
      await Future<void>.delayed(Duration.zero);
      c.cancel();
      gate.complete(page(records: [fact(1, end: end)]));
      await Future.wait([first, second]);
      expect(backend.calls.length, 1);
      expect(c.turns, isEmpty);
      await c.shutdown();
    },
  );
  test(
    'source added during another read receives its own serial refresh',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final backend = FakeRhythmBackend(
        (p) => p['path'] == sourceA.path
            ? gate.future
            : page(
                id: 'b',
                records: [fact(2, end: end)],
              ),
      );
      final c = SessionRhythmController(
        backend: backend,
        store: SessionRhythmStore.memory(),
        now: () => clock,
      );
      final first = c.addSource(sourceA);
      await Future<void>.delayed(Duration.zero);
      final second = c.addSource(sourceB);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls.length, 1);
      gate.complete(page(records: [fact(1, end: end)]));
      await Future.wait([first, second]);
      expect(c.turns.length, 2);
      expect(backend.calls.length, 2);
      await c.shutdown();
    },
  );
  test('initialize cache calls no backend, refresh replaces after process epoch changes', () async {
    final store = SessionRhythmStore.memory();
    await store.write(
      RhythmCache(
        sources: [sourceA],
        turns: [row(1, end: end)],
        lastReadMs: {sourceA.key: end},
      ),
    );
    final backend = FakeRhythmBackend(
      (p) => page(epoch: 999, records: [fact(2, end: end)]),
    );
    final c = SessionRhythmController(
      backend: backend,
      store: store,
      now: () => clock,
    );
    await c.initialize();
    expect(backend.calls, isEmpty);
    expect(c.turns.single.turnId, 'turn1');
    expect(c.cacheStale, true);
    await c.refresh();
    expect(c.turns.single.turnId, 'turn2');
    expect(c.cacheStale, false);
    expect(c.lastRead, clock);
    c.setRange(RhythmRange.hours24);
    c.clearHour();
    expect(backend.calls.length, 1);
    await c.shutdown();
  });
  test(
    'all >64 pages use expected epoch/revision and catchingUp is chased first',
    () async {
      var count = 0;
      final backend = FakeRhythmBackend((p) {
        count++;
        if (count == 1) {
          return page(
            catchingUp: true,
            records: [fact(999, end: end)],
            next: 999,
          );
        }
        if (count == 2) {
          expect(p['afterOrder'], 0);
          return page(
            records: [for (var n = 1; n <= 64; n++) fact(n, end: end)],
            next: 64,
          );
        }
        expect(p['expectedEpoch'], 1);
        expect(p['expectedRevision'], 1);
        expect(p['afterOrder'], 64);
        return page(
          records: [for (var n = 65; n <= 130; n++) fact(n, end: end)],
        );
      });
      final c = SessionRhythmController(
        backend: backend,
        store: SessionRhythmStore.memory(),
        now: () => clock,
      );
      await c.addSource(sourceA);
      expect(c.turns.length, 130);
      expect(c.turns.any((t) => t.order == 999), false);
      await c.shutdown();
    },
  );
  test(
    'mixed page revisions retry once and preserve old cache on second mismatch',
    () async {
      var reads = 0;
      final backend = FakeRhythmBackend((p) {
        reads++;
        return p['afterOrder'] == 0
            ? page(records: [fact(2, end: end)], next: 2)
            : page(revision: 2, records: [fact(3, end: end)]);
      });
      final store = SessionRhythmStore.memory();
      await store.write(
        RhythmCache(
          sources: [sourceA],
          turns: [row(1, end: end)],
        ),
      );
      final c = SessionRhythmController(
        backend: backend,
        store: store,
        now: () => clock,
      );
      await c.initialize();
      await c.refresh();
      expect(reads, 4);
      expect(c.turns.single.turnId, 'turn1');
      expect(c.error, contains('日志更新中'));
      expect(c.cacheStale, true);
      await c.shutdown();
    },
  );
  test('epoch changes retry without mixing old pages then succeed', () async {
    var reads = 0;
    final backend = FakeRhythmBackend((p) {
      reads++;
      if (reads == 1) return page(records: [fact(1, end: end)], next: 1);
      if (reads == 2) return page(epoch: 2, changed: true);
      return page(epoch: 2, records: [fact(2, end: end)]);
    });
    final c = SessionRhythmController(
      backend: backend,
      store: SessionRhythmStore.memory(),
      now: () => clock,
    );
    await c.addSource(sourceA);
    expect(c.turns.map((t) => t.turnId), ['turn2']);
    expect(reads, 3);
    await c.shutdown();
  });
  test('cancel/remove ignore late backend and same-path wrong identity is rejected', () async {
    for (final remove in [false, true]) {
      final gate = Completer<Map<String, dynamic>>();
      final b = FakeRhythmBackend((p) => gate.future);
      final c = SessionRhythmController(
        backend: b,
        store: SessionRhythmStore.memory(),
        now: () => clock,
      );
      final work = c.addSource(sourceA);
      await Future<void>.delayed(Duration.zero);
      if (remove) {
        await c.removeSource(sourceA.key);
      } else {
        c.cancel();
      }
      gate.complete(page(records: [fact(1, end: end)]));
      await work;
      expect(c.turns, isEmpty);
      if (remove) expect(c.sources, isEmpty);
      await c.shutdown();
    }
    final c = SessionRhythmController(
      backend: FakeRhythmBackend(
        (p) => page(
          id: 'other',
          records: [fact(1, end: end)],
        ),
      ),
      store: SessionRhythmStore.memory(),
      now: () => clock,
    );
    await c.addSource(sourceA);
    expect(c.turns, isEmpty);
    expect(c.error, contains('来源'));
    await c.shutdown();
  });
  test('eight sources, 30 day retention and 25000 cap are explicit', () async {
    final records = [
      fact(1, end: end - 31 * 86400000),
      for (var n = 2; n <= 25002; n++) fact(n, end: end),
      fact(25003, end: null),
    ];
    final b = FakeRhythmBackend((p) {
      final after = p['afterOrder'] as int;
      final stop = (after + 256).clamp(0, records.length);
      return page(
        records: records.sublist(after, stop),
        next: stop < records.length ? stop : null,
      );
    });
    final c = SessionRhythmController(
      backend: b,
      store: SessionRhythmStore.memory(),
      now: () => clock,
    );
    await c.addSource(sourceA);
    expect(c.turns.length, 25000);
    expect(c.turns.any((r) => r.order == 1), false);
    expect(c.projection.truncated, true);
    expect(c.projection.unknownTimeCount, 1);
    for (var n = 1; n <= 7; n++) {
      await c.addSource(
        RhythmSource(path: 'C:/synthetic/$n', sessionId: '$n', title: '$n'),
        refresh: false,
      );
    }
    await expectLater(c.addSource(sourceB, refresh: false), throwsStateError);
    await c.shutdown();
  });
  test(
    'corrupt store read blocks overwrite until explicit rebuild refresh',
    () async {
      final store = BrokenStore(readFails: true);
      final c = SessionRhythmController(
        backend: FakeRhythmBackend((p) => page(records: [fact(1, end: end)])),
        store: store,
        now: () => clock,
      );
      await c.initialize();
      expect(c.storageError, isNotNull);
      expect(store.writes, 0);
      await c.shutdown();
      expect(store.writes, 0);
    },
  );
  test(
    'save errors isolated from successful history; sources refresh serially',
    () async {
      var active = 0, maxActive = 0;
      final b = FakeRhythmBackend((p) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return page(
          id: p['path'] == sourceA.path ? 'a' : 'b',
          records: [fact(1, end: end)],
        );
      });
      final c = SessionRhythmController(
        backend: b,
        store: BrokenStore(),
        now: () => clock,
      );
      await c.addSource(sourceA, refresh: false);
      await c.addSource(sourceB, refresh: false);
      await c.refresh();
      expect(maxActive, 1);
      expect(c.turns.length, 2);
      expect(c.error, isNull);
      expect(c.storageError, isNotNull);
      await c.shutdown();
    },
  );
  test(
    'same path replacement works at eight sources and removes previous facts',
    () async {
      final c = SessionRhythmController(
        backend: FakeRhythmBackend((p) => page(records: [fact(1, end: end)])),
        store: SessionRhythmStore.memory(),
        now: () => clock,
      );
      await c.addSource(sourceA);
      for (var n = 1; n <= 7; n++) {
        await c.addSource(
          RhythmSource(path: 'C:/synthetic/$n', sessionId: '$n', title: '$n'),
          refresh: false,
        );
      }
      const replacement = RhythmSource(
        path: r'C:\synthetic\a.jsonl',
        sessionId: 'replacement',
        title: 'Replacement',
      );
      await c.addSource(replacement, refresh: false);
      expect(c.sources.length, 8);
      expect(c.sources.any((s) => s.key == sourceA.key), false);
      expect(c.turns, isEmpty);
      expect((await c.store.read()).turns, isEmpty);
      await c.shutdown();
    },
  );
  test('initial source failure does not block next source and failed reread keeps timestamp', () async {
    final store = SessionRhythmStore.memory();
    await store.write(
      RhythmCache(
        sources: [sourceA, sourceB],
        turns: [row(1, end: end)],
        lastReadMs: {sourceA.key: end},
      ),
    );
    final b = FakeRhythmBackend((p) {
      if (p['path'] == sourceA.path) throw StateError('synthetic source error');
      return page(
        id: 'b',
        records: [fact(2, end: end)],
      );
    });
    final c = SessionRhythmController(
      backend: b,
      store: store,
      now: () => clock,
    );
    await c.initialize();
    await c.refresh();
    expect(c.turns.length, 2);
    expect(c.lastReadMsBySource[sourceA.key], end);
    expect(c.sourceErrors.keys, [sourceA.key]);
    await c.shutdown();
  });
}

class BrokenStore extends SessionRhythmStore {
  BrokenStore({this.readFails = false}) : super.memory();
  final bool readFails;
  int writes = 0;
  @override
  Future<RhythmCache> read() async {
    if (readFails) throw const FormatException('corrupt');
    return RhythmCache();
  }

  @override
  Future<void> write(RhythmCache cache) async {
    writes++;
    throw StateError('disk');
  }
}

class HeldWriteStore extends SessionRhythmStore {
  HeldWriteStore() : super.memory();
  Completer<void>? _next;
  late Completer<void> entered;
  Future<void> _writes = Future<void>.value();
  Completer<void> holdNext() {
    entered = Completer<void>();
    return _next = Completer<void>();
  }

  @override
  Future<void> write(RhythmCache cache) {
    final gate = _next;
    _next = null;
    final write = _writes.then((_) async {
      if (gate != null) {
        entered.complete();
        await gate.future;
      }
      await super.write(cache);
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  @override
  Future<void> flush() async {
    await _writes;
    await super.flush();
  }
}
