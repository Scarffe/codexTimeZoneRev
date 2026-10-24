import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageUsage;
import 'chart_overview_test.dart';
import 'monitor_charts_test.dart' show chartApp;
import 'support/compact_dashboard_fixture.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pure fixture denies all unknown commands and payloads', () async {
    final backend = CompactDashboardBackend();
    for (final (command, payload) in <(String, Map<String, dynamic>)>[
      ('launch', {}),
      ('bootstrap', {'extra': true}),
      ('session_metrics', {'path': 'real-session'}),
      (
        'session_metrics',
        {'action': 'list', 'path': compactDashboardSessionPath},
      ),
    ]) {
      await expectLater(backend.call(command, payload), throwsStateError);
    }
    await expectLater(
      CompactDashboardUsageService().query('real-path'),
      throwsStateError,
    );
    expect((await backend.call('bootstrap'))['detected'], '');
    expect(
      (await backend.call('session_metrics', {
        'path': compactDashboardSessionPath,
      }))['sourceInfo']['id'],
      startsWith('synthetic-'),
    );
  });

  testWidgets(
    'line breaks at null and cancelled values while preserving true zero',
    (tester) async {
      await tester.pumpWidget(
        chartApp(
          const MonitorBarChart(
            bars: [
              ChartBar(label: '零', value: 0),
              ChartBar(label: '一', value: 1),
              ChartBar(label: '未知', value: null),
              ChartBar(label: '三', value: 3),
              ChartBar(label: '取消', value: 9, cancelled: true),
              ChartBar(label: '五', value: 5),
            ],
            unit: 's',
            line: true,
          ),
        ),
      );
      final painter = tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('monitor-duration-line')),
          )
          .painter!;
      expect(
        (Canvas canvas) => painter.paint(canvas, const Size(600, 155)),
        paintsExactlyCountTimes(#drawLine, 1),
      );
      expect(
        find.byKey(const ValueKey('monitor-bar-0-primary')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('monitor-bar-2-primary')), findsNothing);
      expect(find.byKey(const ValueKey('monitor-bar-4-primary')), findsNothing);
      expect(
        find.byKey(const ValueKey('monitor-bar-4-cancelled')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.textContaining('零：0.00 s'), findsOneWidget);
      expect(find.textContaining('未知：未知'), findsOneWidget);
      expect(find.textContaining('取消：取消'), findsOneWidget);
    },
  );

  testWidgets('mark hover shows exact record and named stacked series', (
    tester,
  ) async {
    await tester.pumpWidget(
      chartApp(
        const MonitorBarChart(
          bars: [
            ChartBar(
              label: '响应精确值',
              value: 1.23456789,
              secondaryValue: 2.5,
              detail: '响应 synthetic-1',
            ),
          ],
          unit: 'tokens',
          stacked: true,
          primaryLabel: '非推理输出',
          secondaryLabel: '推理',
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('monitor-bar-0-secondary'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('monitor-chart-hover')), findsOneWidget);
    expect(find.textContaining('非推理输出：1.23 tokens'), findsOneWidget);
    expect(find.textContaining('推理：2.50 tokens'), findsOneWidget);
    expect(find.textContaining('响应 synthetic-1'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
  });

  testWidgets('unknown cancelled and updated marks never retain stale hover', (
    tester,
  ) async {
    final chart = ValueNotifier<Widget>(
      const MonitorBarChart(
        bars: [
          ChartBar(label: '缺失', value: null),
          ChartBar(label: '中断', value: 99, cancelled: true),
        ],
        unit: 's',
        horizontal: true,
      ),
    );
    addTearDown(chart.dispose);
    await tester.pumpWidget(
      chartApp(
        ValueListenableBuilder<Widget>(
          valueListenable: chart,
          builder: (_, value, _) => value,
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('monitor-bar-0-unknown'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('缺失：未知'), findsOneWidget);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('monitor-bar-1-cancelled'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('中断：取消'), findsOneWidget);
    expect(find.textContaining('99 s'), findsNothing);
    chart.value = const MonitorBarChart(
      bars: [ChartBar(label: '新值', value: 4)],
      unit: 's',
      horizontal: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('中断：取消'), findsNothing);
    chart.value = const Text('移除图表');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden source clears pointer popup without a data change', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      chartApp(
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, enabled, _) => TickerMode(
            enabled: enabled,
            child: const MonitorBarChart(
              bars: [ChartBar(label: '合成源', value: 4)],
              unit: 's',
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('monitor-bar-0-primary'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('monitor-chart-hover')), findsOneWidget);
    active.value = false;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real synthetic session polling keeps hover facts live without extra source reads',
    (tester) async {
      final backend = OverviewBackend();
      final usage = PageUsage();
      await tester.pumpWidget(overviewApplication(backend, usage));
      await tester.pumpAndSettle();
      await populateOverview(tester);
      await chooseOverview(tester, 'session-recent-presentation', 'bar');
      await chooseOverview(tester, 'session-recent-range', '8');
      final mark = find.descendant(
        of: find.byKey(const ValueKey('session-recent-chart')),
        matching: find.byKey(const ValueKey('monitor-bar-0-primary')),
      );
      await tester.ensureVisible(mark);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(mark));
      await tester.pump();
      final calls = backend.sessionCalls;
      final quotaCalls = usage.calls;
      for (var poll = 1; poll <= 3; poll++) {
        (backend.value['terminals'] as List)[7]['durationMs'] =
            6000 + poll * 1000;
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump();
        expect(backend.sessionCalls, calls + poll);
        expect(usage.calls, quotaCalls);
        expect(
          find.byKey(const ValueKey('monitor-chart-hover')),
          findsOneWidget,
        );
        expect(find.textContaining('1：${6 + poll}.00 s'), findsOneWidget);
        expect(find.textContaining('回合 terminal-7'), findsOneWidget);
      }
      backend.readFailure = 'synthetic read failure';
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump();
      expect(backend.sessionCalls, calls + 4);
      expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      final controller = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      backend.readFailure = null;
      controller.select(r'C:\synthetic-only\another-selected-session.jsonl');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('session-recent-presentation')),
            )
            .value,
        'bar',
      );
      expect(usage.calls, quotaCalls);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 350));
    },
  );

  testWidgets(
    'recent duration defaults line and retains bar choice without reads',
    (tester) async {
      final backend = OverviewBackend();
      final usage = PageUsage();
      await tester.pumpWidget(overviewApplication(backend, usage));
      await tester.pumpAndSettle();
      await populateOverview(tester);
      final calls = backend.sessionCalls;
      final choice = find.byKey(const ValueKey('session-recent-presentation'));
      expect(choice, findsOneWidget);
      expect(tester.widget<MonitorChoice>(choice).value, 'line');
      final mark = find.descendant(
        of: find.byKey(const ValueKey('session-recent-chart')),
        matching: find.byKey(const ValueKey('monitor-bar-1-primary')),
      );
      await tester.ensureVisible(mark);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(mark));
      await tester.pump();
      expect(find.byKey(const ValueKey('monitor-chart-hover')), findsOneWidget);
      expect(backend.sessionCalls, calls);
      await tester.pump(const Duration(milliseconds: 560));
      expect(find.byKey(const ValueKey('monitor-chart-hover')), findsOneWidget);
      expect(backend.sessionCalls, calls);
      await mouse.removePointer();
      await tester.pump();
      await chooseOverview(tester, 'session-recent-presentation', 'bar');
      await chooseOverview(tester, 'session-recent-metric', 'status');
      expect(graph(tester, 'session-recent-chart').unit, '回合');
      await chooseOverview(tester, 'session-recent-metric', 'duration');
      expect(tester.widget<MonitorChoice>(choice).value, 'bar');
      await overviewTap(tester, 'workspace-benchmark', settle: false);
      await overviewTap(tester, 'workspace-analysis', settle: false);
      expect(tester.widget<MonitorChoice>(choice).value, 'bar');
      await overviewTap(tester, 'workspace-launcher', settle: false);
      await overviewTap(tester, 'workspace-analysis', settle: false);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pump();
      final controller = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      controller.data = overviewFixture();
      controller.notifyListeners();
      await tester.pump();
      expect(tester.widget<MonitorChoice>(choice).value, 'bar');
      expect(backend.sessionCalls, calls);
      expect(usage.calls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 350));
    },
  );
}
