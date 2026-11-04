import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/services/desktop_services.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;
import 'session_compact_workspace_test.dart' show compactFixture;

/// All sources are in-memory fixtures. Never instantiate a native backend.
class SidebarRenderBackend extends PageBackend {
  static final project = r'C:\合成项目\' + List.filled(10, '很长的工程目录').join(r'\');
  static final path = '$project\\sessions\\sidebar-fixture.jsonl';
  int sessionCalls = 0;

  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command != 'session_metrics') return super.call(command, payload);
    sessionCalls++;
    final info = <String, dynamic>{
      'id': 'sidebar-synthetic-session',
      'path': path,
      'cwd': project,
      'title': List.filled(7, '合成会话长名称').join(),
      'modifiedMs': 1792684800000,
    };
    if (payload['action'] == 'list') {
      return {
        'sessions': [info],
      };
    }
    final value = compactFixture()..['sourceInfo'] = info;
    final originalLast = value['last'] as Map<String, dynamic>;
    final originalAnalysis = originalLast['analysis'] as Map<String, dynamic>;
    final originalTimeline =
        originalAnalysis['timeline'] as Map<String, dynamic>;
    value['last'] = <String, dynamic>{
      ...originalLast,
      'outputTokens': 100,
      'durationMs': 10000,
      'firstTokenMs': 1000,
      'analysis': <String, dynamic>{
        ...originalAnalysis,
        // Four distinct intervals: union=7500, category sum=12500.
        // Actual turn and conservative logged window both span 10 s.
        'timeline': <String, dynamic>{
          ...originalTimeline,
          'items': <Map<String, dynamic>>[
            for (final (ordinal, category, start, end) in [
              (1, 'reasoning', 1000, 4000),
              (2, 'tool', 2000, 6000),
              (3, 'message', 3000, 8000),
              (4, 'other', 8500, 9000),
            ])
              {
                'ordinal': ordinal,
                'category': category,
                'startedAtMs': 100000 + start,
                'completedAtMs': 100000 + end,
                'offsetStartMs': start,
                'offsetEndMs': end,
                'durationMs': end - start,
                'drawable': true,
                'reasons': <String>[],
              },
          ],
        },
        'observedMs': 7500,
        'overlapMs': 5000,
        'unclassifiedMs': 2500,
        'messageMs': 5000,
        'reasoningMs': 3000,
        'toolMs': 4000,
        'otherMs': 500,
        'responseCount': 1,
        'responseOutputTokens': 100,
        'usageMatchesTurn': true,
        'recentResponses': <Map<String, dynamic>>[
          {
            'responseId': 'synthetic-response',
            'outputTokens': 100,
            'reasoningTokens': 5,
          },
        ],
      },
    };
    value['measurement'] = <String, dynamic>{
      ...value['measurement'] as Map<String, dynamic>,
      'sessionId': info['id'],
    };
    value['verifiedGroups'] = <Map<String, dynamic>>[
      {
        ...(value['verifiedGroups'] as List).single as Map<String, dynamic>,
        'sessionId': info['id'],
        'turnCount': 1,
        'outputTokens': 100,
        'durationMs': 10000,
        'tokensPerSecond': 10.0,
      },
    ];
    return value;
  }
}

class NoRenderDesktop implements DesktopServices {
  @override
  Future<String?> chooseClient(String platform) =>
      throw StateError('Native file picker is outside render acceptance');
  @override
  Future<void> copyVerified(String text) =>
      throw StateError('Native clipboard is outside render acceptance');
}

