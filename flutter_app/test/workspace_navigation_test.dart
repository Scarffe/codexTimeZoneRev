import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/quota_history_panel.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;
import 'account_usage_test.dart' show usageResponse;
import 'session_measurement_quality_test.dart' show qualityFixture;

class WorkspaceBackend extends PageBackend {
  int sessionCalls = 0;
  static final longPath =
      r'C:\项目\' + List.filled(12, '很长的工程与会话目录').join(r'\') + r'\selected.jsonl';
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) {
    if (command == 'session_metrics') {
      sessionCalls++;
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
                ...qualityFixture(),
                'measurement': {
                  ...qualityFixture()['measurement'] as Map<String, dynamic>,
                  'sourceLabel':
                      '所选 Codex 会话 · 本地只读日志 · ${List.filled(12, '用于核对统计来源的长项目说明').join(' · ')}',
                },
                'quality': {
                  'status': 'incomplete',
                  'reasons': [
                    'missing_request_evidence',
                    'missing_identity',
                    'incomplete_history',
                    'future_reason',
                  ],
                },
                'last': {
                  ...qualityFixture()['last'] as Map<String, dynamic>,
                  'quality': {
                    'status': 'incomplete',
                    'reasons': ['missing_request_evidence'],
                  },
                },
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
  setUpAll(() async {
    timezone.initializeTimeZones();
    for (final (family, filename) in [
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
      ('Segoe UI', 'segoeui.ttf'),
    ]) {
      final font = File('C:/Windows/Fonts/$filename');
      if (await font.exists()) {
        await (FontLoader(family)..addFont(
              font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            ))
            .load();
      }
    }
    // Readable offline render evidence on Windows; no font download or install.
    final cjkFont = File('C:/Windows/Fonts/msyh.ttc');
    if (await cjkFont.exists()) {
      await (FontLoader('Microsoft YaHei')..addFont(
            cjkFont.readAsBytes().then((value) => ByteData.sublistView(value)),
          ))
          .load();
      await (FontLoader('packages/forui/Inter')..addFont(
            rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
          ))
          .load();
    }
  });
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
    expect(find.text('保存并启动 Codex'), findsOneWidget);
    expect(find.byType(AccountUsagePanel), findsNothing);
    expect(find.byType(SessionMetricsPanel), findsNothing);
    await switchPage(tester, 'analysis');
    expect(find.byType(AccountUsagePanel, skipOffstage: false), findsOneWidget);
    expect(find.byType(SessionMetricsPanel), findsOneWidget);
    expect(find.text('保存并启动 Codex'), findsNothing);
    await switchPage(tester, 'overview');
    expect(find.byKey(const ValueKey('recent-monitor-notice')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('monitor-settings')));
    await tester.tap(find.byKey(const ValueKey('monitor-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('alerts-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-alerts-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pet-roles')), findsNothing);
    expect(find.byKey(const ValueKey('reduced-motion')), findsOneWidget);
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
      await switchPage(tester, 'analysis');
      final account = tester
          .widget<AccountUsagePanel>(
            find.byType(AccountUsagePanel, skipOffstage: false),
          )
          .controller;
      final sessions = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      final query = account.query(launcher.effectivePath);
      await tester.pump();
      final monitorScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('analysis-page')),
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
        await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
        await tester.pump();
        expect(
          tester
              .widget<AccountUsagePanel>(
                find.byType(AccountUsagePanel, skipOffstage: false),
              )
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
      final quota = tester.widget<MonitorRingChart>(
        find.descendant(
          of: find.byKey(const ValueKey('account-quota-chart')),
          matching: find.byType(MonitorRingChart),
        ),
      );
      expect(quota.bars.first.value, 92);
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
    await switchPage(tester, 'analysis');
    final metrics = tester
        .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
        .controller;
    expect(find.text('会话状态：未选择会话'), findsOneWidget);
    metrics.select(r'C:\fixture\selected.jsonl');
    await tester.pumpAndSettle();
    expect(find.text('会话状态：状态未知'), findsOneWidget);
    metrics.select(null);
    await tester.pumpAndSettle();
    expect(find.text('会话状态：未选择会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ten measurement entry switches retain session selection scroll and requests',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
      await switchPage(tester, 'analysis');
      final panel = tester.widget<SessionMetricsPanel>(
        find.byType(SessionMetricsPanel),
      );
      final metrics = panel.controller;
      metrics.select(WorkspaceBackend.longPath);
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const PageStorageKey('analysis-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(100);
      await tester.pump();
      final calls = backend.sessionCalls;
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
        await tester.pump();
        expect(find.byType(SessionMetricsPanel), findsNothing);
        expect(find.textContaining('当前预览未启用'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const PageStorageKey('independent-api-scroll')),
            matching: find.byType(EditableText),
          ),
          findsNothing,
        );
        expect(find.textContaining('开始测速'), findsNothing);
        expect(metrics.selected, WorkspaceBackend.longPath);
        expect(scroll.position.pixels, 100);
        final hiddenPanel = find.byType(
          SessionMetricsPanel,
          skipOffstage: false,
        );
        expect(TickerMode.valuesOf(tester.element(hiddenPanel)).enabled, false);
        await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
        await tester.pump();
        expect(
          tester
              .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
              .controller,
          same(metrics),
        );
        expect(
          TickerMode.valuesOf(tester.element(find.byType(SessionMetricsPanel)))
              .enabled,
          true,
        );
        expect(scroll.position.pixels, 100);
      }
      expect(backend.sessionCalls, calls);
      expect(service.calls, 0);
      expect(metrics.alertSerial, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // Forui's pointer highlight timers outlive zero-time simulated taps.
      // Dispose the real session owner first, then drain only those UI timers.
      await tester.pump(const Duration(milliseconds: 200));
    },
  );

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
      expect(find.text('保存并启动 Codex'), findsOneWidget);
      await nativeAction('monitorDetails');
      await tester.pumpAndSettle();
      expect(
        find.byType(AccountUsagePanel, skipOffstage: false),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('accounts-history')),
      );
      await tester.tap(find.byKey(const ValueKey('accounts-history')));
      await tester.pumpAndSettle();
      expect(find.byType(QuotaHistoryPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前预览未启用'), findsOneWidget);
      await switchPage(tester, 'launcher');
      await nativeAction('sessionDetails');
      await tester.pumpAndSettle();
      expect(find.byType(SessionMetricsPanel), findsOneWidget);
      final title = tester.getRect(find.text('会话回合统计'));
      expect(title.top, greaterThan(0));
      expect(title.bottom, lessThan(600));
      await tester.pump(const Duration(seconds: 1));
      expect(snapshots.last['workspace'], 'analysis');
      expect(service.calls, 0);
      await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
      await tester.pumpAndSettle();
      await switchPage(tester, 'launcher');
      await nativeAction('monitorDetails');
      await tester.pumpAndSettle();
      expect(
        find.byType(AccountUsagePanel, skipOffstage: false),
        findsOneWidget,
      );
      final accountRect = tester.getRect(
        find.byKey(const ValueKey('account-usage-card')),
      );
      expect(accountRect.top, greaterThan(0));
      expect(accountRect.top, lessThan(300));
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
      expect(find.text('保存并启动 Codex'), findsOneWidget);
      await switchPage(tester, 'analysis');
      await switchPage(tester, 'overview');
      await tester.ensureVisible(
        find.byKey(const ValueKey('recent-monitor-notice')),
      );
      await tester.tap(find.byKey(const ValueKey('recent-monitor-notice')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Codex 5 小时额度剩余 5%'), findsOneWidget);
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
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: LauncherApplication(
              backend: WorkspaceBackend(),
              usageService: service,
              networkFactory: () => NetworkController(preview: true),
              initialAppearance: appearance,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await switchPage(tester, 'analysis');
        final account = tester.widget<AccountUsagePanel>(
          find.byType(AccountUsagePanel, skipOffstage: false),
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
        await tester.ensureVisible(
          find.byKey(const ValueKey('session-information')),
        );
        await tester.tap(find.byKey(const ValueKey('session-information')));
        await tester.pumpAndSettle();
        expect(find.textContaining('用于核对统计来源的长项目说明'), findsOneWidget);
        expect(find.textContaining('核验信息不完整，暂无法核验'), findsOneWidget);
        expect(find.textContaining('future_reason'), findsNothing);
        expect(tester.takeException(), isNull);
        final captureDirectory =
            Platform.environment['CHART_OVERVIEW_LEGACY_RENDER_DIR'];
        if (captureDirectory != null) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(captureDirectory).create(recursive: true);
            await File(
              '$captureDirectory/workspace-$appearance-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(
          find.byKey(const ValueKey('monitor-information-close')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
        await tester.pumpAndSettle();
        expect(find.textContaining('当前预览未启用'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await switchPage(tester, 'launcher');
        expect(find.text('保存并启动 Codex'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
