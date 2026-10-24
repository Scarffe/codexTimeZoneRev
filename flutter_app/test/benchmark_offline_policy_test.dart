import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/monitoring_page.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:codex_timezone/state/launcher_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'benchmark_fixtures.dart';

import 'package:timezone/data/latest.dart' as timezone;

class DeniedUsage implements AccountUsageService {
  int calls = 0;
  @override
  Future<AccountUsage> query(String path) async {
    calls++;
    throw StateError('should never query');
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  test('network policy prevents startup/manual transport and preference cache access', () async {
    SharedPreferences.setMockInitialValues({'flutter-network-v1': 'preserve'});
    var transports = 0;
    final network = NetworkController(
      offlineTrial: true,
      transportFactory: () {
        transports++;
        throw StateError('PAC or network must never be reached');
      },
    );
    await network.initialize();
    await network.refresh();
    expect(transports, 0);
    expect(network.domestic, isNull);
    expect(network.cached, false);
    expect(
      (await SharedPreferences.getInstance()).getString('flutter-network-v1'),
      'preserve',
    );
    network.dispose();
  });
  test(
    'account controller blocks saved monitoring/manual/resume/wake at boundary',
    () async {
      final service = DeniedUsage();
      final usage = AccountUsageController(service, offlineTrial: true)
        ..savedMonitoring = true;
      usage.startMonitoring(() => 'fixture');
      await usage.query('fixture');
      usage.systemSuspending();
      usage.systemResumed();
      expect(service.calls, 0);
      expect(usage.attempts, 0);
      expect(usage.monitoring, false);
      expect(usage.savedMonitoring, true);
      usage.dispose();
    },
  );
  test('backend policy blocks real reads and target writes; catalog remains callable', () async {
    final native = BenchmarkBackend();
    final backend = OfflineTrialBackend(native);
    final bootstrap = await backend.call('bootstrap');
    expect(bootstrap['detected'], '');
    expect(native.calls, isEmpty);
    for (final command in [
      'account_usage',
      'session_metrics',
      'launch',
      'repair_launch',
      'save',
      'create_shortcut',
      'launch_dream_skin',
      'reapply_dream_skin',
      'validate',
    ]) {
      await expectLater(backend.call(command), throwsStateError);
    }
    await expectLater(
      NativeAccountUsageService(native, offlineTrial: true).query('fixture'),
      throwsStateError,
    );
    await backend.call('benchmark_catalog');
    expect(native.calls, ['benchmark_catalog']);
    final launcher = LauncherController(backend, offlineTrial: true);
    await launcher.initialize();
    expect(await launcher.action('launch'), false);
    expect(launcher.canSave, false);
    launcher.dispose();
  });
  testWidgets(
    'trial app skips appearance/real bootstrap/session/account restore and source switches never start',
    (tester) async {
      SharedPreferences.setMockInitialValues({'flutter-appearance': 'dark'});
      final native = BenchmarkBackend();
      final benchmark = BenchmarkController(BenchmarkService(native));
      await tester.pumpWidget(
        LauncherApplication(
          backend: native,
          offlineTrial: true,
          benchmarkController: benchmark,
          initialAppearance: 'light',
        ),
      );
      await tester.pumpAndSettle();
      final launcher = tester
          .widget<LauncherPage>(find.byType(LauncherPage))
          .launcher;
      expect(launcher.detected, '');
      expect(native.calls, ['benchmark_catalog']);
      final shell = tester.widget<WorkspaceShell>(find.byType(WorkspaceShell));
      expect(shell.appearance, 'light');
      shell.onAppearance('light');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      final page = tester.widget<MonitoringPage>(find.byType(MonitoringPage));
      await page.usage.query('fixture');
      page.usage.startMonitoring(() => 'fixture');
      page.usage.systemResumed();
      await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      expect(page.metrics.selected, isNull);
      expect(native.calls, ['benchmark_catalog']);
      expect(
        (await SharedPreferences.getInstance()).getString('flutter-appearance'),
        'dark',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
