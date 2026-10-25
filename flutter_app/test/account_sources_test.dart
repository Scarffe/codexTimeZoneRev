import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/services/backend.dart';

AccountUsage sample(DateTime time, double used) => AccountUsage(
  email: 'private@example.test',
  plan: 'plus',
  fetchedAt: time,
  buckets: [
    UsageBucket(
      label: 'Codex',
      windows: [
        UsageWindow(
          usedPercent: used,
          durationMinutes: 300,
          resetsAt: time.add(const Duration(days: 1)),
        ),
      ],
    ),
  ],
);

class SyntheticSources extends AccountSourcesService {
  @override
  bool get synthetic => true;
  final calls = <String>[];
  final pending = <String, Completer<AccountUsage>>{};
  int count = 0;
  Completer<String>? createPending;
  Completer<String>? loginPending;
  Completer<SourceCapability>? probePending;
  Completer<SourceLoginStatus>? statusPending;
  Completer<void>? shutdownPending;
  String? cancelError, removeError;
  @override
  Future<SourceCapability> probe() async => probePending == null
      ? const SourceCapability(true, true)
      : probePending!.future;
  @override
  Future<String> create() async =>
      createPending == null ? 'profile-${++count}' : createPending!.future;
  @override
  Future<String> loginStart(String id) async {
    calls.add('login:$id');
    return loginPending == null ? 'job-$id' : loginPending!.future;
  }

  @override
  Future<SourceLoginStatus> loginStatus(String id, String job) async =>
      statusPending == null
      ? const SourceLoginStatus('succeeded')
      : statusPending!.future;
  @override
  Future<SourceLoginStatus> loginCancel(String id, String job) async {
    calls.add('cancel:$id');
    if (cancelError != null) throw SourceFailure(cancelError!);
    return const SourceLoginStatus('cancelled');
  }

  @override
  Future<AccountUsage> query(
    String id, {
    String desktopPath = '',
    bool details = false,
  }) {
    calls.add('$id:$details');
    return (pending[id] = Completer<AccountUsage>()).future;
  }

  @override
  Future<void> remove(String id) async {
    calls.add('remove:$id');
    if (removeError != null) throw SourceFailure(removeError!);
  }

  @override
  Future<void> shutdown() async {
    calls.add('shutdown');
    await shutdownPending?.future;
  }
}

class RecordingBackend implements LauncherBackend {
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> result = {
    'ok': true,
    'sourceId': 'wrong',
    'usage': {'account': {}},
  };
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add((command, payload));
    return result;
  }
}

class ForbiddenLegacy implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) =>
      throw StateError('legacy must never run');
}

class FailingCatalog extends AccountSourceStore {
  FailingCatalog() : super.memory();
  @override
  Future<void> write(Map<String, Object?> value) async =>
      throw const FileSystemException('fixture write denied');
}

class LateFailCatalog extends AccountSourceStore {
  LateFailCatalog() : super.memory();
  bool fail = false;
  @override
  Future<void> write(Map<String, Object?> value) async {
    if (fail) throw const FileSystemException('fixture write denied');
    await super.write(value);
  }
}

