import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/app/monitoring_page.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/workspace_attention_fixture.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);
  testWidgets(
    'notice language redraw preserves raw title and delivery serial',
    (tester) async {
      final snapshots = <Map<Object?, Object?>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
        if (call.method == 'mainVisible') return true;
        if (call.method == 'publish') {
          snapshots.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
      );
      final fixture = await WorkspaceAttentionFixture.create();
      fixture.sources.alertsEnabled = true;
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          monitorEnabled: true,
          backend: fixture.backend,
          sourceController: fixture.sources,
          sessionMetricsController: fixture.metrics,
          attentionController: fixture.attention,
          benchmarkController: fixture.benchmark,
        ),
      );
      await tester.pump();
      await tester.pump();
      tester
          .widget<MonitoringPage>(
            find.byType(MonitoringPage, skipOffstage: false),
          )
          .usage
          .configureSessionAlerts(enabled: true);
      await fixture.attention.poll();
      final shell = tester.widget<WorkspaceShell>(find.byType(WorkspaceShell));
      shell.onLanguage!(AppLanguage.en);
      await tester.pump();
      await tester.pump();
      await fixture.completeA();
      await tester.pump();
      final serial = fixture.attention.alertSerial;
      expect(serial, 1);
      expect(
        snapshots.last['attentionAlert'],
        '${fixture.attention.notices.last.title} · Turn completed',
      );
      final calls = List.of(fixture.backend.calls);
      shell.onLanguage!(AppLanguage.zh);
      await tester.pump();
      await tester.pump();
      expect(fixture.attention.alertSerial, serial);
      expect(snapshots.last['attentionAlertSerial'], serial);
      expect(snapshots.last['attentionAlert'], fixture.attention.alert);
      expect(fixture.backend.calls, calls);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
