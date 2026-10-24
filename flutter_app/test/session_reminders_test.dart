import 'dart:io';

import 'package:codex_timezone/services/desktop_monitor.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/monitor_preferences.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';

import 'session_metrics_test.dart' show NoUsage;

Map<String, dynamic> state(
  String id,
  String status, {
  int epoch = 1,
  bool catching = false,
  List<String> history = const [],
}) => {
  'logEpoch': epoch,
  'catchingUp': catching,
  'current': {'turnId': id, 'status': status},
  'terminals': [
    if (status != 'running')
      {'turnId': id, 'status': status, 'durationMs': 2000},
    for (final h in history) {'turnId': h, 'status': 'completed'},
  ],
};

class Feed implements LauncherBackend {
  Map<String, dynamic> value = state('old', 'completed');
  bool fail = false;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (fail) throw const FileSystemException('fixture read failure');
    return value;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);
void main() {
  testWidgets(
    'hidden surfaces share session state and alert without quota query',
    (tester) async {
      final snapshots = <Map<Object?, Object?>>[];
      final notices = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
        if (call.method == 'publish') {
          snapshots.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        if (call.method == 'mainVisible') return false;
        return null;
      });
      final usage = AccountUsageController(NoUsage())
        ..savedMonitoring = false
        ..sessionAlertsEnabled = true;
      final feed = Feed();
      final metrics = SessionMetricsController(feed);
      final monitor = DesktopMonitor(
        usage,
        () => '',
        metrics: metrics,
        onNotice: notices.add,
      )..start();
      metrics.select('fixture');
      await tester.pump();
      expect(snapshots.last['sessionAlert'], '');
      expect(snapshots.last['sessionStatus'], 2);
      feed.value = state('live', 'running');
      await metrics.poll();
      await tester.pump();
      expect(snapshots.last['sessionStatus'], 1);
      expect(snapshots.last['sessionSummary'], contains('回合进行中'));
      feed.value = state('live', 'completed');
      await metrics.poll();
      await tester.pump();
      expect(snapshots.last['sessionAlertSerial'], 1);
      expect(snapshots.last['sessionAlert'], contains('回合已结束'));
      expect(notices, hasLength(1));
      expect(notices.single, contains('回合已结束'));
      await metrics.poll();
      await tester.pump(const Duration(seconds: 1));
      expect(notices.length, 1);
      expect(usage.attempts, 0);
      expect(usage.mainWindowVisible, false);
      feed.fail = true;
      await metrics.poll();
      await tester.pump();
      expect(snapshots.last['sessionStatus'], 4);
      expect(snapshots.last['sessionAlert'], '');
      expect(notices.length, 1);
      monitor.dispose();
      metrics.dispose();
      usage.dispose();
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );

  test(
    'history and repeated terminal records never produce duplicate reminders',
    () async {
      final b = Feed();
      final c = SessionMetricsController(b)
        ..configureReminders(enabled: true)
        ..select('fixture');
      await settle();
      expect(c.alertSerial, 0);
      expect(c.stateLabel, '回合已结束');
      b.value = state('live', 'running', history: ['old']);
      await c.poll();
      expect(c.stateLabel, '回合进行中');
      b.value = state('live', 'completed', history: ['old']);
      await c.poll();
      expect(c.alertSerial, 1);
      expect(c.alert, contains('回合已结束'));
      await c.poll();
      await c.poll();
      expect(c.alertSerial, 1);
      c.select('other');
      await settle();
      expect(c.alertSerial, 1);
      expect(c.alert, '');
      c.dispose();
    },
  );
  test(
    'catch-up, log reset and read recovery establish a silent baseline',
    () async {
      final b = Feed()..value = state('old', 'completed', catching: true);
      final c = SessionMetricsController(b)
        ..configureReminders(enabled: true)
        ..select('fixture');
      await settle();
      expect(c.stateLabel, contains('正在读取历史'));
      b.value = state('old', 'completed');
      await c.poll();
      expect(c.alertSerial, 0);
      b.fail = true;
      await c.poll();
      expect(c.stateLabel, '状态未知 · 读取失败');
      expect(c.alert, '');
      b.fail = false;
      b.value = state('during-error', 'completed');
      await c.poll();
      expect(c.alertSerial, 0);
      b.value = state('after', 'completed', history: ['during-error']);
      await c.poll();
      expect(c.alertSerial, 1);
      b.value = state('rewrite', 'completed', epoch: 2);
      await c.poll();
      expect(c.alertSerial, 1);
      expect(c.alert, '');
      c.dispose();
    },
  );
  test('cancelled and unknown states do not impersonate completion', () async {
    final b = Feed();
    final c = SessionMetricsController(b)
      ..configureReminders(enabled: true)
      ..select('fixture');
    await settle();
    b.value = state('cancel', 'cancelled', history: ['old']);
    await c.poll();
    expect(c.stateLabel, '已取消');
    expect(c.alertSerial, 0);
    b.value = {'active': false};
    await c.poll();
    expect(c.stateLabel, '状态未知');
    expect(c.alertSerial, 0);
    b.value = state('silent-recovery', 'completed');
    await c.poll();
    expect(c.alertSerial, 0);
    c.dispose();
  });
  test(
    'longer same-session replacement epoch silently baselines history',
    () async {
      final feed = Feed();
      final controller = SessionMetricsController(feed)
        ..configureReminders(enabled: true)
        ..select('same-path');
      addTearDown(controller.dispose);
      await settle();
      feed.value = state('live', 'completed', history: ['old']);
      await controller.poll();
      expect(controller.alertSerial, 1);
      // Rust detects an atomic longer replacement and supplies a new epoch,
      // even though source identity and selected path remain the same.
      feed.value = {
        ...state(
          'replacement-last',
          'completed',
          epoch: 2,
          history: List.generate(40, (index) => 'replacement-history-$index'),
        ),
        'sourceInfo': {
          'id': 'same-session',
          'path': 'same-path',
          'size': 100000,
        },
      };
      await controller.poll();
      expect(controller.alert, '');
      expect(controller.alertSerial, 1);
      await controller.poll();
      expect(controller.alertSerial, 1);
      feed.value = {
        ...state('new-after-replacement', 'completed', epoch: 2),
        'sourceInfo': {'id': 'same-session', 'path': 'same-path'},
      };
      await controller.poll();
      expect(controller.alertSerial, 2);
    },
  );
  test(
    'default-off, enabling and mute expiry never replay past endings',
    () async {
      var now = DateTime(2026, 10, 22);
      final b = Feed();
      final c = SessionMetricsController(b, now: () => now)..select('fixture');
      await settle();
      b.value = state('disabled', 'completed');
      await c.poll();
      expect(c.alertSerial, 0);
      c.configureReminders(enabled: true);
      await c.poll();
      expect(c.alertSerial, 0);
      c.configureReminders(
        enabled: true,
        muteUntil: now.add(const Duration(minutes: 15)),
      );
      await c.poll();
      b.value = state('muted', 'completed');
      await c.poll();
      expect(c.alertSerial, 0);
      now = now.add(const Duration(minutes: 16));
      await c.poll();
      expect(c.alertSerial, 0);
      b.value = state('new', 'completed');
      await c.poll();
      expect(c.alertSerial, 1);
      now = now.add(const Duration(seconds: 11));
      expect(c.alert, '');
      c.dispose();
    },
  );
  test(
    'session reminder preferences persist separately from quota reminders',
    () async {
      final dir = await Directory.systemTemp.createTemp('stage-i-prefs-');
      addTearDown(() => dir.delete(recursive: true));
      final store = MonitorPreferencesStore(File('${dir.path}/prefs.json'));
      final c = AccountUsageController(NoUsage());
      await c.loadPreferences(store);
      expect(c.sessionAlertsEnabled, false);
      c.configureAlerts(enabled: false);
      c.configureSessionAlerts(enabled: true, mute: true);
      await c.settingsSaved;
      final next = AccountUsageController(NoUsage());
      await next.loadPreferences(store);
      expect(next.sessionAlertsEnabled, true);
      expect(next.sessionMuted, true);
      expect(next.alertsEnabled, false);
      expect(MonitorPreferences.fromJson({}).sessionAlerts, false);
      expect(
        MonitorPreferences.fromJson({'sessionMutedUntil': -1})
            .sessionMutedUntil,
        isNull,
      );
      c.dispose();
      next.dispose();
    },
  );
}
