import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'monitor_lifecycle_test.dart' show LifecycleService, nativeAction;
import 'support/global_workbench_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  var visible = true;
  setUp(() {
    calls.clear();
    visible = true;
    messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'mainVisible') return visible;
      if (call.method == 'hide') visible = false;
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
  );

  testWidgets(
    'global cached running rows do not turn an ordinary close into hide',
    (tester) async {
      final backend = GlobalFixtureBackend();
      final global = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
      );
      await global.initialize();
      final usage = AccountUsageController(LifecycleService());
      final monitor = DesktopMonitor(usage, () => '', global: global)..start();
      await tester.pump();
      expect(global.snapshot!.totals.states['running'], 2);
      expect(global.keepAlive, isFalse);
      await nativeAction('closeRequested');
      expect(calls, contains('exit'));
      expect(calls, isNot(contains('hide')));
      expect(backend.calls.last['action'], 'shutdown');
      monitor.dispose();
      global.dispose();
      usage.dispose();
    },
  );

  testWidgets(
    'explicit global background monitoring hides and actual exit drains its owner',
    (tester) async {
      final backend = GlobalFixtureBackend();
      final global = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
      );
      await global.initialize();
      await global.setBackgroundObservation(true);
      final usage = AccountUsageController(LifecycleService());
      final monitor = DesktopMonitor(usage, () => '', global: global)..start();
      await tester.pump();
      await nativeAction('closeRequested');
      expect(calls, contains('hide'));
      expect(calls, isNot(contains('exit')));
      final queryCalls = backend.calls
          .where((v) => v['action'] == 'scan')
          .length;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(
        backend.calls.where((v) => v['action'] == 'scan').length,
        greaterThan(queryCalls),
      );
      await nativeAction('exit');
      expect(calls, contains('exit'));
      expect(global.keepAlive, isFalse);
      expect(backend.calls.last['action'], 'shutdown');
      monitor.dispose();
      global.dispose();
      usage.dispose();
    },
  );
}
