import 'package:codex_timezone/app/accounts_workspace_page.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/runtime_account_panel.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/runtime_account.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/launcher_controller.dart';
import 'package:codex_timezone/state/runtime_account_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'runtime_account_test.dart' show RecordingRuntimeBackend, snapshot;
import 'support/multi_account_fixture.dart';

class _NoLegacyUsage implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) => throw StateError('legacy query');
}

Widget runtimeHost(
  Widget child, {
  DashboardThemeStyle style = DashboardThemeStyle.soft,
  AppLanguage language = AppLanguage.zh,
  bool dark = false,
}) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (_, child) => AppCopyScope(
    language: language,
    child: DashboardStyleScope(
      style: style,
      child: FTheme(
        data: launcherTheme(dark, style: style, language: language),
        child: FToaster(
          child: FTooltipGroup(
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14),
              child: child!,
            ),
          ),
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) =>
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => child),
);

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'monitor selector never switches; explicit runtime action uses selected ID',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = await syntheticMultiFixture();
      final backend = RecordingRuntimeBackend();
      final runtime = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
      );
      await runtime.initialize();
      final usage = AccountUsageController(_NoLegacyUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        runtime.dispose();
        usage.dispose();
        launcher.dispose();
        f.owner.dispose();
        f.metrics.dispose();
      });
      await tester.pumpWidget(
        runtimeHost(
          AccountsWorkspacePage(
            usage: usage,
            launcher: launcher,
            runtime: runtime,
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<MonitorChoice>(
            find.byKey(const ValueKey('account-source-selector')),
          )
          .onChanged('profile-unknown');
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c['action'] == 'switch'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('runtime-use-source')));
      await tester.pumpAndSettle();
      expect(backend.calls.last, {
        'command': 'desktop_runtime',
        'action': 'switch',
        'sourceId': 'profile-unknown',
      });
      expect(f.metrics.selected, isNotNull);
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unlogged selected source does not expose a runnable switch action',
    (tester) async {
      final f = await syntheticMultiFixture();
      f.metrics.select(null);
      final source = f.owner.selected!;
      source.usage = null;
      source.loginState = 'idle';
      final runtime = RuntimeAccountController(
        SyntheticRuntimeAccountService(),
      );
      await runtime.connect();
      addTearDown(() {
        runtime.dispose();
        f.owner.dispose();
        f.metrics.dispose();
      });
      await tester.pumpWidget(
        runtimeHost(RuntimeAccountPanel(controller: runtime, sources: f.owner)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FButton>(find.byKey(const ValueKey('runtime-use-source')))
            .onPress,
        isNull,
      );
      expect(find.text('请先在账号来源完成官方登录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'retained account outside this catalog is not described as unattached',
    (tester) async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(phase: 'active', active: true);
      final runtime = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
      );
      addTearDown(runtime.dispose);
      await runtime.initialize();
      await tester.pumpWidget(
        runtimeHost(RuntimeAccountPanel(controller: runtime)),
      );
      await tester.pumpAndSettle();
      expect(find.text('运行账号仍保留 · 其他来源'), findsOneWidget);
      expect(find.text('尚未绑定监控来源'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline application substitutes a pure runtime and never touches injected native',
    (tester) async {
      final f = await syntheticMultiFixture();
      final backend = RecordingRuntimeBackend();
      final injected = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
      );
      addTearDown(injected.dispose);
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: f.backend,
          sourceController: f.owner,
          sessionMetricsController: f.metrics,
          runtimeController: injected,
          desktop: SyntheticMultiDesktop(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
      await tester.pumpAndSettle();
      final panel = tester.widget<RuntimeAccountPanel>(
        find.byType(RuntimeAccountPanel),
      );
      expect(panel.controller.service, isA<SyntheticRuntimeAccountService>());
      await tester.ensureVisible(find.byKey(const ValueKey('runtime-connect')));
      await tester.tap(find.byKey(const ValueKey('runtime-connect')));
      await tester.pumpAndSettle();
      expect(backend.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  for (final style in DashboardThemeStyle.values) {
    for (final language in AppLanguage.values) {
      for (final width in [360.0, 1100.0]) {
        testWidgets(
          'runtime ${style.name} ${language.name} $width keeps pending separate from retained alias',
          (tester) async {
            tester.view.physicalSize = Size(width, 1050);
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = 1.25;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final f = await syntheticMultiFixture();
            f.metrics.select(null);
            f.owner.states.first.alias =
                '研究来源 · Research account with a longer alias';
            final backend = RecordingRuntimeBackend()
              ..result = snapshot(
                phase: 'unresolved',
                sourceId: 'profile-primary',
                active: true,
                pending: true,
              );
            final runtime = RuntimeAccountController(
              NativeRuntimeAccountService(backend),
              maxPolls: 0,
            );
            await runtime.initialize();
            addTearDown(() {
              runtime.dispose();
              f.owner.dispose();
              f.metrics.dispose();
            });
            await tester.pumpWidget(
              runtimeHost(
                SingleChildScrollView(
                  child: RuntimeAccountPanel(
                    controller: runtime,
                    sources: f.owner,
                  ),
                ),
                style: style,
                language: language,
                dark: width == 360,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('runtime-account-panel')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('runtime-reconcile')),
              findsOneWidget,
            );
            expect(
              find.text(
                language == AppLanguage.en
                    ? 'In-flight requests may keep using the previous account.'
                    : '在途请求可能沿用原账号',
              ),
              findsOneWidget,
            );
            expect(find.textContaining('must-not-enter-ui'), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
