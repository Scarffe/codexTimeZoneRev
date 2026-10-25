import 'dart:async';
import 'dart:convert';

import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_store.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multi_account_fixture.dart';

class _Sources extends SyntheticMultiSources {
  Completer<AccountUsage>? gate;
  String identity = 'fixture-identity';
  bool noLimits = false;
  bool unavailableLimits = false;
  @override
  Future<AccountUsage> query(
    String id, {
    String desktopPath = '',
    bool details = false,
  }) async {
    queries.add(id);
    if (gate != null) return gate!.future;
    final failure = queryFailureKinds[id];
    if (failure != null) throw SourceFailure(failure);
    return observation();
  }

  AccountUsage observation() => AccountUsage(
    email: 'fixture@example.test',
    plan: 'fixture',
    identityKey: identity,
    fetchedAt: DateTime.utc(2026, 10, 25, 1),
    timeQuality: UsageObservationTimeQuality.nativeCompletion,
    limitsErrorKind: unavailableLimits ? 'network' : null,
    buckets: noLimits
        ? []
        : const [
            UsageBucket(
              label: 'Private display label',
              windows: [
                UsageWindow(
                  role: UsageWindowRole.secondary,
                  usedPercent: 42,
                  durationMinutes: 10080,
                ),
                UsageWindow(role: UsageWindowRole.primary),
              ],
            ),
          ],
  );
}

class _FailingHistory implements QuotaHistorySink {
  int appends = 0, flushes = 0, removals = 0;
  @override
  Future<void> append(QueryHistoryRecord record) async {
    appends++;
    throw StateError('sensitive raw failure');
  }

  @override
  Future<void> removeSource(String id) async {
    removals++;
    throw StateError('sensitive cleanup');
  }

  @override
  Future<void> flush() async {
    flushes++;
    throw StateError('sensitive flush');
  }
}

