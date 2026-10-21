import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/monitor_preferences.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';

class AnimationUsage implements AccountUsageService {
  int calls = 0;
  Object? failure;
  Completer<AccountUsage>? pending;
  late AccountUsage value;
  @override
  Future<AccountUsage> query(String path) async {
    calls++;
    if (failure != null) throw failure!;
    return pending?.future ?? value;
  }
}

void main() {
  final now = DateTime.utc(2026, 10, 20);
  AccountUsage sample(double used, {DateTime? fetched}) => AccountUsage(
    email: null,
    plan: null,
    identityKey: 'test',
    fetchedAt: fetched ?? now,
    buckets: [
      UsageBucket(
        label: 'Codex',
        windows: [
          UsageWindow(
            usedPercent: used,
            durationMinutes: 300,
            resetsAt: now.add(const Duration(hours: 2)),
          ),
        ],
      ),
    ],
  );
  test('animation tracks shared freshness, busy and threshold without additional queries', () async {
    var clock = now;
    final service = AnimationUsage()..value = sample(20);
    final c = AccountUsageController(service, now: () => clock);
    expect(c.desktopSnapshot['animationState'], 3);
    final query = c.query('fixture');
    expect(c.desktopSnapshot['animationState'], 1);
    await query;
    expect(c.desktopSnapshot['animationState'], 0);
    service.value = sample(85);
    await c.query('fixture');
    expect(c.desktopSnapshot['animationState'], 2);
    c.configureAlerts(threshold: 10);
    expect(c.desktopSnapshot['animationState'], 0);
    c.configureAlerts(threshold: 30, enabled: false);
    expect(c.desktopSnapshot['animationState'], 2);
    c.setReducedMotion(true);
    for (var i = 0; i < 10000; i++) {
      expect(c.desktopSnapshot['reducedMotion'], true);
    }
    expect(service.calls, 2);
    expect(c.desktopSnapshot['alert'], '');
    clock = now.add(const Duration(minutes: 5));
    expect(c.desktopSnapshot['animationState'], 3);
    clock = now;
    service.failure = StateError('isolated offline');
    await c.query('fixture');
    expect(c.desktopSnapshot['animationState'], 3);
    c.dispose();
  });
  test('reduced motion survives restart and old preferences default to full animation', () async {
    final dir = await Directory.systemTemp.createTemp('animation-prefs-');
    addTearDown(() => dir.delete(recursive: true));
    final store = MonitorPreferencesStore(File('${dir.path}/prefs.json'));
    final service = AnimationUsage()..value = sample(20);
    final a = AccountUsageController(service, now: () => now);
    await a.loadPreferences(store);
    expect(a.reducedMotion, false);
    a.setReducedMotion(true);
    await a.settingsSaved;
    a.dispose();
    final b = AccountUsageController(service, now: () => now);
    await b.loadPreferences(MonitorPreferencesStore(store.file));
    expect(b.reducedMotion, true);
    b.dispose();
    expect(
      MonitorPreferences.fromJson({'version': 1, 'reducedMotion': 'invalid'})
          .reducedMotion,
      false,
    );
  });
  testWidgets(
    'a failed refresh becomes static and recovers only after backoff',
    (tester) async {
      var clock = now;
      final service = AnimationUsage()..value = sample(20);
      final c = AccountUsageController(service, now: () => clock);
      c.startMonitoring(() => 'fixture', every: const Duration(seconds: 1));
      await tester.pump();
      service.failure = StateError('isolated offline');
      clock = clock.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(c.desktopSnapshot['animationState'], 3);
      final calls = service.calls;
      for (var i = 0; i < 10; i++) {
        c.setReducedMotion(i.isEven);
        c.configurePet(mode: i % 3);
      }
      await c.query('fixture');
      expect(service.calls, calls);
      service.failure = null;
      clock = clock.add(const Duration(seconds: 30));
      service.value = sample(20, fetched: clock);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(c.desktopSnapshot['animationState'], 0);
      expect(c.failures, 0);
      c.dispose();
    },
  );
}
