import 'dart:async';

import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_attention_test.dart'
    show AttentionFeed, MemoryAttentionStore, observation;
import 'monitor_lifecycle_test.dart' show LifecycleService, nativeAction;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final snapshots = <Map<Object?, Object?>>[];
  final calls = <String>[];
  setUp(() {
    snapshots.clear();
    calls.clear();
    messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'mainVisible') return true;
      if (call.method == 'publish') {
        snapshots.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
  );
  testWidgets(
    'attention A completion survives selected B running; serial and click routes independent',
    (tester) async {
      final feed = AttentionFeed()
        ..values.addAll({
          'a': observation('a', 'a0', 'running'),
          'b': observation('b', 'b0', 'running'),
        });
      final attention = SessionAttentionController(feed);
      final store = MemoryAttentionStore();
      await attention.initialize(store);
      await attention.watch('a', expectedId: 'a');
      await attention.watch('b', expectedId: 'b');
      final metrics = SessionMetricsController(feed)
        ..select('b', expectedId: 'b');
      final usage = AccountUsageController(LifecycleService())
        ..sessionAlertsEnabled = true;
      int inbox = 0, legacy = 0;
      final bridge = DesktopMonitor(
        usage,
        () => '',
        metrics: metrics,
        attention: attention,
        onAttentionDetails: () => inbox++,
        onSessionDetails: () => legacy++,
      )..start();
      await tester.pump();
      await attention.poll();
      feed.values['a'] = observation('a', 'a0', 'completed');
      await attention.poll();
      await tester.pump();
      expect(snapshots.last['sessionStatus'], 1);
      expect(snapshots.last['attentionAlertSerial'], 1);
      expect(snapshots.last['attentionAlertStatus'], 2);
      expect(snapshots.last['sessionAlertSerial'], 0);
      expect(inbox, 0);
      expect(legacy, 0);
      feed.values['b'] = observation('b', 'b0', 'completed');
      await attention.poll();
      await metrics.poll();
      await tester.pump();
      expect(snapshots.last['attentionAlertSerial'], 2);
      expect(snapshots.last['sessionAlertSerial'], 0);
      await attention.unwatch(
        attention.watches.firstWhere((w) => w.path == 'b').key,
      );
      feed.values['b'] = observation('b', 'b-new', 'running');
      await metrics.poll();
      feed.values['b'] = observation('b', 'b-new', 'completed');
      await metrics.poll();
      await tester.pump();
      expect(
        snapshots.last['sessionAlertSerial'],
        1,
        reason: 'unwatched selection retains legacy owner',
      );
      expect(snapshots.last['attentionAlertSerial'], 2);
      await nativeAction('systemSuspend');
      await nativeAction('systemResume');
      feed.values['a'] = observation('a', 'during-suspend', 'completed');
      await attention.poll();
      await tester.pump();
      expect(attention.notices.length, 2, reason: 'resume silently baselines');
      usage.sessionMutedUntil = DateTime.now().add(const Duration(hours: 1));
      usage.notifyListeners();
      await tester.pump();
      feed.values['a'] = observation('a', 'muted', 'running');
      await attention.poll();
      feed.values['a'] = observation('a', 'muted', 'completed');
      await attention.poll();
      await tester.pump();
      expect(attention.notices.length, 3);
      expect(attention.alertSerial, 2);
      await nativeAction('attentionDetails');
      expect(inbox, 1);
      expect(legacy, 0);
      await nativeAction('sessionDetails');
      expect(inbox, 1);
      expect(legacy, 1);
      await nativeAction('closeRequested');
      expect(calls, contains('hide'));
      expect(attention.watches.length, 1);
      bridge.dispose();
      attention.dispose();
      metrics.dispose();
      usage.dispose();
    },
  );
  testWidgets(
    'attention shutdown failure blocks native exit and explicit retry waits for save',
    (tester) async {
      final attention = SessionAttentionController(AttentionFeed());
      final store = MemoryAttentionStore();
      await attention.initialize(store);
      final usage = AccountUsageController(LifecycleService());
      final bridge = DesktopMonitor(usage, () => '', attention: attention)
        ..start();
      await tester.pump();
      store.fail = true;
      await nativeAction('exit');
      expect(calls.where((c) => c == 'exit'), isEmpty);
      store.fail = false;
      store.writeGate = Completer<void>();
      final retry = nativeAction('exit');
      await tester.pump();
      expect(calls.where((c) => c == 'exit'), isEmpty);
      store.writeGate!.complete();
      await retry;
      expect(calls.where((c) => c == 'exit').length, 1);
      bridge.dispose();
      attention.dispose();
      usage.dispose();
    },
  );
}
