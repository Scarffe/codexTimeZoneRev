import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/services/session_activity_timeline.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'monitor_charts_test.dart' show chartApp;
import 'session_activity_fixture.dart';

void main() {
  final shortCharts = <String, Widget>{
    'ring': const MonitorRingChart(
      bars: [ChartBar(label: '额度', value: 75, detail: '本地重置时间')],
    ),
    'category dots': const MonitorCategoryDotChart(
      bars: [
        ChartBar(label: '模型 · high · priority', value: 12, detail: '3 回合'),
      ],
      unit: 'tokens/s',
    ),
    'recent turn line': const MonitorBarChart(
      bars: [ChartBar(label: '1', value: 1.25, detail: '回合 turn-1 · 完成')],
      unit: 's',
      line: true,
    ),
    'response composition': const MonitorBarChart(
      bars: [
        ChartBar(label: '1', value: 10, secondaryValue: 5, detail: '响应 r1'),
      ],
      unit: 'tokens',
      stacked: true,
    ),
    'status counts': const MonitorBarChart(
      bars: [
        ChartBar(label: '完成', value: 3),
        ChartBar(label: '取消', value: 2),
      ],
      unit: '回合',
      horizontal: true,
    ),
    'zero status count': const MonitorBarChart(
      bars: [ChartBar(label: '取消', value: 0)],
      unit: '回合',
      horizontal: true,
    ),
    'unknown marker with complete hover': const MonitorBarChart(
      bars: [ChartBar(label: '1', value: null, detail: '响应 unknown-response')],
      unit: 'tokens',
    ),
    'activity durations': const MonitorBarChart(
      bars: [
        ChartBar(label: '消息', value: 3),
        ChartBar(label: '推理', value: 2),
      ],
      unit: 's',
      horizontal: true,
    ),
    'compact meters': const MonitorBarChart(
      bars: [ChartBar(label: '额度', value: 2.5, detail: '本地重置时间')],
      unit: '小时',
      horizontal: true,
      compactMeters: true,
    ),
    'coverage': const MonitorCoverageChart(
      observedMs: 7123,
      unclassifiedMs: 2877,
    ),
    'drawable activity intervals': MonitorIntervalChart(
      data: SessionActivityTimelineData.fromAnalysis({
        'timeline': timelineFixture(count: 1),
      }),
    ),
  };

  for (final entry in shortCharts.entries) {
    testWidgets(
      '${entry.key} omits inspection that repeats visible or hover facts',
      (tester) async {
        await tester.pumpWidget(chartApp(entry.value));
        expect(find.text('查看数值'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('zero size bars retain details that have no hover target', (
    tester,
  ) async {
    await tester.pumpWidget(
      chartApp(
        const MonitorBarChart(
          bars: [ChartBar(label: '1', value: 0, detail: '响应 zero-response')],
          unit: 'tokens',
          horizontal: true,
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('monitor-bar-0-primary'))).width,
      0,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('响应 zero-response'), findsOneWidget);
  });

  testWidgets('long hover uses the same overflow decision as full inspection', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final detail = List.filled(30, '完整模型与响应元数据').join('\n');
    await tester.pumpWidget(
      chartApp(
        MonitorBarChart(
          bars: [ChartBar(label: '1', value: 2, detail: detail)],
          unit: 's',
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('monitor-bar-0-primary'))),
    );
    await tester.pump();
    expect(find.text('完整内容请查看数值'), findsOneWidget);
    expect(find.text('查看数值'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看数值'));
    await tester.tap(find.text('查看数值'));
    await tester.pumpAndSettle();
    expect(find.textContaining(detail), findsOneWidget);
  });

  testWidgets(
    'explicitly suppressed inspection leaves no unavailable full-text hint',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        chartApp(
          MonitorBarChart(
            showInspection: false,
            bars: [
              ChartBar(
                label: '1',
                value: 2,
                detail: List.filled(30, '主页面已有完整文本').join('\n'),
              ),
            ],
            unit: 's',
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('monitor-bar-0-primary'))),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('monitor-chart-hover')), findsOneWidget);
      expect(find.text('查看数值'), findsNothing);
      expect(find.text('完整内容请查看数值'), findsNothing);
      await mouse.removePointer();
      await tester.pumpAndSettle();
    },
  );
}
