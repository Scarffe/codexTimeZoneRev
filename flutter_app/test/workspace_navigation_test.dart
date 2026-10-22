import 'dart:async';

import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;
import 'account_usage_test.dart' show usageResponse;

class WorkspaceBackend extends PageBackend {
  static final longPath =
      r'C:\项目\' + List.filled(12, '很长的工程与会话目录').join(r'\') + r'\selected.jsonl';
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) {
    if (command == 'session_metrics') {
      return Future.value(
        payload['action'] == 'list'
            ? {
                'sessions': [
                  {
                    'id': 'selected',
                    'path': longPath,
                    'cwd': longPath,
                    'title': '选定的测试会话',
                    'modifiedMs': 1792600000000,
                  },
                ],
              }
            : {
                'current': {'status': 'running'},
                'sourceInfo': {
                  'id': 'selected',
                  'cwd': longPath,
                  'title': '选定的测试会话',
                },
              },
      );
    }
    return super.call(command, payload);
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> switchPage(WidgetTester tester, String page) async {
    await tester.tap(find.byKey(ValueKey('workspace-$page')));
    await tester.pumpAndSettle();
  }

  testWidgets('launcher opens first and monitoring owns quota and sessions', (
    tester,
  ) async {
    await tester.pumpWidget(const LauncherApplication(preview: true));
    await tester.pumpAndSettle();
    expect(find.text('保存并启动'), findsOneWidget);
    expect(find.byType(AccountUsagePanel), findsNothing);
    expect(find.byType(SessionMetricsPanel), findsNothing);
    await switchPage(tester, 'monitor');
    expect(find.byType(AccountUsagePanel), findsOneWidget);
    expect(find.byType(SessionMetricsPanel), findsOneWidget);
    expect(find.text('保存并启动'), findsNothing);
    expect(find.byKey(const ValueKey('recent-monitor-notice')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('monitor-settings')));
    await tester.tap(find.byKey(const ValueKey('monitor-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('alerts-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-alerts-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pet-roles')), findsNothing);
    expect(find.byKey(const ValueKey('reduced-motion')), findsNothing);
    expect(find.textContaining('桌宠'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ten page switches retain draft, query owner and scroll offsets',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final service = PageUsage()..pending = Completer<AccountUsage>();
      await tester.pumpWidget(
        LauncherApplication(
          backend: PageBackend(),
          usageService: service,
          networkFactory: () => NetworkController(preview: true),
        ),
      );
      await tester.pumpAndSettle();
      final launcher = tester
          .widget<LauncherPage>(find.byType(LauncherPage))
          .launcher;
      launcher.update(
        launcher.settings.copyWith(executable: r'C:\草稿\Codex.exe'),
      );
      await tester.pump();
      final pathField = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == r'C:\草稿\Codex.exe',
      );
      final pathEditor = tester.widget<EditableText>(pathField);
      final pathController = pathEditor.controller;
      pathController.selection = const TextSelection.collapsed(offset: 4);
      final launcherScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('launcher-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      launcherScroll.position.jumpTo(130);
      await switchPage(tester, 'monitor');
      final account = tester
          .widget<AccountUsagePanel>(find.byType(AccountUsagePanel))
          .controller;
      final sessions = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      final query = account.query(launcher.effectivePath);
      await tester.pump();
      final monitorScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('monitor-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      monitorScroll.position.jumpTo(50);
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.byKey(const ValueKey('workspace-launcher')));
        await tester.pump();
        expect(
          tester.widget<LauncherPage>(find.byType(LauncherPage)).launcher,
          same(launcher),
        );
        expect(launcher.settings.executable, r'C:\草稿\Codex.exe');
        expect(
          tester.widget<EditableText>(pathField).controller,
          same(pathController),
        );
        expect(pathController.selection.baseOffset, 4);
        expect(launcherScroll.position.pixels, 130);
        await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
        await tester.pump();
        expect(
          tester
              .widget<AccountUsagePanel>(find.byType(AccountUsagePanel))
              .controller,
          same(account),
        );
        expect(
          tester
              .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
              .controller,
          same(sessions),
        );
        expect(monitorScroll.position.pixels, 50);
      }
      expect(account.busy, true);
      expect(service.calls, 1);
      expect(account.attempts, 1);
      service.pending!.complete(AccountUsage.fromJson(usageResponse()));
      await query;
      await tester.pumpAndSettle();
      expect(find.text('已用 8%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('monitor overview follows session selection without navigation', (
    tester,
  ) async {
    await tester.pumpWidget(
      LauncherApplication(
        backend: PageBackend(),
        usageService: PageUsage(),
        networkFactory: () => NetworkController(preview: true),
      ),
    );
    await tester.pumpAndSettle();
    await switchPage(tester, 'monitor');
    final metrics = tester
        .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
        .controller;
    expect(find.text('本地会话：未选择会话'), findsOneWidget);
    metrics.select(r'C:\fixture\selected.jsonl');
    await tester.pumpAndSettle();
    expect(find.text('本地会话：状态未知'), findsOneWidget);
    metrics.select(null);
    await tester.pumpAndSettle();
    expect(find.text('本地会话：未选择会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native detail actions select monitor and locate sessions without new quota requests',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
      Future<void> nativeAction(String method) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          DesktopMonitor.channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (_) => done.complete(),
        );
        await done.future;
      }

      final service = PageUsage();
      await tester.pumpWidget(
        LauncherApplication(
          backend: PageBackend(),
          monitorEnabled: true,
          usageService: service,
          networkFactory: () => NetworkController(preview: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保存并启动'), findsOneWidget);
      await nativeAction('monitorDetails');
      await tester.pumpAndSettle();
      expect(find.byType(AccountUsagePanel), findsOneWidget);
      await switchPage(tester, 'launcher');
      await nativeAction('sessionDetails');
      await tester.pumpAndSettle();
      expect(find.byType(SessionMetricsPanel), findsOneWidget);
      final title = tester.getRect(find.text('会话回合统计'));
      expect(title.top, greaterThan(0));
      expect(title.bottom, lessThan(600));
      await tester.pump(const Duration(seconds: 1));
      expect(snapshots.last['workspace'], 'monitor');
      expect(service.calls, 0);
      await switchPage(tester, 'launcher');
      final usage = tester
          .widget<AccountUsagePanel>(
            find.byType(AccountUsagePanel, skipOffstage: false),
          )
          .controller;
      final primary =
          service.response['limits']['rateLimitsByLimitId']['codex']['primary']
              as Map;
      primary['usedPercent'] = 95;
      primary['resetsAt'] =
          DateTime.now().add(const Duration(hours: 5)).millisecondsSinceEpoch ~/
          1000;
      await usage.query(r'C:\fixture\Codex.exe');
      await tester.pumpAndSettle();
      expect(find.text('保存并启动'), findsOneWidget);
      await switchPage(tester, 'monitor');
      expect(find.textContaining('最近提醒：Codex 5 小时额度剩余 5%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final appearance in ['light', 'dark']) {
    for (final width in [600.0, 760.0, 1280.0]) {
      testWidgets('$appearance monitoring and launcher fit $width', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final service = PageUsage();
        await tester.pumpWidget(
          LauncherApplication(
            backend: WorkspaceBackend(),
            usageService: service,
            networkFactory: () => NetworkController(preview: true),
            initialAppearance: appearance,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await switchPage(tester, 'monitor');
        final account = tester.widget<AccountUsagePanel>(
          find.byType(AccountUsagePanel),
        );
        final sessions = tester.widget<SessionMetricsPanel>(
          find.byType(SessionMetricsPanel),
        );
        await account.controller.query(account.launcher.effectivePath);
        await sessions.controller.list();
        sessions.controller.select(WorkspaceBackend.longPath);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('session-selector')), findsOneWidget);
        await tester.ensureVisible(find.text('会话回合统计'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await switchPage(tester, 'launcher');
        expect(find.text('保存并启动'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
