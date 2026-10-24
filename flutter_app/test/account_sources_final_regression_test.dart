import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/app/account_sources_panel.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_sources_test.dart' show ForbiddenLegacy, sample;
import 'account_sources_ui_test.dart' show sourcesHost;
import 'monitor_lifecycle_test.dart' show nativeAction;
import 'support/compact_dashboard_fixture.dart';
import 'support/multi_account_fixture.dart';

class _Bootstrap extends CompactDashboardBackend {
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final result = await super.call(command, payload);
    if (command == 'bootstrap') result['detected'] = 'synthetic-cli.exe';
    return result;
  }
}

class _DiskCatalog extends AccountSourceStore {
  _DiskCatalog(super.file);
  int preReadWrites = 0;
  bool readFinished = false;
  final readDone = Completer<void>();
  @override
  Future<Map<String, dynamic>> read() async {
    try {
      return await super.read();
    } finally {
      readFinished = true;
      readDone.complete();
    }
  }

  @override
  Future<void> write(Map<String, Object?> value) {
    if (!readFinished) preReadWrites++;
    return super.write(value);
  }
}

class _RetryShutdown extends SyntheticMultiSources {
  final cleanup = Completer<void>();
  @override
  Future<void> shutdown() async {
    shutdowns++;
    if (shutdowns == 1) throw const SourceFailure('busy');
    await cleanup.future;
  }
}

class _SaveGate extends AccountSourceStore {
  _SaveGate() : super.memory();
  Completer<void>? gate;
  @override
  Future<void> write(Map<String, Object?> value) async {
    await gate?.future;
    await super.write(value);
  }
}

