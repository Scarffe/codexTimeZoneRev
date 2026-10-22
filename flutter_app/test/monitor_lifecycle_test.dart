import 'dart:async';
import 'dart:io';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/monitor_preferences.dart';
import 'package:codex_timezone/services/session_selection.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_usage_test.dart' show usageResponse;
import 'session_reminders_test.dart' show Feed;

class LifecycleService implements AccountUsageService {
  Completer<AccountUsage>? pending;
  @override
  Future<AccountUsage> query(String path) async =>
      pending?.future ?? AccountUsage.fromJson(usageResponse());
}

class PendingPreferences extends MonitorPreferencesStore {
  PendingPreferences() : super(File('unused-preferences-fixture'));
  final writeFinished = Completer<void>();
  @override
  Future<Map<String, dynamic>> read() async => {'enabled': true};
  @override
  Future<void> write(Map<String, Object?> value) => writeFinished.future;
}

class PendingSelection extends SessionSelectionStore {
  PendingSelection() : super(File('unused-selection-fixture'));
  final writeFinished = Completer<void>();
  @override
  Future<Map<String, dynamic>> read() async => {};
  @override
  Future<void> write(Map<String, Object?> value) => writeFinished.future;
}

Future<void> nativeAction(String method) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        DesktopMonitor.channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) => done.complete(),
      );
  await done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  final snapshots = <Map<Object?, Object?>>[];
  setUp(() {
    calls.clear();
    snapshots.clear();
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

  testWidgets('fresh startup publishes no keepalive and never queries quota', (
    tester,
  ) async {
    final usage = AccountUsageController(LifecycleService());
    final bridge = DesktopMonitor(usage, () => 'fixture')..start();
    await tester.pump();
    expect(usage.attempts, 0);
    expect(usage.savedMonitoring, false);
    expect(snapshots.last['keepAlive'], false);
    expect(snapshots.last['workspace'], 'launcher');
    expect(snapshots.last['petVisible'], false);
    expect(snapshots.last['roleImage'], '');
    expect(snapshots.last['roleName'], '');
    bridge.dispose();
    usage.dispose();
  });

  testWidgets('ordinary close exits when no collection is enabled', (
    tester,
  ) async {
    final usage = AccountUsageController(LifecycleService())
      ..savedMonitoring = false;
    final bridge = DesktopMonitor(usage, () => 'fixture')..start();
    await tester.pump();
    await nativeAction('closeRequested');
    expect(calls, contains('exit'));
    expect(calls, isNot(contains('hide')));
    bridge.dispose();
    usage.dispose();
  });

  testWidgets(
    'background close hides even with both collectors off and explicit exit exits',
    (tester) async {
      final usage = AccountUsageController(LifecycleService());
      final bridge = DesktopMonitor(
        usage,
        () => 'fixture',
        backgroundStart: true,
      )..start();
      await tester.pump();
      expect(snapshots.last['keepAlive'], false);
      await nativeAction('closeRequested');
      expect(calls.where((c) => c == 'hide').length, 1);
      expect(calls, isNot(contains('exit')));
      await nativeAction('exit');
      expect(calls.where((c) => c == 'exit').length, 1);
      bridge.dispose();
      usage.dispose();
    },
  );

  testWidgets(
    'detail routes sync visibility and workspace without restarting polling',
    (tester) async {
      var workspace = 'launcher';
      final routes = <String>[];
      final usage = AccountUsageController(LifecycleService());
      final bridge = DesktopMonitor(
        usage,
        () => 'fixture',
        workspace: () => workspace,
        onMonitor: () {
          routes.add('monitor');
          workspace = 'monitor';
        },
        onSessionDetails: () {
          routes.add('session');
          workspace = 'monitor';
        },
      )..start();
      await tester.pump();
      usage.setMainWindowVisible(false);
      await nativeAction('monitorDetails');
      expect(usage.mainWindowVisible, true);
      await nativeAction('sessionDetails');
      await tester.pump(const Duration(seconds: 1));
      expect(routes, ['monitor', 'session']);
      expect(snapshots.last['workspace'], 'monitor');
      expect(usage.attempts, 0);
      bridge.dispose();
      usage.dispose();
    },
  );

  testWidgets('quota monitoring and selected session each keep close in tray', (
    tester,
  ) async {
    final usage = AccountUsageController(LifecycleService())
      ..savedMonitoring = false;
    final metrics = SessionMetricsController(Feed());
    final bridge = DesktopMonitor(usage, () => 'fixture', metrics: metrics)
      ..start();
    await tester.pump();
    metrics.select('fixture');
    await tester.pump();
    expect(snapshots.last['keepAlive'], true);
    await nativeAction('closeRequested');
    expect(calls.where((c) => c == 'hide').length, 1);
    metrics.select(null);
    usage.startMonitoring(() => 'fixture');
    await tester.pump();
    await nativeAction('closeRequested');
    expect(calls.where((c) => c == 'hide').length, 2);
    expect(calls, isNot(contains('exit')));
    bridge.dispose();
    metrics.dispose();
    usage.dispose();
  });

  testWidgets(
    'manual busy query waits for cleanup then exits without keepalive',
    (tester) async {
      final service = LifecycleService()..pending = Completer<AccountUsage>();
      final usage = AccountUsageController(service)..savedMonitoring = false;
      final bridge = DesktopMonitor(usage, () => 'fixture')..start();
      final query = usage.query('fixture');
      await tester.pump();
      expect(snapshots.last['keepAlive'], false);
      var closed = false;
      final close = nativeAction('closeRequested').then((_) => closed = true);
      await tester.pump();
      expect(closed, false);
      expect(calls, isNot(contains('exit')));
      service.pending!.complete(AccountUsage.fromJson(usageResponse()));
      await query;
      await tester.pump(const Duration(milliseconds: 100));
      await close;
      expect(calls.where((c) => c == 'exit').length, 1);
      expect(usage.monitoring, false);
      expect(usage.savedMonitoring, false);
      expect(calls, isNot(contains('hide')));
      bridge.dispose();
      usage.dispose();
    },
  );

  testWidgets(
    'explicit exit waits both save queues and coalesces repeated requests',
    (tester) async {
      final preferences = PendingPreferences();
      final selection = PendingSelection();
      final usage = AccountUsageController(LifecycleService());
      final metrics = SessionMetricsController(Feed());
      await usage.loadPreferences(preferences);
      await metrics.initialize(selection);
      final bridge = DesktopMonitor(usage, () => 'fixture', metrics: metrics)
        ..start();
      await tester.pump();
      final firstExit = nativeAction('exit');
      final repeatedExit = nativeAction('exit');
      await tester.pump();
      expect(usage.monitoring, false);
      expect(usage.savedMonitoring, true);
      expect(calls, isNot(contains('exit')));
      preferences.writeFinished.complete();
      await tester.pump();
      expect(calls, isNot(contains('exit')));
      selection.writeFinished.complete();
      await tester.pump();
      await Future.wait([firstExit, repeatedExit]);
      expect(calls.where((c) => c == 'exit').length, 1);
      bridge.dispose();
      metrics.dispose();
      usage.dispose();
    },
  );

  testWidgets('starting twice keeps one polling and publication owner', (
    tester,
  ) async {
    final usage = AccountUsageController(LifecycleService())
      ..savedMonitoring = true;
    final bridge = DesktopMonitor(
      usage,
      () => 'fixture',
      interval: const Duration(seconds: 5),
    );
    bridge.start();
    await tester.pump();
    bridge.start();
    await tester.pump();
    expect(usage.attempts, 1);
    expect(calls.where((c) => c == 'mainVisible').length, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(usage.attempts, 2);
    bridge.dispose();
    usage.dispose();
  });

  testWidgets('legacy pet actions cannot change preferences or open roles', (
    tester,
  ) async {
    var roles = 0;
    final usage = AccountUsageController(LifecycleService())
      ..savedMonitoring = false
      ..configurePet(visible: false, mode: 1);
    final bridge = DesktopMonitor(
      usage,
      () => 'fixture',
      onRoles: () => roles++,
    )..start();
    await tester.pump();
    for (final action in [
      'mode0',
      'mode1',
      'mode2',
      'showPet',
      'hidePet',
      'roles',
      'reduceMotion',
    ]) {
      await nativeAction(action);
    }
    expect(usage.petVisible, false);
    expect(usage.petMode, 1);
    expect(usage.reducedMotion, false);
    expect(roles, 0);
    bridge.dispose();
    usage.dispose();
  });
}