void main() {
  final captureDirectory = Platform.environment['SIDEBAR_RENDER_DIR'];
  setUpAll(() async {
    timezone.initializeTimeZones();
    for (final (family, filename) in [
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
      ('Segoe UI', 'segoeui.ttf'),
      ('Microsoft YaHei UI', 'msyh.ttc'),
    ]) {
      final font = File('C:/Windows/Fonts/$filename');
      await (FontLoader(family)..addFont(
            font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
    for (final (family, asset) in [
      ('packages/forui/Inter', 'packages/forui/assets/fonts/inter/Inter.ttf'),
      (
        'packages/forui_lucide/ForuiLucideIcons',
        'packages/forui_lucide/assets/lucide.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final cjk = File(r'C:\Windows\Fonts\msyh.ttc');
    expect(cjk.existsSync(), isTrue, reason: 'CJK render evidence needs YaHei');
    await (FontLoader('Microsoft YaHei')..addFont(
          cjk.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        ))
        .load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('candidate metadata and local guide ship reviewable provenance', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      matches(RegExp(r'version: \d+\.\d+\.\d+-rc\.\d+\+\d+')),
    );
    expect(
      File('../docs/monitoring.md').readAsStringSync(),
      contains('回合平均吞吐'),
    );
  });

  Future<void> capture(
    WidgetTester tester,
    GlobalKey boundaryKey,
    String name,
  ) async {
    if (captureDirectory == null) return;
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(captureDirectory);
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> tapAction(WidgetTester tester, String key) async {
    final action = find.byKey(ValueKey(key));
    await tester.ensureVisible(action);
    expect(action.hitTestable(), findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final appearance in ['light', 'dark']) {
    for (final width in [320.0, 600.0, 760.0, 1024.0, 1280.0]) {
      testWidgets(
        '$appearance full application $width at 125% text keeps actions usable',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final backend = SidebarRenderBackend();
          final service = PageUsage();
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: LauncherApplication(
                backend: backend,
                usageService: service,
                desktop: NoRenderDesktop(),
                networkFactory: () => NetworkController(preview: true),
                initialAppearance: appearance,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('保存并启动'), findsOneWidget);
          expect(find.byType(AccountUsagePanel), findsNothing);
          expect(find.byType(SessionMetricsPanel), findsNothing);
          expect(tester.takeException(), isNull);
          final launcher = tester.widget<LauncherPage>(
            find.byType(LauncherPage),
          );
          expect(
            MediaQuery.textScalerOf(tester.element(find.byType(LauncherPage)))
                .scale(16),
            20,
          );
          if (width >= 320) {
            await capture(
              tester,
              boundaryKey,
              '$appearance-${width.toInt()}-launcher',
            );
          }
          await tapAction(tester, 'workspace-analysis');
          expect(
            tester.getSize(find.byKey(const ValueKey('workspace-rail'))).width,
            width >= 1100 ? 192 : (width <= 620 ? 45 : 56),
          );
          final account = tester.widget<AccountUsagePanel>(
            find.byType(AccountUsagePanel, skipOffstage: false),
          );
          final metrics = tester
              .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
              .controller;
          await tapAction(tester, 'workspace-accounts');
          await tapAction(tester, 'query-account-usage');
          await tapAction(tester, 'workspace-analysis');
          expect(service.calls, 1);
          await tapAction(tester, 'session-refresh');
          expect(backend.sessionCalls, 1);
          metrics.select(SidebarRenderBackend.path);
          await tester.pumpAndSettle();
          expect(metrics.selected, SidebarRenderBackend.path);
          expect(metrics.error, isNull, reason: 'Synthetic backend must poll');
          expect(metrics.data, isNotNull);
          expect(find.text('10.00 tokens/s'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('session-timeline-chart')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('session-timeline-list')),
            findsNothing,
          );
          expect(find.textContaining(SidebarRenderBackend.path), findsNothing);
          expect(tester.takeException(), isNull);
          final scroll = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('analysis-page')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          scroll.position.jumpTo(0);
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundaryKey,
            '$appearance-${width.toInt()}-monitor',
          );
          await Scrollable.ensureVisible(
            tester.element(find.text('最近完成 · 含工具与等待')),
            alignment: 0,
          );
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundaryKey,
            '$appearance-${width.toInt()}-session',
          );
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const ValueKey('session-timeline-chart')),
            ),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundaryKey,
            '$appearance-${width.toInt()}-timeline',
          );
          await tapAction(tester, 'session-information');
          expect(find.text('日志：${SidebarRenderBackend.path}'), findsOneWidget);
          expect(find.textContaining('记录开始：'), findsNWidgets(4));
          await tapAction(tester, 'monitor-information-close');
          await tapAction(tester, 'monitor-settings');
          expect(find.byKey(const ValueKey('alerts-toggle')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('session-alerts-toggle')),
            findsOneWidget,
          );
          // Dismiss only the widget dialog, without a native desktop action.
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          // Escape is not a platform close command; use its dismissible barrier.
          if (find
              .byKey(const ValueKey('alerts-toggle'))
              .evaluate()
              .isNotEmpty) {
            await tester.tapAt(const Offset(5, 5));
            await tester.pumpAndSettle();
          }
          await tapAction(tester, 'workspace-theme');
          expect(find.text('跟随系统'), findsOneWidget);
          expect(find.text('浅色'), findsOneWidget);
          expect(find.text('深色'), findsOneWidget);
          await tester.tap(find.text(appearance == 'light' ? '深色' : '浅色'));
          await tester.pumpAndSettle();
          await tapAction(tester, 'workspace-benchmark');
          expect(find.textContaining('当前预览未启用'), findsOneWidget);
          await tapAction(tester, 'workspace-analysis');
          expect(metrics.selected, SidebarRenderBackend.path);
          expect(
            account.controller,
            same(
              tester
                  .widget<AccountUsagePanel>(
                    find.byType(AccountUsagePanel, skipOffstage: false),
                  )
                  .controller,
            ),
          );
          await tapAction(tester, 'workspace-launcher');
          expect(
            tester.widget<LauncherPage>(find.byType(LauncherPage)).launcher,
            same(launcher.launcher),
          );
          await tapAction(tester, 'workspace-analysis');
          expect(
            service.calls,
            1,
            reason: 'Navigation must not add quota reads',
          );
          await tester.ensureVisible(find.text('停止会话采集'));
          await tester.tap(find.text('停止会话采集'));
          await tester.pumpAndSettle();
          expect(metrics.selected, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
