import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/monitor_settings_dialog.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageUsage;
import 'workspace_navigation_test.dart' show WorkspaceBackend;

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('sidebar settings reuse account owner without starting reads', (
    tester,
  ) async {
    final backend = WorkspaceBackend();
    final service = PageUsage();
    await tester.pumpWidget(
      LauncherApplication(
        backend: backend,
        usageService: service,
        networkFactory: () => NetworkController(preview: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存并启动'), findsOneWidget);
    final account = tester.widget<AccountUsagePanel>(
      find.byType(AccountUsagePanel, skipOffstage: false),
    );
    final settings = find.byKey(const ValueKey('monitor-settings'));
    expect(settings, findsOneWidget);
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MonitorSettingsDialog>(find.byType(MonitorSettingsDialog))
          .controller,
      same(account.controller),
    );
    await tester.tap(find.byKey(const ValueKey('alerts-toggle')));
    await tester.pumpAndSettle();
    expect(account.controller.alertsEnabled, isFalse);
    expect(account.controller.monitoring, isFalse);
    expect(service.calls, 0);
    expect(backend.sessionCalls, 0);
    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('保存并启动'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('monitor-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-monitor-interval')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'account keeps quota and errors visible while token facts are disclosed',
    (tester) async {
      final service = PageUsage();
      await tester.pumpWidget(
        LauncherApplication(
          backend: WorkspaceBackend(),
          usageService: service,
          networkFactory: () => NetworkController(preview: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-account-usage')));
      await tester.pumpAndSettle();
      expect(find.text('已用 8%'), findsOneWidget);
      expect(find.text('1,234,567'), findsNothing);
      expect(find.byKey(const ValueKey('usage-time-basis')), findsNothing);
      final details = find.byKey(const ValueKey('account-details-toggle'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('1,234,567'), findsOneWidget);
      expect(find.text('12,345'), findsOneWidget);
      expect(find.byKey(const ValueKey('usage-time-basis')), findsOneWidget);
      final account = tester.widget<AccountUsagePanel>(
        find.byType(AccountUsagePanel),
      );
      account.controller.preferencesError = '设置保存失败';
      service.failure = '网络暂不可用';
      account.controller.startMonitoring(() => account.launcher.effectivePath);
      await tester.pumpAndSettle();
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('设置保存失败'), findsOneWidget);
      expect(find.text('网络暂不可用'), findsOneWidget);
      expect(find.textContaining('失败退避中'), findsOneWidget);
      expect(find.textContaining('上次成功结果'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    for (final width in [600.0, 760.0, 1280.0]) {
      testWidgets(
        'account and launcher fit $width dark=$dark with long identity and 125 percent text',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final service = PageUsage();
          service.response['account']['email'] =
              '${List.filled(20, 'longidentity').join()}@example.com';
          await tester.pumpWidget(
            LauncherApplication(
              backend: WorkspaceBackend(),
              usageService: service,
              initialAppearance: dark ? 'dark' : 'light',
              networkFactory: () => NetworkController(preview: true),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('保存并启动'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
          await tester.pumpAndSettle();
          final account = tester.widget<AccountUsagePanel>(
            find.byType(AccountUsagePanel),
          );
          await account.controller.query(account.launcher.effectivePath);
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('account-details-toggle')),
          );
          await tester.tap(
            find.byKey(const ValueKey('account-details-toggle')),
          );
          await tester.pumpAndSettle();
          expect(find.text('1,234,567'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    for (final width in [320.0, 599.0, 600.0, 760.0, 1280.0]) {
      testWidgets('rail fits $width dark=$dark at 125 percent text', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var selected = false;
        String appearance = 'system';
        await tester.pumpWidget(
          WidgetsApp(
            color: const Color(0xff000000),
            pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
            localizationsDelegates: FLocalizations.localizationsDelegates,
            supportedLocales: FLocalizations.supportedLocales,
            builder: (context, child) => FTheme(
              data: launcherTheme(dark),
              child: FTooltipGroup(
                child: DefaultTextStyle(
                  style: launcherTheme(dark).typography.body.md,
                  child: child!,
                ),
              ),
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 700),
                textScaler: const TextScaler.linear(1.25),
              ),
              child: StatefulBuilder(
                builder: (context, update) => WorkspaceShell(
                  monitorSelected: selected,
                  onSelect: (value) => update(() => selected = value),
                  appearance: appearance,
                  onAppearance: (value) => update(() => appearance = value),
                  launcher: const Text('launcher fixture'),
                  monitor: const Text('monitor fixture'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('workspace-rail'))).width,
          width < 600 ? 56 : 72,
        );
        final rail = tester.getRect(
          find.byKey(const ValueKey('workspace-rail')),
        );
        expect(rail.left, 0);
        expect(rail.top, 0);
        expect(rail.bottom, 700);
        await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
        await tester.pumpAndSettle();
        expect(selected, isTrue);
        expect(find.text('monitor fixture'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('workspace-theme')));
        await tester.pumpAndSettle();
        for (final label in ['跟随系统', '浅色', '深色']) {
          expect(find.text(label), findsOneWidget);
        }
        await tester.tap(find.text('深色'));
        await tester.pumpAndSettle();
        expect(appearance, 'dark');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
