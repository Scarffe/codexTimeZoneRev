import 'dart:async';

import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';
import 'benchmark_offline_policy_test.dart' show DeniedUsage;
import 'monitor_lifecycle_test.dart' show nativeAction;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  final views = <Map>[];
  setUp(() {
    calls.clear();
    views.clear();
    messenger.setMockMethodCallHandler(DesktopMonitor.channel, (c) async {
      calls.add(c.method);
      if (c.method == 'mainVisible') return true;
      if (c.method == 'publish') views.add(c.arguments as Map);
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
  );
  testWidgets(
    'suspend stops existing quota path before a pending benchmark start returns',
    (tester) async {
      final backend = BenchmarkBackend()..pendingStart = Completer();
      final benchmark = BenchmarkController(BenchmarkService(backend));
      await benchmark.initialize();
      final service = DeniedUsage();
      final usage = AccountUsageController(service);
      final bridge = DesktopMonitor(
        usage,
        () => 'fixture',
        benchmark: benchmark,
      )..start();
      final start = benchmark.start();
      await tester.pump();
      final suspend = nativeAction('systemSuspend');
      await tester.pump();
      await usage.query('fixture');
      final callsBeforeCleanup = service.calls;
      backend.pendingStart!.complete(
        benchmarkFixture(state: 'streaming', cleaning: true),
      );
      await start;
      await suspend;
      expect(callsBeforeCleanup, 0);
      bridge.dispose();
      usage.dispose();
      benchmark.dispose();
    },
  );
  testWidgets(
    'starting/active close hides; suspend interrupts; wake/tray cannot query trial',
    (tester) async {
      final backend = BenchmarkBackend()..pendingStart = Completer();
      final benchmark = BenchmarkController(BenchmarkService(backend));
      await benchmark.initialize();
      final service = DeniedUsage();
      final usage = AccountUsageController(service, offlineTrial: true)
        ..savedMonitoring = true;
      final bridge = DesktopMonitor(
        usage,
        () => 'fixture',
        benchmark: benchmark,
      )..start();
      final start = benchmark.start();
      await tester.pump();
      expect(views.last['keepAlive'], true);
      await nativeAction('closeRequested');
      expect(calls, contains('hide'));
      expect(calls, isNot(contains('exit')));
      final suspend = nativeAction('systemSuspend');
      await tester.pump();
      backend.pendingStart!.complete(
        benchmarkFixture(state: 'streaming', cleaning: true),
      );
      await start;
      await suspend;
      expect(benchmark.snapshot!.state, 'interrupted');
      for (final action in ['systemResume', 'refresh', 'resume', 'mainShown']) {
        await nativeAction(action);
      }
      expect(backend.sequence, 1);
      expect(service.calls, 0);
      bridge.dispose();
      usage.dispose();
      benchmark.dispose();
    },
  );
  testWidgets(
    'explicit exit waits owned bounded shutdown and coalesces repeated calls',
    (tester) async {
      final backend = BenchmarkBackend()..pendingShutdown = Completer();
      final benchmark = BenchmarkController(BenchmarkService(backend));
      await benchmark.initialize();
      await benchmark.start();
      final usage = AccountUsageController(DeniedUsage());
      final bridge = DesktopMonitor(
        usage,
        () => 'fixture',
        benchmark: benchmark,
      )..start();
      await tester.pump();
      final exit = nativeAction('exit');
      final second = nativeAction('exit');
      await tester.pump();
      expect(calls, isNot(contains('exit')));
      expect(
        backend.calls.where((c) => c == 'benchmark_shutdown'),
        hasLength(1),
      );
      backend.pendingShutdown!.complete({
        'accepting': false,
        'cleanupComplete': true,
        'runId': 'run-1',
      });
      await tester.pump();
      await Future.wait([exit, second]);
      expect(calls.where((c) => c == 'exit'), hasLength(1));
      bridge.dispose();
      usage.dispose();
      benchmark.dispose();
    },
  );
}
