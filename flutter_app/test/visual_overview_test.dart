import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/workspace_attention_fixture.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);

  Future<WorkspaceAttentionFixture> showOverview(
    WidgetTester tester,
    double width,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
    return fixture;
  }

  testWidgets('wide overview keeps four useful entries in one viewport', (
    tester,
  ) async {
    final fixture = await showOverview(tester, 1280);
    final account = tester.getRect(
      find.byKey(const ValueKey('overview-card-accounts')),
    );
    final attention = tester.getRect(
      find.byKey(const ValueKey('overview-card-sessions')),
    );
    final analysis = tester.getRect(
      find.byKey(const ValueKey('overview-card-analysis')),
    );
    final benchmark = tester.getRect(
      find.byKey(const ValueKey('overview-card-benchmark')),
    );
    expect(account.top, closeTo(attention.top, 1));
    expect(analysis.top, closeTo(benchmark.top, 1));
    expect(account.right, lessThan(attention.left));
    final viewport = tester.getRect(
      find.byKey(const PageStorageKey('overview-scroll')),
    );
    expect(benchmark.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(find.text('最近完成回合 · 平均吞吐'), findsOneWidget);
    expect(find.text('10.00'), findsOneWidget);

    final queries = fixture.sourceService.queries.length;
    final reads = fixture.backend.calls.length;
    final selected = fixture.metrics.selected;
    await tester.tap(find.byKey(const ValueKey('overview-accounts')));
    // Observe the navigation frame without advancing the fixture's periodic
    // read timers; their normal background polls are independent of this tap.
    await tester.pump();
    expect(
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).selected,
      WorkspaceDestination.accounts,
    );
    expect(fixture.sourceService.queries.length, queries);
    expect(fixture.backend.calls.length, reads);
    expect(fixture.metrics.selected, selected);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets(
    'narrow overview stacks complete entries and preserves API route',
    (tester) async {
      final fixture = await showOverview(tester, 600);
      final account = tester.getRect(
        find.byKey(const ValueKey('overview-card-accounts')),
      );
      final attention = tester.getRect(
        find.byKey(const ValueKey('overview-card-sessions')),
      );
      expect(account.left, attention.left);
      expect(account.bottom, lessThan(attention.top));
      final queries = fixture.sourceService.queries.length;
      final reads = fixture.backend.calls.length;
      final entry = find.byKey(const ValueKey('overview-benchmark'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pump();
      expect(
        tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).selected,
        WorkspaceDestination.benchmark,
      );
      expect(fixture.sourceService.queries.length, queries);
      expect(fixture.backend.calls.length, reads);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
    },
  );
}
