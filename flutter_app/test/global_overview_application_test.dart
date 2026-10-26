import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/workspace_attention_fixture.dart';
import 'support/global_workbench_fixture.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);

  testWidgets(
    'aggregate conflict evidence remains visible even with ready phase',
    (tester) async {
      final fixture = await WorkspaceAttentionFixture.create();
      final data = globalSnapshotFixture();
      data['phase'] = 'ready';
      (data['totals'] as Map)['quality'] = 'partial';
      (data['totals'] as Map)['excludedConflicts'] = 1;
      data['coverage'] = {'discovered': 1, 'indexed': 1};
      data['warnings'] = <String>[];
      final global = GlobalWorkbenchController(
        service: SyntheticGlobalWorkbenchService(
          snapshot: GlobalSnapshot.fromJson(data),
        ),
      );
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: fixture.backend,
          sourceController: fixture.sources,
          sessionMetricsController: fixture.metrics,
          attentionController: fixture.attention,
          benchmarkController: fixture.benchmark,
          globalController: global,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-overview')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('global-quality-warning')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('overview exposes the global workbench inside six workspaces', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = await WorkspaceAttentionFixture.create();
    await tester.pumpWidget(
      LauncherApplication(
        offlineTrial: true,
        initialAppearance: 'light',
        backend: fixture.backend,
        sourceController: fixture.sources,
        sessionMetricsController: fixture.metrics,
        attentionController: fixture.attention,
        benchmarkController: fixture.benchmark,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('global-workbench')), findsOneWidget);
    expect(find.byKey(const ValueKey('global-daily-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('global-project-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('global-model-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('global-session-list')), findsOneWidget);
    expect(WorkspaceDestination.values, hasLength(6));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });
}