void main() {
  late _Sources service;
  late AccountSourceStore catalog;
  late QuotaHistoryStore history;
  late AccountSourcesController owner;
  var now = DateTime.utc(2026, 10, 25, 1);
  setUp(() async {
    now = DateTime.utc(2026, 10, 25, 1);
    service = _Sources();
    catalog = AccountSourceStore.memory();
    history = QuotaHistoryStore.memory(now: () => now);
    owner = AccountSourcesController(
      service,
      catalog,
      historySink: history,
      now: () => now,
    );
    await owner.initialize(() => '');
  });
  tearDown(() => owner.dispose());
  Future<List<QueryHistoryRecord>> records(String id) async =>
      (await history.read(
        QuotaHistoryFilter(
          sourceId: id,
          fromUtc: DateTime.utc(2026, 10, 1),
          toUtc: DateTime.utc(2026, 11, 1),
        ),
      )).records;

  test('A/B/A captures real attempts and identical values without identity or labels', () async {
    final a = (await owner.create('A'))!, b = (await owner.create('B'))!;
    await owner.refresh(a);
    await owner.refresh(b);
    await owner.refresh(a);
    final rows = await records(a);
    expect(rows, hasLength(2));
    expect(await records(b), hasLength(1));
    expect(rows.map((r) => r.attemptId).toSet(), hasLength(2));
    expect(rows.map((r) => r.segmentId).toSet(), hasLength(1));
    expect(rows.first.outcome, QueryHistoryOutcome.success);
    expect(rows.first.windows.first.role, UsageWindowRole.secondary);
    expect(rows.first.windows.last.usedPercent, isNull);
    expect(
      rows.first.timeQuality,
      UsageObservationTimeQuality.nativeCompletion,
    );
    expect(rows.first.expectedIntervalSec, 120);
    final encoded = jsonEncode(rows.map((r) => r.toJson()).toList());
    for (final secret in [
      'fixture@example',
      'fixture-identity',
      'Private display label',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });
  test('same-source coalescing creates one actual observation', () async {
    final id = (await owner.create('A'))!;
    service.gate = Completer<AccountUsage>();
    final first = owner.refresh(id), second = owner.refresh(id);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    service.gate!.complete(service.observation());
    await first;
    expect(await records(id), hasLength(1));
  });
  test(
    'typed failure excludes cached windows and cooldown creates no record',
    () async {
      final id = (await owner.create('A'))!;
      await owner.refresh(id);
      service.queryFailureKinds[id] = 'network';
      await owner.refresh(id);
      await owner.refresh(id);
      final rows = await records(id);
      expect(rows, hasLength(2));
      expect(rows.last.outcome, QueryHistoryOutcome.failure);
      expect(rows.last.errorKind, 'network');
      expect(rows.last.windows, isEmpty);
      expect(owner.selected!.usage, isNotNull);
      expect(owner.selected!.failures, 1);
    },
  );
  test('unknown failure is sanitized and empty limits are no_limits', () async {
    final id = (await owner.create('A'))!;
    service.noLimits = true;
    await owner.refresh(id);
    expect((await records(id)).single.outcome, QueryHistoryOutcome.noLimits);
    service.queryFailureKinds[id] = 'raw secret identity';
    await owner.refresh(id);
    final last = (await records(id)).last;
    expect(last.errorKind, 'unavailable');
    expect(jsonEncode(last.toJson()), isNot(contains('raw secret')));
  });
  test('typed unsuccessful native response keeps completion quality but no windows', () async {
    final id = (await owner.create('A'))!;
    now = now.add(const Duration(minutes: 1));
    service.unavailableLimits = true;
    await owner.refresh(id);
    final record = (await records(id)).single;
    expect(record.outcome, QueryHistoryOutcome.failure);
    expect(record.windows, isEmpty);
    expect(
      record.completedAtMs,
      DateTime.utc(2026, 10, 25, 1).millisecondsSinceEpoch,
    );
    expect(record.timeQuality, UsageObservationTimeQuality.nativeCompletion);
  });
  test(
    'missing or malformed history metadata never locks a valid source catalog',
    () async {
      final id = (await owner.create('A'))!;
      await owner.refresh(id);
      await owner.saved;
      final old = owner.selected!.historySegmentId;
      for (final metadata in [null, 7, 'unexpected metadata']) {
        final value = await catalog.read();
        value['sources'][0]['historySegmentId'] = metadata;
        await catalog.write(value);
        owner.dispose();
        owner = AccountSourcesController(
          service,
          catalog,
          historySink: history,
          now: () => now,
        );
        await owner.initialize(() => '');
        expect(owner.catalogError, isNull);
        expect(owner.canMutateCatalog, isTrue);
        await owner.refresh(id);
        expect(owner.selected!.historySegmentId, isNot(old));
        expect(owner.selected!.errorKind, isNull);
        await owner.saved;
      }
    },
  );
  test(
    'shutdown joins a pending owner query before its final history flush',
    () async {
      owner.dispose();
      final sink = _FailingHistory();
      owner = AccountSourcesController(
        service,
        catalog,
        historySink: sink,
        now: () => now,
      );
      await owner.initialize(() => '');
      final id = (await owner.create('A'))!;
      service.gate = Completer<AccountUsage>();
      final pending = owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      final stopping = owner.shutdown();
      await Future<void>.delayed(Duration.zero);
      expect(
        sink.flushes,
        1,
        reason: 'Only startup flush may run before owner query finishes',
      );
      service.gate!.complete(service.observation());
      await pending;
      await stopping;
      expect(sink.flushes, 2);
      expect(sink.appends, 0);
      expect(service.shutdowns, 1);
    },
  );
  test('cache restart rename select and pin do not query and keep a proven segment', () async {
    final id = (await owner.create('A'))!;
    await owner.refresh(id);
    await owner.saved;
    final segment = owner.selected!.historySegmentId;
    owner.dispose();
    owner = AccountSourcesController(
      service,
      catalog,
      historySink: history,
      now: () => now,
    );
    await owner.initialize(() => '');
    owner.rename(id, 'Renamed');
    owner.select(id);
    owner.pin(id);
    expect(owner.selected!.historySegmentId, segment);
    expect(await records(id), hasLength(1));
    await owner.refresh(id);
    expect((await records(id)).last.segmentId, segment);
    final rows = await records(id);
    final before = rows.first.attemptId.split(':'),
        after = rows.last.attemptId.split(':');
    expect(
      after.first,
      before.first,
      reason: 'The run id belongs to this process, not a restored source owner',
    );
    expect(int.parse(after.last), greaterThan(int.parse(before.last)));
  });
  test('explicit login cuts immediately and cancellation never reconnects old segment', () async {
    final id = (await owner.create('A'))!;
    await owner.refresh(id);
    final old = (await records(id)).single.segmentId;
    await owner.login(id);
    final next = owner.selected!.historySegmentId;
    expect(next, isNot(old));
    await owner.saved;
    expect((await catalog.read())['sources'][0]['historySegmentId'], next);
    await owner.cancelLogin(id);
    await owner.refresh(id);
    expect((await records(id)).last.segmentId, next);
  });
  test(
    'visible identity change and auth-cleared baseline each start new segments',
    () async {
      final id = (await owner.create('A'))!;
      await owner.refresh(id);
      final first = (await records(id)).last.segmentId;
      service.identity = 'other-fixture';
      await owner.refresh(id);
      final second = (await records(id)).last.segmentId;
      expect(second, isNot(first));
      service.queryFailureKinds[id] = 'auth_required';
      await owner.refresh(id);
      expect(owner.selected!.usage, isNull);
      now = now.add(const Duration(minutes: 3));
      service.queryFailureKinds.clear();
      await owner.refresh(id);
      expect((await records(id)).last.segmentId, isNot(second));
    },
  );
  test('restored missing baseline cannot claim segment continuity', () async {
    final id = (await owner.create('A'))!;
    await owner.refresh(id);
    await owner.saved;
    final old = owner.selected!.historySegmentId;
    final saved = await catalog.read();
    (saved['sources'][0] as Map).remove('usage');
    await catalog.write(saved);
    owner.dispose();
    owner = AccountSourcesController(
      service,
      catalog,
      historySink: history,
      now: () => now,
    );
    await owner.initialize(() => '');
    await owner.refresh(id);
    expect((await records(id)).last.segmentId, isNot(old));
  });
  test(
    'removed late result records nothing and cannot recreate history',
    () async {
      final id = (await owner.create('A'))!;
      await owner.refresh(id);
      service.gate = Completer<AccountUsage>();
      final pending = owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      await owner.remove(id);
      service.gate!.complete(service.observation());
      await pending;
      expect(await records(id), isEmpty);
      expect(owner.states, isEmpty);
    },
  );
  test(
    'history failures never become query errors or skip native cleanup',
    () async {
      owner.dispose();
      final failing = _FailingHistory();
      owner = AccountSourcesController(
        service,
        catalog,
        historySink: failing,
        now: () => now,
      );
      await owner.initialize(() => '');
      final id = (await owner.create('A'))!;
      await owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      expect(owner.selected!.errorKind, isNull);
      expect(owner.selected!.failures, 0);
      expect(owner.selected!.revision, 1);
      expect(owner.historyError, isNotNull);
      expect(owner.historyError, isNot(contains('sensitive')));
      expect(owner.catalogError, isNull);
      await owner.remove(id);
      expect(owner.states, isEmpty);
      expect(failing.removals, 1);
      expect(owner.historyError, contains('清理'));
      await owner.shutdown();
      expect(service.shutdowns, 1);
      expect(failing.flushes, 2);
      expect(owner.shutdownState, 'succeeded');
    },
  );
}
