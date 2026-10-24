import 'dart:async';

import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multi_account_fixture.dart';
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
    'tray refresh uses pinned source independently of selected quota',
    (tester) async {
      final service = SyntheticMultiSources();
      final owner = AccountSourcesController(
        service,
        AccountSourceStore.memory(),
      );
      await owner.initialize(() => '');
      final id = (await owner.create('Other'))!;
      owner.select(id);
      final usage = AccountUsageController(_Usage(), sources: owner);
      final bridge = DesktopMonitor(usage, () => '')..start();
      await tester.pump();
      await nativeAction('refresh');
      expect(service.queries, ['current']);
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