class _LoginEnvelope implements LauncherBackend {
  _LoginEnvelope(this.terminal);
  final String terminal;
  Completer<Map<String, dynamic>>? cancelGate, statusGate;
  final commands = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    commands.add(command);
    if (command == 'account_source_probe') {
      return {'ok': true, 'supported': true, 'managedLogin': true};
    }
    if (command == 'account_source_login_cancel' && cancelGate != null) {
      return cancelGate!.future;
    }
    if (command == 'account_source_login_status' && statusGate != null) {
      return statusGate!.future;
    }
    return envelope(terminal);
  }

  Map<String, dynamic> envelope(String state) => {
    'ok': true,
    'sourceId': 'profile-race',
    'jobId': 'job-race',
    'state': state,
    if (state == 'failed') 'error': {'kind': 'auth_failed'},
    if (state == 'timed_out') 'error': {'kind': 'timeout'},
  };
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('fresh owner refuses catalog mutations until restoration and retains bootstrap path', () async {
    final service = SyntheticMultiSources();
    final store = AccountSourceStore.memory();
    await store.write({
      'sources': [
        {'id': 'current', 'alias': 'Original'},
      ],
    });
    final owner = AccountSourcesController(service, store);
    owner.sourceChanged('bootstrap-cli');
    owner.rename('current', 'Lost');
    owner.start(() => 'bootstrap-cli');
    expect(await owner.create('Too soon'), isNull);
    await owner.refresh('current');
    expect(service.queries, isEmpty);
    expect(owner.monitoring, isFalse);
    await owner.initialize(() => 'bootstrap-cli');
    expect(owner.selected!.alias, 'Original');
    final generation = owner.selected!.generation;
    owner.sourceChanged('bootstrap-cli');
    expect(owner.selected!.generation, generation);
    owner.dispose();
  });

  for (final corrupt in [false, true]) {
    testWidgets(
      'cold app bootstrap preserves original disk catalog corrupt=$corrupt',
      (tester) async {
        final now = DateTime.now();
        final cycles = {
          'a' * 64: [
            3,
            now.add(const Duration(days: 1)).millisecondsSinceEpoch,
          ],
        };
        final catalog = {
          'version': 1,
          'selectedId': 'profile-one',
          'pinnedId': 'profile-two',
          'sources': [
            for (final id in ['current', 'profile-one', 'profile-two'])
              {
                'id': id,
                'alias': id,
                'generation': 4,
                'usage': sample(now, 60).toCacheJson(),
              },
          ],
          'cycles': cycles,
        };
        late Directory temp;
        late File file;
        final bytes = utf8.encode(
          corrupt ? '{broken original\n' : jsonEncode(catalog),
        );
        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('source-final-cold-');
          file = File('${temp.path}/account-sources-v1.json');
          await file.writeAsBytes(bytes, flush: true);
        });
        final store = _DiskCatalog(file);
        final service = SyntheticMultiSources();
        final owner = AccountSourcesController(
          service,
          store,
          offlineTrial: true,
        );
        await tester.pumpWidget(
          LauncherApplication(
            preview: true,
            backend: _Bootstrap(),
            sourceController: owner,
            desktop: SyntheticMultiDesktop(),
          ),
        );
        for (var i = 0; i < 100 && !store.readFinished; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(store.readFinished, isTrue);
        await tester.pumpAndSettle();
        await tester.runAsync(() => owner.saved);
        expect(store.preReadWrites, 0);
        if (corrupt) {
          expect(owner.catalogError, isNotNull);
          await tester.runAsync(() async {
            owner.rename('current', 'must not write');
            owner.sourceChanged('another-cli.exe');
            await owner.saved;
          });
          expect(await tester.runAsync(file.readAsBytes), bytes);
        } else {
          expect(owner.states.map((s) => s.id), [
            'current',
            'profile-one',
            'profile-two',
          ]);
          expect(owner.selectedId, 'profile-one');
          expect(owner.pinnedId, 'profile-two');
          for (final s in owner.states.where((s) => !s.isCurrent)) {
            expect(
              s.usage!.fetchedAt.millisecondsSinceEpoch,
              now.millisecondsSinceEpoch,
            );
          }
          await tester.runAsync(() async {
            owner.rename('current', 'renamed');
            await owner.saved;
          });
          final saved = jsonDecode((await tester.runAsync(file.readAsString))!);
          expect(saved['cycles'], cycles);
          expect(saved['sources'], hasLength(3));
          expect(saved['selectedId'], 'profile-one');
          expect(saved['pinnedId'], 'profile-two');
        }
        expect(service.queries, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => temp.delete(recursive: true));
      },
    );
  }

  testWidgets(
    'failed exit retries cleanup and joins durable save before exactly one native exit',
    (tester) async {
      final calls = <String>[];
      final notices = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
        calls.add(call.method);
        return call.method == 'mainVisible' ? true : null;
      });
      final service = _RetryShutdown();
      final store = _SaveGate();
      final owner = AccountSourcesController(service, store);
      await owner.initialize(() => '');
      final usage = AccountUsageController(ForbiddenLegacy(), sources: owner);
      final bridge = DesktopMonitor(usage, () => '', onNotice: notices.add)
        ..start();
      addTearDown(() {
        bridge.dispose();
        usage.dispose();
        owner.dispose();
        messenger.setMockMethodCallHandler(DesktopMonitor.channel, null);
      });
      store.gate = Completer<void>();
      owner.rename('current', 'Durable');
      final first = nativeAction('exit');
      await tester.pump();
      expect(calls.where((c) => c == 'exit'), isEmpty);
      expect(
        notices,
        isEmpty,
        reason: 'Failure reporting also joins pending saves',
      );
      store.gate!.complete();
      await tester.pump();
      await first;
      expect(calls.where((c) => c == 'exit'), isEmpty);
      expect(owner.canOperate, isFalse);
      expect(notices, isNotEmpty);
      expect(owner.shutdownState, 'failed');
      final retry = nativeAction('exit');
      await tester.pump();
      expect(service.shutdowns, 2);
      expect(owner.shutdownState, 'pending');
      expect(calls.where((c) => c == 'exit'), isEmpty);
      service.cleanup.complete();
      await tester.pump();
      await retry;
      expect(owner.shutdownState, 'succeeded');
      expect((await store.read())['sources'][0]['alias'], 'Durable');
      await nativeAction('exit');
      expect(calls.where((c) => c == 'exit'), hasLength(1));
      bridge.dispose();
    },
  );

  for (final terminal in ['succeeded', 'failed', 'timed_out', 'cancelled']) {
    testWidgets(
      'native cancel preserves $terminal in login UI and rejects late status',
      (tester) async {
        final backend = _LoginEnvelope(terminal);
        final native = NativeAccountSourcesService(backend);
        final owner = AccountSourcesController(
          native,
          AccountSourceStore.memory(),
        );
        await owner.initialize(() => '');
        final id = (await owner.create('Race'))!;
        await owner.login(id);
        backend.statusGate = Completer<Map<String, dynamic>>();
        final lateStatus = owner.pollLogin(id);
        await tester.pumpWidget(
          sourcesHost(
            SingleChildScrollView(child: AccountSourcesPanel(owner: owner)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('官方登录进行中'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
        await tester.pumpAndSettle();
        expect(owner.states.last.loginState, terminal);
        expect(
          find.text(switch (terminal) {
            'succeeded' => '登录已完成。',
            'failed' => '登录未完成，请重试。',
            'timed_out' => '登录超时，请重试。',
            _ => '登录已取消。',
          }),
          findsOneWidget,
        );
        backend.statusGate!.complete(backend.envelope('succeeded'));
        await lateStatus;
        expect(owner.states.last.loginState, terminal);
        expect(owner.states.last.usage, isNull);
        expect(backend.commands, isNot(contains('account_source_usage')));
        await tester.pumpWidget(const SizedBox());
        owner.dispose();
      },
    );
  }

  test('late native cancellation success cannot resurrect removed source or cached usage', () async {
    final backend = _LoginEnvelope('succeeded');
    final store = AccountSourceStore.memory();
    final owner = AccountSourcesController(
      NativeAccountSourcesService(backend),
      store,
    );
    await owner.initialize(() => '');
    final id = (await owner.create('Race'))!;
    await owner.login(id);
    backend.cancelGate = Completer<Map<String, dynamic>>();
    final cancel = owner.cancelLogin(id);
    await owner.remove(id);
    backend.cancelGate!.complete(backend.envelope('succeeded'));
    await cancel;
    await owner.saved;
    expect(owner.states.map((s) => s.id), ['current']);
    expect(jsonEncode(await store.read()), isNot(contains(id)));
    expect(backend.commands, isNot(contains('account_source_usage')));
    owner.dispose();
  });

  test('native cancellation rejects missing or nonterminal outcomes', () async {
    for (final state in ['', 'waiting', 'starting', 'unknown']) {
      await expectLater(
        NativeAccountSourcesService(_LoginEnvelope(state))
            .loginCancel('profile-race', 'job-race'),
        throwsA(isA<SourceFailure>()),
      );
    }
  });

  testWidgets(
    'literal suffixed aliases retain every selectable source exactly once',
    (tester) async {
      final f = await syntheticMultiFixture();
      f.owner.rename('current', 'A');
      f.owner.rename('profile-stale', 'A');
      f.owner.rename('profile-unknown', 'A · 1');
      await tester.pumpWidget(sourcesHost(AccountSourcesPanel(owner: f.owner)));
      await tester.pumpAndSettle();
      final choice = tester.widget<MonitorChoice>(
        find.byKey(const ValueKey('account-source-selector')),
      );
      expect(choice.items.values.toList()..sort(), [
        'current',
        'profile-stale',
        'profile-unknown',
      ]);
      for (final id in choice.items.values) {
        choice.onChanged(id);
        expect(f.owner.selectedId, id);
      }
      await tester.pumpWidget(const SizedBox());
      f.owner.dispose();
      f.metrics.dispose();
    },
  );

  testWidgets(
    'paused overview minute tick updates age stale and reset without queries',
    (tester) async {
      var now = DateTime.now();
      final service = SyntheticMultiSources();
      final store = AccountSourceStore.memory();
      await store.write({
        'sources': [
          {
            'id': 'current',
            'alias': 'Clock',
            'usage': sample(
              now
                  .subtract(const Duration(days: 1))
                  .add(const Duration(seconds: 30)),
              40,
            ).toCacheJson(),
          },
        ],
      });
      final owner = AccountSourcesController(service, store, now: () => now);
      await owner.initialize(() => '');
      // Preserve a recent observation while the known reset crosses in 30 seconds.
      final usage = owner.selected!.usage!;
      owner.selected!.usage = service.sample('current', observed: now);
      final cache = owner.selected!.usage!.toCacheJson();
      cache['buckets'] = usage.toCacheJson()['buckets'];
      await store.write({
        'sources': [
          {'id': 'current', 'alias': 'Clock', 'usage': cache},
        ],
      });
      owner.dispose();
      final clockOwner = AccountSourcesController(
        service,
        store,
        now: () => now,
      );
      await clockOwner.initialize(() => '');
      await tester.pumpWidget(
        sourcesHost(
          SingleChildScrollView(child: AccountSourcesPanel(owner: clockOwner)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('toggle-source-overview')));
      await tester.pumpAndSettle();
      expect(find.text('观测于 0 分钟前'), findsOneWidget);
      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 5));
      expect(find.text('观测于 5 分钟前 · 数据已过期'), findsOneWidget);
      final bars = tester
          .widgetList<MonitorBarChart>(find.byType(MonitorBarChart))
          .last
          .bars;
      expect(bars.single.detail, '到期 · 待查询');
      expect(bars.single.value, isNull);
      expect(service.queries, isEmpty);
      await tester.pumpWidget(const SizedBox());
      clockOwner.dispose();
      await tester.pump(const Duration(minutes: 1));
      expect(tester.takeException(), isNull);
    },
  );
}
