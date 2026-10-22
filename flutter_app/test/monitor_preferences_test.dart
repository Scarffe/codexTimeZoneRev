import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/monitor_preferences.dart';
import 'package:codex_timezone/services/pet_alerts.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';

class SampleService implements AccountUsageService {
  SampleService(this.result);
  AccountUsage result;
  bool fail = false;
  @override
  Future<AccountUsage> query(String path) async {
    if (fail) throw StateError('offline');
    return result;
  }
}

void main() {
  test(
    'fresh and malformed enabled preferences cannot authorize auto query',
    () {
      expect(const MonitorPreferences().enabled, false);
      expect(MonitorPreferences.fromJson({}).enabled, false);
      expect(MonitorPreferences.fromJson({'enabled': 'true'}).enabled, false);
      expect(MonitorPreferences.fromJson({'enabled': true}).enabled, true);
    },
  );
  final now = DateTime.utc(2026, 10, 20);
  AccountUsage sample({
    String identity = 'account-A',
    int hours = 2,
    double used = 95,
  }) => AccountUsage(
    email: null,
    plan: null,
    identityKey: identity,
    fetchedAt: now,
    buckets: [
      UsageBucket(
        label: 'Codex',
        windows: [
          UsageWindow(
            usedPercent: used,
            durationMinutes: 300,
            resetsAt: now.add(Duration(hours: hours)),
          ),
        ],
      ),
    ],
  );
  test(
    'portable preferences roundtrip with atomic replacement and safe defaults',
    () async {
      final dir = await Directory.systemTemp.createTemp('monitor-e-');
      addTearDown(() => dir.delete(recursive: true));
      final store = MonitorPreferencesStore(File('${dir.path}/prefs.json'));
      expect(await store.read(), isEmpty);
      await store.write(
        const MonitorPreferences(
          seconds: 300,
          mode: 2,
          visible: false,
        ).toJson(),
      );
      await store.write(
        const MonitorPreferences(seconds: 600, threshold: 30).toJson(),
      );
      expect(MonitorPreferences.fromJson(await store.read()).seconds, 600);
      expect(
        MonitorPreferences.fromJson({
          'seconds': -1,
          'mode': 55,
          'visible': 'bad',
        }).mode,
        1,
      );
      expect(await File('${store.file.path}.tmp').exists(), false);
    },
  );
  test(
    'only a stored explicit enable restores automatic quota monitoring',
    () async {
      final dir = await Directory.systemTemp.createTemp('monitor-explicit-');
      final store = MonitorPreferencesStore(File('${dir.path}/prefs.json'));
      addTearDown(() => dir.delete(recursive: true));
      for (final enabled in [false, true]) {
        await store.write({'enabled': enabled});
        final usage = AccountUsageController(
          SampleService(sample()),
          now: () => now,
        );
        await usage.loadPreferences(store);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              DesktopMonitor.channel,
              (_) async => null,
            );
        final bridge = DesktopMonitor(usage, () => 'fixture')..start();
        await Future<void>.delayed(Duration.zero);
        expect(usage.attempts, enabled ? 1 : 0);
        expect(usage.monitoring, enabled);
        bridge.dispose();
        await usage.settingsSaved;
        usage.dispose();
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );
  testWidgets(
    'recent quota notice deduplicates and ignores stale or failed results',
    (tester) async {
      var clock = now;
      final notices = <String>[];
      final service = SampleService(sample());
      final usage = AccountUsageController(service, now: () => clock);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopMonitor.channel, (_) async => null);
      final bridge = DesktopMonitor(
        usage,
        () => 'fixture',
        onNotice: notices.add,
      )..start();
      await usage.query('fixture');
      await tester.pump();
      expect(notices, hasLength(1));
      expect(notices.single, contains('额度'));
      await tester.pump(const Duration(seconds: 1));
      await usage.query('fixture');
      expect(notices.length, 1);
      service.result = sample(hours: 3);
      clock = now.add(const Duration(minutes: 10));
      await usage.query('fixture');
      expect(notices.length, 1);
      service.fail = true;
      await usage.query('fixture');
      expect(notices.length, 1);
      bridge.dispose();
      usage.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );
  test('corrupt input is backed up before the first replacement', () async {
    final dir = await Directory.systemTemp.createTemp('monitor-e-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/prefs.json');
    await file.writeAsString('broken');
    final c = AccountUsageController(SampleService(sample()));
    await c.loadPreferences(MonitorPreferencesStore(file));
    expect(c.preferencesError, isNotNull);
    c.configureAlerts(threshold: 30);
    await c.settingsSaved;
    final backup = await dir
        .list()
        .where((f) => f.path.endsWith('.bak'))
        .single;
    expect(await File(backup.path).readAsString(), 'broken');
    c.dispose();
  });
  test('all settings and muted cycle survive controller restart without plaintext identity', () async {
    final dir = await Directory.systemTemp.createTemp('monitor-e-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/prefs.json');
    final a = AccountUsageController(SampleService(sample()), now: () => now);
    await a.loadPreferences(MonitorPreferencesStore(file));
    a.setInterval(const Duration(minutes: 5));
    a.configurePet(mode: 2, visible: false);
    a.setLocalTime(false);
    a.configureAlerts(threshold: 30);
    await a.query('fixture');
    expect(a.desktopSnapshot['alert'], isNotEmpty);
    a.muteCurrentCycle();
    expect(a.cycleMuted, true);
    a.pause();
    await a.settingsSaved;
    a.dispose();
    final persisted = await file.readAsString();
    expect(persisted, isNot(contains('account-A')));
    final service = SampleService(sample());
    final b = AccountUsageController(service, now: () => now);
    await b.loadPreferences(MonitorPreferencesStore(file));
    expect(b.interval.inSeconds, 300);
    expect(b.alertThreshold, 30);
    expect(b.petMode, 2);
    expect(b.petVisible, false);
    expect(b.savedMonitoring, false);
    expect(b.useLocalTime, false);
    await b.query('fixture');
    expect(b.desktopSnapshot['alert'], '');
    service.result = sample(identity: 'account-B');
    await b.query('fixture');
    expect(b.desktopSnapshot['alert'], isNotEmpty);
    service.result = sample(hours: 3);
    await b.query('fixture');
    expect(b.desktopSnapshot['alert'], isNotEmpty);
    await b.settingsSaved;
    b.dispose();
    expect(jsonDecode(persisted)['version'], 1);
  });
  test('disabled, stale and failed results cannot emit alerts', () async {
    var clock = now;
    final service = SampleService(sample());
    final c = AccountUsageController(service, now: () => clock);
    c.configureAlerts(enabled: false);
    await c.query('fixture');
    expect(c.desktopSnapshot['alert'], '');
    c.configureAlerts(enabled: true);
    clock = now.add(const Duration(minutes: 10));
    await c.query('fixture');
    expect(c.desktopSnapshot['alert'], '');
    clock = now;
    await c.query('fixture');
    expect(c.desktopSnapshot['alert'], isNotEmpty);
    service.fail = true;
    await c.query('fixture');
    expect(c.desktopSnapshot['alert'], '');
    expect(c.desktopSnapshot['text'], contains('上次观测'));
    c.dispose();
  });
  test(
    'a write failure is visible and leaves runtime preferences usable',
    () async {
      final dir = await Directory.systemTemp.createTemp('monitor-e-');
      addTearDown(() => dir.delete(recursive: true));
      final c = AccountUsageController(SampleService(sample()), now: () => now);
      await c.loadPreferences(
        MonitorPreferencesStore(File('${dir.path}/missing/prefs.json')),
      );
      c.configurePet(mode: 0);
      await c.settingsSaved;
      expect(c.petMode, 0);
      expect(c.preferencesError, contains('保存失败'));
      c.dispose();
    },
  );
  testWidgets('interval edits preserve the existing failure cooldown', (
    tester,
  ) async {
    var clock = now;
    final service = SampleService(sample())..fail = true;
    final c = AccountUsageController(service, now: () => clock);
    c.startMonitoring(() => 'fixture');
    await tester.pump();
    final deadline = c.nextRefreshAt;
    c.setInterval(const Duration(minutes: 10));
    expect(c.nextRefreshAt, deadline);
    clock = now.add(const Duration(seconds: 30));
    c.setInterval(const Duration(minutes: 1));
    expect(c.nextRefreshAt, deadline);
    c.dispose();
  });
  testWidgets(
    'desktop monitor honors saved intervals and explicit test overrides',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopMonitor.channel, (_) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DesktopMonitor.channel, null),
      );
      final normal = AccountUsageController(
        SampleService(sample()),
        now: () => now,
      );
      normal.setInterval(const Duration(minutes: 5));
      final monitor = DesktopMonitor(normal, () => 'fixture')..start();
      await tester.pump();
      expect(normal.interval.inSeconds, 300);
      monitor.dispose();
      normal.dispose();
      final fast = AccountUsageController(
        SampleService(sample()),
        now: () => now,
      )..savedMonitoring = true;
      final testMonitor = DesktopMonitor(
        fast,
        () => 'fixture',
        interval: const Duration(seconds: 5),
      )..start();
      await tester.pump();
      expect(fast.attempts, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(fast.attempts, 2);
      testMonitor.dispose();
      fast.dispose();
    },
  );
  test(
    'custom threshold escalates once and cycle keys survive window reordering',
    () {
      final policy = PetAlerts();
      expect(policy.observe(sample(used: 75), now, threshold: 30), isNotNull);
      expect(policy.observe(sample(used: 80), now, threshold: 30), isNull);
      expect(policy.observe(sample(), now, threshold: 30), isNotNull);
      final restored = PetAlerts()..restore(policy.records(now), now);
      expect(restored.observe(sample(), now), isNull);
      expect(restored.observe(sample(hours: 3), now), isNotNull);
    },
  );
}
