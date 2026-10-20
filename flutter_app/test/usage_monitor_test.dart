import 'dart:async';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_usage_test.dart' show usageResponse;

class MonitorService implements LimitsUsageService {
  int light = 0, full = 0;
  Object? failure;
  Completer<AccountUsage>? pending;
  String identity = 'account-A';
  @override
  Future<AccountUsage> query(String path) async {
    full++;
    return read(true);
  }

  @override
  Future<AccountUsage> queryLimits(String path) async {
    light++;
    return read(false);
  }

  Future<AccountUsage> read(bool details) async {
    if (pending != null) return pending!.future;
    if (failure != null) throw failure!;
    final response = usageResponse();
    response['identityKey'] = identity;
    response['detailsIncluded'] = details;
    if (!details) response['tokenUsage'] = null;
    return AccountUsage.fromJson(response);
  }
}

void main() {
  testWidgets(
    'one automatic owner survives absent views; pause stops polling',
    (tester) async {
      final service = MonitorService();
      final controller = AccountUsageController(service);
      controller.startMonitoring(
        () => 'desktop',
        every: const Duration(seconds: 2),
      );
      await tester.pump();
      expect(service.light, 1);
      expect(service.full, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(service.light, 2);
      expect(controller.revision, 2);
      final tray = controller.desktopSnapshot, pet = controller.desktopSnapshot;
      expect(tray['revision'], pet['revision']);
      expect(tray['remaining'], 92.0);
      controller.pause();
      await tester.pump(const Duration(seconds: 30));
      expect(service.light, 2);
      controller.dispose();
    },
  );

  testWidgets(
    'failure keeps cache, backs off, rejects manual bypass and recovers',
    (tester) async {
      var now = DateTime(2026);
      final service = MonitorService();
      final monitor = AccountUsageController(service, now: () => now);
      monitor.startMonitoring(
        () => 'desktop',
        every: const Duration(seconds: 1),
      );
      await tester.pump();
      final cached = monitor.data;
      service.failure = StateError('网络离线');
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(identical(monitor.data, cached), isTrue);
      expect(monitor.stale, isTrue);
      expect(
        monitor.nextRefreshAt!.difference(now),
        const Duration(seconds: 30),
      );
      await monitor.query('desktop');
      expect(service.full, 0);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(monitor.failures, 2);
      expect(
        monitor.nextRefreshAt!.difference(now),
        const Duration(seconds: 60),
      );
      service.failure = null;
      now = now.add(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(monitor.failures, 0);
      expect(monitor.error, isNull);
      expect(monitor.revision, 2);
      monitor.dispose();
    },
  );

  testWidgets('manual and automatic reads cannot overlap', (tester) async {
    final service = MonitorService()..pending = Completer<AccountUsage>();
    final monitor = AccountUsageController(service);
    monitor.startMonitoring(() => 'desktop', every: const Duration(seconds: 1));
    await monitor.query('desktop');
    await tester.pump(const Duration(seconds: 10));
    expect(service.light, 1);
    expect(service.full, 0);
    service.pending!.complete(AccountUsage.fromJson(usageResponse()));
    await tester.pump();
    expect(monitor.busy, isFalse);
    monitor.dispose();
  });

  testWidgets(
    'source changes discard late results and auth failure clears cache',
    (tester) async {
      final service = MonitorService();
      final monitor = AccountUsageController(service);
      await monitor.query('desktop');
      expect(monitor.data, isNotNull);
      service.failure = StateError('登录状态已失效');
      await monitor.query('desktop');
      expect(monitor.data, isNull);
      service.failure = null;
      service.pending = Completer<AccountUsage>();
      final read = monitor.query('old-path');
      monitor.sourceChanged('new-path');
      service.pending!.complete(AccountUsage.fromJson(usageResponse()));
      await read;
      expect(monitor.data, isNull);
      monitor.dispose();
    },
  );

  testWidgets(
    'light snapshots retain detailed tokens only for the same account',
    (tester) async {
      final service = MonitorService();
      final monitor = AccountUsageController(service);
      await monitor.query('desktop');
      expect(monitor.data!.lifetimeTokens, 1234567);
      await monitor.query('desktop', details: false);
      expect(monitor.data!.lifetimeTokens, 1234567);
      service.identity = 'account-B';
      await monitor.query('desktop', details: false);
      expect(monitor.data!.lifetimeTokens, isNull);
      monitor.dispose();
    },
  );

  testWidgets('disposed monitor never keeps a pending result or timer', (
    tester,
  ) async {
    final service = MonitorService()..pending = Completer<AccountUsage>();
    final monitor = AccountUsageController(service);
    monitor.startMonitoring(() => 'desktop');
    monitor.dispose();
    service.pending!.complete(AccountUsage.fromJson(usageResponse()));
    await tester.pump();
    expect(monitor.data, isNull);
  });
}