void main() {
  test(
    'native completion time survives source parsing and detail retention',
    () async {
      final backend = RecordingBackend();
      backend.result = {
        'ok': true,
        'sourceId': 'profile-fixture',
        'queriedAtMs': 1792886400123,
        'usage': {'account': <String, dynamic>{}, 'detailsIncluded': false},
      };
      final parsed = await NativeAccountSourcesService(backend)
          .query('profile-fixture');
      expect(parsed.fetchedAt, DateTime.utc(2026, 10, 25, 0, 0, 0, 123));
      expect(parsed.fetchedAt.isUtc, isTrue);
      expect(parsed.toCacheJson()['timeQuality'], 'nativeCompletion');
      final retained = retainUsageDetails(
        parsed,
        AccountUsage(
          email: null,
          plan: null,
          buckets: const [],
          fetchedAt: DateTime.utc(2026, 10, 24),
          lifetimeTokens: 123,
        ),
      );
      expect(retained.lifetimeTokens, 123);
      expect(retained.fetchedAt, parsed.fetchedAt);
      expect(retained.toCacheJson()['timeQuality'], 'nativeCompletion');
    },
  );

  test(
    'invalid native completion times use a marked local receipt fallback',
    () async {
      for (final invalid in [
        null,
        0,
        -1,
        '1792886400123',
        1.5,
        double.nan,
        double.infinity,
        8640000000000001,
      ]) {
        final backend = RecordingBackend();
        backend.result = {
          'ok': true,
          'sourceId': 'profile-fixture',
          'queriedAtMs': invalid,
          'usage': {'account': <String, dynamic>{}},
        };
        final before = DateTime.now();
        final parsed = await NativeAccountSourcesService(backend)
            .query('profile-fixture');
        final after = DateTime.now();
        expect(parsed.fetchedAt.isBefore(before), isFalse, reason: '$invalid');
        expect(parsed.fetchedAt.isAfter(after), isFalse, reason: '$invalid');
        expect(parsed.toCacheJson()['timeQuality'], 'localReceiptFallback');
      }
    },
  );

  late DateTime now;
  late SyntheticSources service;
  late AccountSourceStore store;
  late AccountSourcesController owner;
  setUp(() async {
    now = DateTime.utc(2026, 10, 24);
    service = SyntheticSources();
    store = AccountSourceStore.memory();
    owner = AccountSourcesController(service, store, now: () => now);
    await owner.initialize(() => 'fixture-cli');
  });
  tearDown(() {
    owner.dispose();
  });

  testWidgets(
    'pending login and cancellation cannot consume healthy source schedule',
    (tester) async {
      final fixture = SyntheticSources();
      final scheduled = AccountSourcesController(
        fixture,
        AccountSourceStore.memory(),
        now: () => now,
      );
      await scheduled.initialize(() => 'fixture-cli');
      final healthy = (await scheduled.create('Healthy'))!;
      final id = (await scheduled.create('Work'))!;
      scheduled.start(() => 'fixture-cli');
      await tester.pump(const Duration(milliseconds: 1));
      fixture.pending[healthy]!.complete(sample(now, 30));
      await tester.pump();
      fixture.loginPending = Completer<String>();
      final login = scheduled.login(id);
      await tester.pump();
      now = now.add(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      now = now.add(const Duration(seconds: 120));
      await tester.pump(const Duration(seconds: 120));
      expect(fixture.calls.where((c) => c == '$healthy:false').length, 2);
      fixture.pending[healthy]!.complete(sample(now, 35));
      await tester.pump();
      await scheduled.cancelLogin(id);
      fixture.loginPending!.complete('late-job');
      await login;
      await tester.pump(const Duration(milliseconds: 1));
      expect(fixture.calls, contains('$id:false'));
      fixture.pending[id]!.complete(sample(now, 40));
      await tester.pump();
      scheduled.pause();
      scheduled.dispose();
    },
  );

  test('cancel failure keeps native ownership and retry handle until acknowledgement', () async {
    final a = (await owner.create('Work'))!,
        b = (await owner.create('Personal'))!;
    await owner.login(a);
    final state = owner.states.firstWhere((s) => s.id == a);
    final job = state.jobId;
    service.cancelError = 'network';
    await owner.cancelLogin(a);
    expect(state.jobId, job);
    expect(state.loginState, 'cancel_failed');
    expect(state.errorKind, 'network');
    expect(owner.anyBusy, isTrue);
    await owner.login(b);
    expect(service.calls, isNot(contains('login:$b')));
    service.cancelError = null;
    await owner.cancelLogin(a);
    expect(owner.operationError, isNull);
    expect(state.jobId, isNull);
    expect(state.loginState, 'cancelled');
    await owner.login(b);
    expect(service.calls, contains('login:$b'));
    await owner.cancelLogin(b);
  });

  test(
    'late login start cancellation failure remains owned and addressable',
    () async {
      final a = (await owner.create('Work'))!,
          b = (await owner.create('Personal'))!;
      service.loginPending = Completer<String>();
      final login = owner.login(a);
      await Future<void>.delayed(Duration.zero);
      await owner.cancelLogin(a);
      unawaited(owner.login(b));
      await Future<void>.delayed(Duration.zero);
      expect(service.calls, isNot(contains('login:$b')));
      service.cancelError = 'timeout';
      service.loginPending!.complete('late-job');
      await login;
      final state = owner.states.firstWhere((s) => s.id == a);
      expect(state.jobId, 'late-job');
      expect(state.loginState, 'cancel_failed');
      service.cancelError = null;
      await owner.cancelLogin(a);
      expect(state.jobId, isNull);
    },
  );

  test('failed removal persists cleanup row across restart until native acknowledgement', () async {
    final id = (await owner.create('Work'))!;
    final query = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.complete(sample(now, 20));
    await query;
    service.removeError = 'unavailable';
    owner.select(id);
    owner.pin(id);
    await owner.remove(id);
    await owner.saved;
    expect(owner.states.map((s) => s.id), contains(id));
    expect(owner.selectedId, '');
    expect(owner.pinnedId, '');
    expect(owner.states.last.usage, isNull);
    final item = ((await store.read())['sources'] as List).last as Map;
    expect(item['pendingRemoval'], isTrue);
    expect(item['alias'], 'Work');
    final fixture = SyntheticSources();
    final restored = AccountSourcesController(fixture, store, now: () => now);
    await restored.initialize(() => 'fixture-cli');
    await restored.refresh(id);
    await restored.login(id);
    expect(fixture.calls, isEmpty);
    expect(restored.states.last.usage, isNull);
    await restored.remove(id);
    await restored.saved;
    expect(restored.states, isEmpty);
    expect(jsonEncode(await store.read()), isNot(contains(id)));
    restored.dispose();
  });

  test('synthetic native envelopes retain typed partial availability and cached detail kinds', () async {
    Map<String, dynamic> payload({
      String? limitsKind,
      String? tokensKind,
      bool details = true,
    }) => {
      'account': {'email': null, 'planType': 'plus'},
      'identityKey': 'fixture',
      'detailsIncluded': details,
      'limits': limitsKind == null
          ? {
              'rateLimits': {
                'primary': {'usedPercent': 20, 'windowDurationMins': 300},
              },
            }
          : null,
      if (limitsKind != null) ...{
        'limitsError': 'Sanitized failure',
        'limitsErrorKind': limitsKind,
      },
      if (tokensKind != null) ...{
        'tokensError': 'Sanitized token failure',
        'tokensErrorKind': tokensKind,
      },
    };
    for (final kind in ['auth_required', 'network', 'rate_limited']) {
      final backend = RecordingBackend();
      backend.result = {
        'ok': true,
        'sourceId': 'profile-fixture',
        'usage': payload(),
      };
      final native = NativeAccountSourcesService(backend);
      final catalog = AccountSourceStore.memory();
      await catalog.write({
        'sources': [
          {'id': 'profile-fixture', 'alias': 'Fixture'},
        ],
      });
      final monitored = AccountSourcesController(
        native,
        catalog,
        now: () => now,
      );
      await monitored.initialize(() => 'fixture-cli');
      await monitored.refresh('profile-fixture');
      final original = monitored.selected!.usage!.fetchedAt;
      backend.result = {
        'ok': true,
        'sourceId': 'profile-fixture',
        'usage': payload(limitsKind: kind),
      };
      await monitored.refresh('profile-fixture');
      expect(monitored.selected!.errorKind, kind);
      if (kind == 'auth_required') {
        expect(monitored.selected!.usage, isNull);
      } else {
        expect(monitored.selected!.usage!.fetchedAt, original);
      }
      final parsed = await native.query('profile-fixture');
      expect(
        AccountUsage.fromCacheJson(parsed.toCacheJson())
            .toCacheJson()['limitsErrorKind'],
        kind,
      );
      monitored.dispose();
    }
    final backend = RecordingBackend();
    backend.result = {
      'ok': true,
      'sourceId': 'profile-fixture',
      'usage': payload(tokensKind: 'network'),
    };
    final native = NativeAccountSourcesService(backend);
    final catalog = AccountSourceStore.memory();
    await catalog.write({
      'sources': [
        {'id': 'profile-fixture', 'alias': 'Fixture'},
      ],
    });
    final monitored = AccountSourcesController(native, catalog, now: () => now);
    await monitored.initialize(() => 'fixture-cli');
    await monitored.refresh('profile-fixture', details: true);
    expect(monitored.selected!.errorKind, isNull);
    expect(monitored.selected!.usage!.buckets, isNotEmpty);
    final previous = monitored.selected!.usage!;
    backend.result = {
      'ok': true,
      'sourceId': 'profile-fixture',
      'usage': payload(details: false),
    };
    final retained = retainUsageDetails(
      await native.query('profile-fixture'),
      previous,
    );
    expect(
      AccountUsage.fromCacheJson(retained.toCacheJson())
          .toCacheJson()['tokensErrorKind'],
      'network',
    );
    monitored.dispose();
  });

  test('FIFO global arbiter and duplicate refresh share completion', () async {
    final a = await owner.create('Work'), b = await owner.create('Personal');
    final first = owner.refresh(a!);
    final duplicate = owner.refresh(a);
    final second = owner.refresh(b!);
    expect(identical(first, duplicate), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(service.calls, ['$a:false']);
    service.pending[a]!.complete(sample(now, 20));
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(service.calls, ['$a:false', '$b:false']);
    service.pending[b]!.complete(sample(now, 60));
    await second;
    expect(owner.states.map((s) => s.id), [a, b]);
    expect(
      owner.states
          .firstWhere((s) => s.id == a)
          .usage!
          .buckets
          .first
          .windows
          .first
          .usedPercent,
      20,
    );
  });

  test('backoff isolates failure and selection pinning never query', () async {
    final a = (await owner.create('Work'))!;
    final b = (await owner.create('Healthy'))!;
    final attempt = owner.refresh(a);
    await Future<void>.delayed(Duration.zero);
    service.pending[a]!.completeError(const SourceFailure('network'));
    await attempt;
    final previous = service.calls.length;
    await owner.refresh(a);
    owner.select(a);
    owner.pin(a);
    expect(service.calls.length, previous);
    final healthy = owner.refresh(b);
    await Future<void>.delayed(Duration.zero);
    service.pending[b]!.complete(sample(now, 30));
    await healthy;
    expect(owner.selected!.errorKind, 'network');
    expect(owner.selected!.usage, isNull);
    expect(owner.states.firstWhere((s) => s.id == b).usage, isNotNull);
  });

  test('restart restores failed status and cooldown without blocking healthy due source', () async {
    final healthy = (await owner.create('Healthy'))!;
    final id = (await owner.create('Work'))!;
    final original = now;
    for (final source in [id, healthy]) {
      final query = owner.refresh(source);
      await Future<void>.delayed(Duration.zero);
      service.pending[source]!.complete(sample(now, 40));
      await query;
    }
    now = now.add(const Duration(seconds: 120));
    final failed = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.completeError(const SourceFailure('network'));
    await failed;
    await owner.saved;
    final failureTime = now, cooldown = owner.states.last.nextRefreshAt;
    now = now.add(const Duration(seconds: 5));
    final fixture = SyntheticSources();
    final restored = AccountSourcesController(fixture, store, now: () => now);
    await restored.initialize(() => 'fixture-cli');
    final state = restored.states.last;
    expect(state.errorKind, 'network');
    expect(state.failures, 1);
    expect(state.lastAttempt, failureTime);
    expect(state.nextRefreshAt, cooldown);
    expect(state.usage!.fetchedAt, original);
    expect(restored.isStale(state), isTrue);
    await restored.refresh(id);
    expect(fixture.calls, isEmpty);
    restored.start(() => 'fixture-cli');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.calls, ['$healthy:false']);
    restored.systemSuspending();
    restored.systemResumed();
    await restored.refresh(id);
    expect(fixture.calls, ['$healthy:false']);
    fixture.pending[healthy]!.complete(sample(now, 35));
    await Future<void>.delayed(Duration.zero);
    restored.pause();
    now = cooldown!.add(const Duration(milliseconds: 1));
    final retry = restored.refresh(id);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.calls.last, '$id:false');
    fixture.pending[id]!.complete(sample(now, 50));
    await retry;
    expect(state.errorKind, isNull);
    expect(state.failures, 0);
    restored.dispose();
  });

  test(
    'restart keeps auth failure unavailable without obsolete quota',
    () async {
      final id = (await owner.create('Work'))!;
      final query = owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      service.pending[id]!.completeError(const SourceFailure('auth_required'));
      await query;
      await owner.saved;
      final restored = AccountSourcesController(service, store, now: () => now);
      await restored.initialize(() => 'fixture-cli');
      expect(restored.states.last.errorKind, 'auth_required');
      expect(restored.states.last.usage, isNull);
      restored.dispose();
    },
  );

  test('restart during relogin keeps prior cooldown but never restores an owned job', () async {
    final id = (await owner.create('Work'))!;
    final query = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.completeError(const SourceFailure('network'));
    await query;
    await owner.login(id);
    await owner.saved;
    final value = await store.read();
    expect(jsonEncode(value), isNot(contains('jobId')));
    expect(jsonEncode(value), isNot(contains('job-$id')));
    final restored = AccountSourcesController(service, store, now: () => now);
    await restored.initialize(() => 'fixture-cli');
    expect(restored.catalogError, isNull);
    expect(restored.states.last.failures, 1);
    expect(restored.states.last.jobId, isNull);
    expect(restored.states.last.loggingIn, isFalse);
    restored.dispose();
  });

  test(
    'restore accepts bounded query latency at maximum failure backoff',
    () async {
      final catalog = AccountSourceStore.memory();
      await catalog.write({
        'sources': [
          {
            'id': 'profile-backoff',
            'alias': 'Default',
            'generation': 0,
            'errorKind': 'network',
            'failures': 6,
            'lastAttempt': now
                .subtract(const Duration(minutes: 30))
                .millisecondsSinceEpoch,
            'nextRefreshAt': now
                .subtract(const Duration(seconds: 1))
                .millisecondsSinceEpoch,
          },
        ],
      });
      final fixture = SyntheticSources();
      final running = AccountSourcesController(
        fixture,
        catalog,
        now: () => now,
      );
      await running.initialize(() => 'fixture-cli');
      final query = running.refresh('profile-backoff');
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 2));
      fixture.pending['profile-backoff']!.completeError(
        const SourceFailure('network'),
      );
      await query;
      await running.saved;
      final restored = AccountSourcesController(
        fixture,
        catalog,
        now: () => now,
      );
      await restored.initialize(() => 'fixture-cli');
      expect(restored.catalogError, isNull);
      expect(restored.states.single.failures, 7);
      expect(
        restored.states.single.nextRefreshAt,
        now.add(const Duration(minutes: 30)),
      );
      running.dispose();
      restored.dispose();
    },
  );

  test('catalog save during retry keeps a valid past cooldown without restoring busy', () async {
    final id = (await owner.create('Work'))!;
    var query = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.completeError(const SourceFailure('network'));
    await query;
    now = owner.states.last.nextRefreshAt!.add(const Duration(seconds: 1));
    query = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    owner.select(id);
    await owner.saved;
    final restored = AccountSourcesController(service, store, now: () => now);
    await restored.initialize(() => 'fixture-cli');
    expect(restored.catalogError, isNull);
    expect(restored.selected!.busy, isFalse);
    expect(restored.selected!.errorKind, 'network');
    expect(restored.selected!.nextRefreshAt!.isBefore(now), isTrue);
    service.pending[id]!.complete(sample(now, 30));
    await query;
    restored.dispose();
  });

  test(
    'persisted failure metadata rejects invalid kinds counts and deadlines',
    () async {
      for (final invalid in [
        {'errorKind': 'raw secret@example.test'},
        {'failures': -1},
        {'failures': 65},
        {'lastAttempt': -1},
        {'nextRefreshAt': 8640000000000001},
        {
          'nextRefreshAt': now
              .add(const Duration(days: 2))
              .millisecondsSinceEpoch,
        },
      ]) {
        final catalog = AccountSourceStore.memory();
        await catalog.write({
          'sources': [
            {
              'id': 'profile-backoff',
              'alias': 'Default',
              'generation': 0,
              'errorKind': 'network',
              'failures': 1,
              'lastAttempt': now.millisecondsSinceEpoch,
              'nextRefreshAt': now
                  .add(const Duration(seconds: 120))
                  .millisecondsSinceEpoch,
              ...invalid,
            },
          ],
        });
        final restored = AccountSourcesController(
          service,
          catalog,
          now: () => now,
        );
        await restored.initialize(() => 'fixture-cli');
        expect(restored.catalogError, isNotNull, reason: invalid.toString());
        await expectLater(catalog.write({'sources': []}), throwsStateError);
        restored.dispose();
      }
    },
  );

  test('removal invalidates queued and active results durably', () async {
    final a = (await owner.create('Work'))!, b = (await owner.create('Other'))!;
    final active = owner.refresh(a), queued = owner.refresh(b);
    await Future<void>.delayed(Duration.zero);
    await owner.remove(a);
    await owner.remove(b);
    service.pending[a]!.complete(sample(now, 90));
    await active;
    await queued;
    await owner.saved;
    expect(owner.states, isEmpty);
    expect(jsonEncode(await store.read()), isNot(contains(a)));
    expect(service.calls, isNot(contains('$b:false')));
  });

  test(
    'relogin invalidates pending query and never retains prior cache',
    () async {
      final id = (await owner.create('Work'))!;
      final query = owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      final login = owner.login(id);
      service.pending[id]!.complete(sample(now, 88));
      await query;
      await login;
      expect(owner.states.firstWhere((s) => s.id == id).usage, isNull);
      await owner.cancelLogin(id);
      expect(
        owner.states.firstWhere((s) => s.id == id).loginState,
        'cancelled',
      );
    },
  );

  test(
    'cancel while login starts cancels late job instead of registering it',
    () async {
      final id = (await owner.create('Work'))!;
      service.loginPending = Completer<String>();
      final login = owner.login(id);
      await Future<void>.delayed(Duration.zero);
      await owner.cancelLogin(id);
      service.loginPending!.complete('late-job');
      await login;
      expect(
        owner.states.firstWhere((s) => s.id == id).loginState,
        'cancelled',
      );
      expect(service.calls, contains('cancel:$id'));
    },
  );

  test(
    'cache timestamps selection pin and alert history survive restart',
    () async {
      final id = (await owner.create('Work'))!;
      final query = owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      service.pending[id]!.complete(sample(now, 85));
      await query;
      expect(owner.alertSerial, 0, reason: 'initial low reading is history');
      owner.select(id);
      owner.pin(id);
      await owner.saved;
      now = now.add(const Duration(minutes: 7));
      final restored = AccountSourcesController(service, store, now: () => now);
      await restored.initialize(() => 'fixture-cli');
      expect(restored.selectedId, id);
      expect(restored.pinnedId, id);
      expect(restored.selected!.usage!.fetchedAt, DateTime.utc(2026, 10, 24));
      expect(restored.alertSerial, 0);
      expect(restored.isStale(restored.selected!), isTrue);
      restored.dispose();
    },
  );

  test(
    'independent same email aliases produce globally serialized private alerts',
    () async {
      final a = (await owner.create('Work'))!,
          b = (await owner.create('Personal'))!;
      for (final id in [a, b]) {
        final q = owner.refresh(id);
        await Future<void>.delayed(Duration.zero);
        service.pending[id]!.complete(sample(now, 40));
        await q;
      }
      for (final id in [a, b]) {
        final q = owner.refresh(id);
        await Future<void>.delayed(Duration.zero);
        service.pending[id]!.complete(sample(now, 85));
        await q;
      }
      expect(owner.alertSerial, 2);
      expect(owner.alert, contains('Personal'));
      expect(owner.alert, isNot(contains('private@example.test')));
      owner.select(a);
      owner.pin(b);
      expect(owner.alertSerial, 2);
    },
  );

  test(
    'shutdown stops scheduling and awaits native shutdown and durable save',
    () async {
      service.shutdownPending = Completer<void>();
      final shutdown = owner.shutdown();
      var finished = false;
      unawaited(
        shutdown.then((_) {
          finished = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(owner.monitoring, isFalse);
      service.shutdownPending!.complete();
      await shutdown;
      expect(finished, isTrue);
      await owner.refresh('current');
      expect(service.calls, ['shutdown']);
    },
  );

  test('shutdown joins late create cleanup before completing', () async {
    service.createPending = Completer<String>();
    final creation = owner.create('Work');
    await Future<void>.delayed(Duration.zero);
    final shutdown = owner.shutdown();
    var finished = false;
    unawaited(
      shutdown.then((_) {
        finished = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    service.createPending!.complete('profile-late');
    expect(await creation, isNull);
    await shutdown;
    expect(service.calls, contains('remove:profile-late'));
    expect(owner.states, isEmpty);
  });

  test('remove during login status discards terminal success', () async {
    final id = (await owner.create('Work'))!;
    await owner.login(id);
    service.statusPending = Completer<SourceLoginStatus>();
    final poll = owner.pollLogin(id);
    await owner.remove(id);
    service.statusPending!.complete(const SourceLoginStatus('succeeded'));
    await poll;
    await owner.saved;
    expect(jsonEncode(await store.read()), isNot(contains(id)));
  });

  testWidgets(
    'schedule staggers sources and suspend resume retains failure cooldown',
    (tester) async {
      final fixture = SyntheticSources();
      final scheduled = AccountSourcesController(
        fixture,
        AccountSourceStore.memory(),
        now: () => now,
      );
      await scheduled.initialize(() => 'fixture-cli');
      final failed = (await scheduled.create('Backoff'))!;
      final id = (await scheduled.create('Work'))!;
      scheduled.start(() => 'fixture-cli');
      await tester.pump(const Duration(milliseconds: 1));
      expect(fixture.calls, ['$failed:false']);
      fixture.pending[failed]!.completeError(const SourceFailure('network'));
      await tester.pump();
      now = now.add(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(fixture.calls.last, '$id:false');
      fixture.pending[id]!.complete(sample(now, 40));
      await tester.pump();
      scheduled.systemSuspending();
      now = now.add(const Duration(seconds: 20));
      scheduled.systemResumed();
      await tester.pump(const Duration(milliseconds: 1));
      expect(fixture.calls.length, 3);
      expect(fixture.calls.last, '$id:false');
      fixture.pending[id]!.complete(sample(now, 40));
      await tester.pump();
      scheduled.pause();
      scheduled.dispose();
    },
  );

  test('login waits for durable generation save before native authentication starts', () async {
    final fixture = SyntheticSources();
    final catalog = LateFailCatalog();
    final guarded = AccountSourcesController(fixture, catalog);
    await guarded.initialize(() => 'fixture-cli');
    final id = (await guarded.create('Work'))!;
    await guarded.saved;
    catalog.fail = true;
    await guarded.login(id);
    expect(fixture.calls, isNot(contains('login:$id')));
    expect(guarded.states.last.loginState, 'failed');
    guarded.dispose();
  });

  test(
    'absent current source cannot be queried removed or authenticated',
    () async {
      await owner.remove('current');
      await owner.login('current');
      await owner.refresh('current');
      expect(owner.states, isEmpty);
      expect(service.calls, isEmpty);
    },
  );

  test('native service binds source, forces managed limits, and rejects mismatched response', () async {
    final backend = RecordingBackend();
    final native = NativeAccountSourcesService(backend);
    await expectLater(
      native.query('profile-1', details: true),
      throwsA(isA<SourceFailure>()),
    );
    expect(backend.calls.single.$2, {
      'sourceId': 'profile-1',
      'details': false,
    });
    expect(backend.calls.single.$1, 'account_source_usage');
    final denied = NativeAccountSourcesService(backend, offlineTrial: true);
    await expectLater(denied.probe(), throwsA(isA<SourceFailure>()));
    await expectLater(denied.create(), throwsA(isA<SourceFailure>()));
    expect(backend.calls.length, 1);
  });

  test(
    'native authentication and removal reject mismatched source responses',
    () async {
      final backend = RecordingBackend();
      backend.result = {
        'ok': true,
        'sourceId': 'wrong',
        'jobId': 'job',
        'state': 'succeeded',
      };
      final native = NativeAccountSourcesService(backend);
      for (final operation in [
        () => native.loginStart('profile-1'),
        () => native.loginStatus('profile-1', 'job'),
        () => native.loginCancel('profile-1', 'job'),
        () => native.remove('profile-1'),
      ]) {
        await expectLater(operation(), throwsA(isA<SourceFailure>()));
      }
    },
  );

  test('network errors retain original stale timestamp while auth failures clear obsolete quota', () async {
    final id = (await owner.create('Work'))!;
    var q = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.complete(sample(now, 45));
    await q;
    final original = now;
    now = now.add(const Duration(minutes: 2));
    q = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.completeError(const SourceFailure('network'));
    await q;
    final state = owner.states.last;
    expect(state.usage!.fetchedAt, original);
    expect(owner.isStale(state), isTrue);
    now = now.add(const Duration(minutes: 2));
    q = owner.refresh(id);
    await Future<void>.delayed(Duration.zero);
    service.pending[id]!.completeError(const SourceFailure('auth_required'));
    await q;
    expect(state.usage, isNull);
    expect(state.errorKind, 'auth_required');
  });

  test('offline owner denies even an injected native service without invoking backend', () async {
    final backend = RecordingBackend();
    final offline = AccountSourcesController(
      NativeAccountSourcesService(backend),
      AccountSourceStore.memory(),
      offlineTrial: true,
    );
    await offline.initialize(() => 'fixture-cli');
    await offline.probe();
    await offline.create('Work');
    await offline.refresh('current');
    await offline.shutdown();
    expect(backend.calls, isEmpty);
    offline.dispose();
  });

  test('catalog write failure blocks login and removal until durable catalog is available', () async {
    final fixture = SyntheticSources();
    final failed = AccountSourcesController(fixture, FailingCatalog());
    await failed.initialize(() => 'fixture-cli');
    final id = (await failed.create('Work'))!;
    await failed.saved;
    expect(failed.catalogError, isNotNull);
    await failed.login(id);
    await failed.remove(id);
    expect(failed.states.map((s) => s.id), contains(id));
    expect(fixture.calls, isEmpty);
    failed.dispose();
  });

  test(
    'facade projects selected data and independently pinned desktop data',
    () async {
      final facade = AccountUsageController(
        ForbiddenLegacy(),
        sources: owner,
        now: () => now,
      );
      final pinned = (await owner.create('Work'))!;
      final id = (await owner.create('Personal'))!;
      var q = owner.refresh(pinned);
      await Future<void>.delayed(Duration.zero);
      service.pending[pinned]!.complete(sample(now, 25));
      await q;
      q = owner.refresh(id);
      await Future<void>.delayed(Duration.zero);
      service.pending[id]!.complete(sample(now, 75));
      await q;
      owner.select(id);
      owner.pin(pinned);
      expect(facade.data!.buckets.first.windows.first.usedPercent, 75);
      expect(facade.desktopSnapshot['remaining'], 75);
      expect(facade.desktopSnapshot['text'], contains('Work'));
      facade.sourceChanged('another-cli');
      expect(facade.data!.buckets.first.windows.first.usedPercent, 75);
      final query = facade.query('another-cli');
      await Future<void>.delayed(Duration.zero);
      expect(service.calls.last, '$id:false');
      service.pending[id]!.complete(sample(now, 70));
      await query;
      facade.dispose();
    },
  );

  test(
    'file store refuses to overwrite corrupt data and serializes atomic writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('source-store-');
      try {
        final file = File('${dir.path}/catalog.json');
        await file.writeAsString('broken original');
        final disk = AccountSourceStore(file);
        await expectLater(disk.read(), throwsFormatException);
        await expectLater(disk.write({'sources': []}), throwsStateError);
        expect(await file.readAsString(), 'broken original');
        await file.delete();
        final clean = AccountSourceStore(file);
        await clean.read();
        await Future.wait([
          clean.write({'sources': [], 'serial': 1}),
          clean.write({'sources': [], 'serial': 2}),
        ]);
        expect((await clean.read())['serial'], 2);
        expect(await File('${file.path}.tmp').exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
