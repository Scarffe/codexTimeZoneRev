import 'dart:async';

import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_store.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
import 'support/compact_dashboard_fixture.dart';
import 'monitor_lifecycle_test.dart' show nativeAction;

class _Usage implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) =>
      throw StateError('Legacy forbidden');
}

class _Sources extends SyntheticMultiSources {
  final shutdownGate = Completer<void>();
  @override
  Future<void> shutdown() async {
    shutdowns++;
    await shutdownGate.future;
  }
}

class _History implements QuotaHistorySink {
  final appendGate = Completer<void>();
  bool flushing = false;
  @override
  Future<void> append(QueryHistoryRecord record) => appendGate.future;
  @override
  Future<void> removeSource(String id) async {}
  @override
  Future<void> flush() async {
    flushing = true;
    await appendGate.future;
    throw StateError('fixture history flush failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
      calls.add(call.method);
      return call.method == 'mainVisible' ? true : null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
  );

  testWidgets(
    'true exit joins history flush and still exits after its failure',
    (tester) async {
      final service = SyntheticMultiSources();
      final history = _History();
      final owner = AccountSourcesController(
        service,
        AccountSourceStore.memory(),
        historySink: history,
      );
      await owner.initialize(() => '');
      final id = (await owner.create('Fixture'))!;
      await owner.refresh(id);
      final usage = AccountUsageController(_Usage(), sources: owner);
      final bridge = DesktopMonitor(usage, () => '')..start();
      await tester.pump();
      final exit = nativeAction('exit');
      await tester.pump();
      expect(service.shutdowns, 1);
      expect(history.flushing, isTrue);
      expect(calls, isNot(contains('exit')));
      history.appendGate.complete();
      await tester.pump();
      await exit;
      expect(calls.where((c) => c == 'exit'), hasLength(1));
      expect(owner.shutdownState, 'succeeded');
      expect(owner.historyError, isNotNull);
      bridge.dispose();
      usage.dispose();
      owner.dispose();
    },
  );

  testWidgets(
    'application shares explicit memory history with injected source owner',
    (tester) async {
      timezone.initializeTimeZones();
      SharedPreferences.setMockInitialValues({});
      final service = SyntheticMultiSources();
      final owner = AccountSourcesController(
        service,
        AccountSourceStore.memory(),
        offlineTrial: true,
      );
      final history = QuotaHistoryStore.memory();
      await tester.pumpWidget(
        LauncherApplication(
          preview: true,
          offlineTrial: true,
          backend: CompactDashboardBackend(),
          sourceController: owner,
          historyStore: history,
          desktop: SyntheticMultiDesktop(),
        ),
      );
      await tester.pumpAndSettle();
      expect(owner.historySink, same(history));
      final id = (await owner.create('Fixture'))!;
      await owner.refresh(id);
      final read = await history.read(
        QuotaHistoryFilter(
          sourceId: id,
          fromUtc: DateTime.utc(2026),
          toUtc: DateTime.utc(2027),
        ),
      );
      expect(read.records, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'tray refresh uses pinned source independently of selected quota',
    (tester) async {
      final service = SyntheticMultiSources();
      final owner = AccountSourcesController(
        service,
        AccountSourceStore.memory(),
      );
      await owner.initialize(() => '');
      final pinnedId = (await owner.create('Pinned'))!;
      final id = (await owner.create('Other'))!;
      owner.select(id);
      final usage = AccountUsageController(_Usage(), sources: owner);
      final bridge = DesktopMonitor(usage, () => '')..start();
      await tester.pump();
      await nativeAction('refresh');
      expect(service.queries, [pinnedId]);
      expect(owner.pinnedId, pinnedId);
      expect(owner.selectedId, id);
      bridge.dispose();
      usage.dispose();
      owner.dispose();
    },
  );

  testWidgets(
    'hide keeps login alive and true exit joins source shutdown before native exit',
    (tester) async {
      final service = _Sources();
      final owner = AccountSourcesController(
        service,
        AccountSourceStore.memory(),
      );
      await owner.initialize(() => '');
      final id = (await owner.create('Other'))!;
      final usage = AccountUsageController(_Usage(), sources: owner);
      final bridge = DesktopMonitor(usage, () => '')..start();
      await owner.login(id);
      await tester.pump();
      // A login is independent of the selected source's short query busy flag.
      final close = nativeAction('closeRequested');
      await tester.pump();
      expect(calls, contains('hide'));
      expect(service.shutdowns, 0);
      await close;
      final exit = nativeAction('exit');
      await tester.pump();
      expect(service.shutdowns, 1);
      expect(calls, isNot(contains('exit')));
      service.shutdownGate.complete();
      await tester.pump();
      await exit;
      expect(calls.where((c) => c == 'exit').length, 1);
      bridge.dispose();
      usage.dispose();
      owner.dispose();
    },
  );
}
