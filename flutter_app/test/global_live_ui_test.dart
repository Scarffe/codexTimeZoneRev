import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/global_live_panel.dart';
import 'package:codex_timezone/app/workspace_overview_page.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/global_live.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/global_live_controller.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'global_live_test.dart' show liveSnapshot, RecordingLiveBackend;
import 'runtime_account_ui_test.dart' show runtimeHost;
import 'support/multi_account_fixture.dart';
import 'support/global_workbench_fixture.dart';
import 'support/workspace_attention_fixture.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('unavailable feed shows unknown rather than zero pending work', (
    tester,
  ) async {
    final controller = GlobalLiveController(SyntheticGlobalLiveService());
    await controller.refresh();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      runtimeHost(GlobalLivePanel(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('未连接 · 全局待办未知'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'offline live entry goes to account page without reaching injected native',
    (tester) async {
      final fixture = await WorkspaceAttentionFixture.create();
      final backend = RecordingLiveBackend();
      final denied = GlobalLiveController(NativeGlobalLiveService(backend));
      addTearDown(denied.dispose);
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: fixture.backend,
          sourceController: fixture.sources,
          sessionMetricsController: fixture.metrics,
          attentionController: fixture.attention,
          benchmarkController: fixture.benchmark,
          globalLiveController: denied,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-overview')));
      await tester.pumpAndSettle();
      final panel = tester.widget<GlobalLivePanel>(
        find.byType(GlobalLivePanel),
      );
      expect(panel.controller.service, isA<SyntheticGlobalLiveService>());
      await tester.ensureVisible(
        find.byKey(const ValueKey('global-live-connect')),
      );
      await tester.tap(find.byKey(const ValueKey('global-live-connect')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).selected,
        WorkspaceDestination.accounts,
      );
      expect(backend.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'live thread opens matching indexed detail without changing log totals',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1500);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final f = await syntheticMultiFixture();
      f.metrics.select(null);
      final usage = AccountUsageController(
        NativeAccountUsageService(f.backend, offlineTrial: true),
        sources: f.owner,
      );
      final attention = SessionAttentionController(f.backend);
      final global = GlobalWorkbenchController(
        service: SyntheticGlobalWorkbenchService(
          snapshot: GlobalSnapshot.fromJson(
            globalSnapshotFixture(
              sessions: [globalSessionFixture(id: 'thread-a')],
            ),
          ),
        ),
      );
      final live = GlobalLiveController(
        SyntheticGlobalLiveService(
          snapshot: GlobalLiveSnapshot.fromJson(liveSnapshot()),
        ),
      );
      await global.initialize();
      await live.refresh();
      GlobalSessionRow? opened;
      final before = global.snapshot!.totals.tokens.totalTokens;
      await tester.pumpWidget(
        runtimeHost(
          WorkspaceOverviewPage(
            usage: usage,
            metrics: f.metrics,
            attention: attention,
            onSelect: (_) {},
            recentNotice: '',
            global: global,
            live: live,
            onOpenSession: (row) => opened = row,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('global-live-open-thread-a')));
      await tester.pumpAndSettle();
      expect(opened?.threadId, 'thread-a');
      expect(global.snapshot!.totals.tokens.totalTokens, before);
      await tester.pumpWidget(const SizedBox());
      await global.shutdown();
      global.dispose();
      live.dispose();
      usage.dispose();
      attention.dispose();
      f.owner.dispose();
      f.metrics.dispose();
    },
  );
  testWidgets('older pending work is visible ahead of newer completed chats', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final pending =
        (liveSnapshot()['items'] as List).first as Map<String, dynamic>;
    final controller = GlobalLiveController(
      SyntheticGlobalLiveService(
        snapshot: GlobalLiveSnapshot.fromJson({
          ...liveSnapshot(),
          'items': [
            pending,
            for (var n = 10; n < 16; n++)
              {
                ...pending,
                'threadId': 'completed-$n',
                'state': 'completed',
                'attention': 'none',
                'sequence': n,
              },
          ],
        }),
      ),
    );
    await controller.refresh();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      runtimeHost(
        SingleChildScrollView(
          child: GlobalLivePanel(controller: controller, onOpenThread: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('global-live-open-thread-a')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  for (final (style, language, width) in [
    (DashboardThemeStyle.soft, AppLanguage.zh, 360.0),
    (DashboardThemeStyle.tech, AppLanguage.en, 360.0),
    (DashboardThemeStyle.graphite, AppLanguage.en, 1100.0),
  ]) {
    testWidgets(
      'live ${style.name} ${language.name} $width shows observed states and thread navigation',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = GlobalLiveController(
          SyntheticGlobalLiveService(
            snapshot: GlobalLiveSnapshot.fromJson({
              ...liveSnapshot(),
              'dropped': 2,
            }),
          ),
        );
        await controller.refresh();
        addTearDown(controller.dispose);
        String? opened;
        await tester.pumpWidget(
          runtimeHost(
            SingleChildScrollView(
              child: GlobalLivePanel(
                controller: controller,
                onOpenThread: (id) => opened = id,
              ),
            ),
            style: style,
            language: language,
            dark: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('global-live-active')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('global-live-approval')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('global-live-input')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('global-live-failed')),
          findsOneWidget,
        );
        expect(
          find.text(
            language == AppLanguage.en
                ? 'Only recently observed events · earlier activity is unknown'
                : '仅最近已观察事件 · 接入前活动未知',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('global-live-dropped')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('global-live-open-thread-a')),
        );
        await tester.pumpAndSettle();
        expect(opened, 'thread-a');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
