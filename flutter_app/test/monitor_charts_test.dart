import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/session_activity_timeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'session_activity_fixture.dart';

Widget chartApp(Widget child, {bool dark = false, double scale = 1}) =>
    WidgetsApp(
      key: UniqueKey(),
      color: const Color(0xff000000),
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      builder: (context, child) => FTheme(
        data: dark ? darkLauncherTheme : lightLauncherTheme,
        child: FTooltipGroup(
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: DefaultTextStyle(
              style: TextStyle(
                fontSize: 14,
                color: (dark ? darkLauncherTheme : lightLauncherTheme)
                    .colors
                    .foreground,
              ),
              child: child!,
            ),
          ),
        ),
      ),
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => SingleChildScrollView(child: child),
      ),
    );

void main() {
  testWidgets('choice displays labels and lifts stored values to its caller', (
    tester,
  ) async {
    var value = 'model';
    String? changed;
    await tester.pumpWidget(
      chartApp(
        StatefulBuilder(
          builder: (context, setState) => MonitorChoice(
            label: '分组',
            value: value,
            items: const {'按模型': 'model', '按日期': 'date'},
            onChanged: (next) => setState(() {
              changed = next;
              value = next;
            }),
          ),
        ),
      ),
    );
    await tester.tap(find.text('按模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按日期').last);
    await tester.pumpAndSettle();
    expect(changed, 'date');
    expect(find.text('按日期'), findsOneWidget);
    expect(find.text('date'), findsNothing);
  });

  testWidgets('bar axes show units and count ticks reflect actual data', (
    tester,
  ) async {
    await tester.pumpWidget(
      chartApp(
        const MonitorBarChart(
          bars: [
            ChartBar(label: '甲', value: 3),
            ChartBar(label: '乙', value: 7),
          ],
          unit: '次',
          integers: true,
          xLabel: '回合',
        ),
      ),
    );
    expect(find.text('回合'), findsOneWidget);
    expect(find.text('次'), findsWidgets);
    expect(find.text('0'), findsWidgets);
    // The domain must accommodate 7 and use whole-number ticks, not 0–100%.
    final ticks = tester
        .widgetList<Text>(
          find.byWidgetPredicate(
            (w) =>
                w is Text &&
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'monitor-axis-tick-',
                ),
          ),
        )
        .map((w) => double.tryParse(w.data ?? ''))
        .whereType<double>()
        .toList();
    expect(ticks, isNotEmpty);
    expect(ticks.last, greaterThanOrEqualTo(7));
    expect(ticks.every((v) => v == v.roundToDouble()), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('requested domain is honored without hiding values above it', (
    tester,
  ) async {
    for (final sample in <(double, double)>[(60, 100), (125, 100)]) {
      await tester.pumpWidget(
        chartApp(
          MonitorBarChart(
            bars: [ChartBar(label: '额度', value: sample.$1)],
            unit: '%',
            maxValue: sample.$2,
          ),
        ),
      );
      final ticks = tester
          .widgetList<Text>(
            find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    'monitor-axis-tick-',
                  ),
            ),
          )
          .map((w) => double.tryParse(w.data ?? ''))
          .whereType<double>()
          .toList();
      expect(ticks.last, greaterThanOrEqualTo(sample.$1));
      if (sample.$1 == 60) expect(ticks.last, 100);
    }
  });

  testWidgets('column orientation survives many samples at narrow width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      chartApp(
        MonitorBarChart(
          bars: [
            for (var i = 0; i < 64; i++)
              ChartBar(label: '回合 $i', value: (i + 1).toDouble()),
          ],
          unit: 's',
          xLabel: '回合顺序',
        ),
        scale: 1.25,
      ),
    );
    final first = tester.getRect(
      find.byKey(const ValueKey('monitor-bar-0-primary')),
    );
    final last = tester.getRect(
      find.byKey(const ValueKey('monitor-bar-63-primary')),
    );
    expect(last.left, greaterThan(first.right));
    expect(last.bottom, closeTo(first.bottom, 0.1));
    expect(find.text('回合顺序'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unknown and cancelled bars expose gaps instead of invented zero',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          chartApp(
            const MonitorBarChart(
              bars: [
                ChartBar(label: '已记录', value: 0),
                ChartBar(label: '缺失', value: null),
                ChartBar(label: '中断', value: 12, cancelled: true),
              ],
              unit: 's',
              horizontal: true,
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('monitor-bar-0-primary')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('monitor-bar-1-primary')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('monitor-bar-2-primary')),
          findsNothing,
        );
        expect(find.text('—'), findsWidgets);
        expect(find.text('×'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('缺失.*未知')), findsWidgets);
        expect(find.bySemanticsLabel(RegExp('中断.*取消')), findsWidgets);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'stacking preserves known segments and labels unknown secondary',
    (tester) async {
      await tester.pumpWidget(
        chartApp(
          const MonitorBarChart(
            bars: [
              ChartBar(label: '完整', value: 3, secondaryValue: 6),
              ChartBar(label: '部分', value: 3),
            ],
            unit: 'tokens',
            showInspection: true,
            stacked: true,
            horizontal: true,
          ),
        ),
      );
      final primary = tester.getRect(
        find.byKey(const ValueKey('monitor-bar-0-primary')),
      );
      final secondary = tester.getRect(
        find.byKey(const ValueKey('monitor-bar-0-secondary')),
      );
      expect(secondary.left, closeTo(primary.right, 0.1));
      expect(secondary.width, closeTo(primary.width * 2, 0.1));
      expect(
        find.byKey(const ValueKey('monitor-bar-1-secondary')),
        findsNothing,
      );
      await tester.tap(find.text('查看数值'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('部分 · 数值：3.00 tokens · 补充数值：未知'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'named series remain meaningful in graph and numeric inspection',
    (tester) async {
      await tester.pumpWidget(
        chartApp(
          const MonitorBarChart(
            bars: [ChartBar(label: '响应一', value: 3, secondaryValue: 6)],
            showInspection: true,
            unit: 'tokens',
            stacked: true,
            primaryLabel: '非推理输出',
            secondaryLabel: '推理',
          ),
        ),
      );
      expect(find.text('非推理输出'), findsOneWidget);
      expect(find.text('推理'), findsOneWidget);
      expect(find.textContaining('第一序列'), findsNothing);
      expect(find.textContaining('第二序列'), findsNothing);
      await tester.tap(find.text('查看数值'));
      await tester.pumpAndSettle();
      expect(find.textContaining('非推理输出：3.00 tokens'), findsOneWidget);
      expect(find.textContaining('推理：6.00 tokens'), findsOneWidget);
      expect(find.textContaining('响应一'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('numeric disclosure is reachable by keyboard and touch', (
    tester,
  ) async {
    await tester.pumpWidget(
      chartApp(
        const MonitorBarChart(
          bars: [ChartBar(label: '明细', value: 1.2345, detail: '本地记录')],
          showInspection: true,
          unit: 's',
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('明细：1.23 s'), findsOneWidget);
    expect(find.textContaining('本地记录'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('明细：1.23 s'), findsNothing);
  });

  testWidgets(
    'timeline gives each separated interval a real independent lane',
    (tester) async {
      final fixture = timelineFixture(count: 2);
      fixture['items'][1]
        ..['category'] = 'message'
        ..['startedAtMs'] = 108000
        ..['completedAtMs'] = 109000
        ..['offsetStartMs'] = 8000
        ..['offsetEndMs'] = 9000
        ..['durationMs'] = 1000;
      await tester.pumpWidget(
        chartApp(
          MonitorIntervalChart(
            data: SessionActivityTimelineData.fromAnalysis({
              'timeline': fixture,
            }),
          ),
        ),
      );
      final first = tester.getRect(
        find.byKey(const ValueKey('monitor-interval-1')),
      );
      final second = tester.getRect(
        find.byKey(const ValueKey('monitor-interval-2')),
      );
      expect(first.height, greaterThanOrEqualTo(16));
      expect(second.height, greaterThanOrEqualTo(16));
      expect(second.top, greaterThanOrEqualTo(first.bottom));
      expect(second.left, greaterThan(first.right));
      expect(find.text('相对窗口时间 (s)'), findsOneWidget);
      expect(find.textContaining('空白不代表等待'), findsOneWidget);
    },
  );

  testWidgets(
    'missing timeline boundaries preserve facts without interval marks',
    (tester) async {
      final fixture = timelineFixture(count: 1)
        ..['startEpochMs'] = null
        ..['endEpochMsExclusive'] = null
        ..['spanMs'] = null
        ..['coverageInterpretation'] = 'unavailable';
      fixture['items'][0]
        ..['offsetStartMs'] = null
        ..['offsetEndMs'] = null
        ..['drawable'] = false
        ..['reasons'] = ['missing_turn_bounds'];
      await tester.pumpWidget(
        chartApp(
          MonitorIntervalChart(
            data: SessionActivityTimelineData.fromAnalysis({
              'timeline': fixture,
            }),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('monitor-interval-1')), findsNothing);
      expect(find.textContaining('缺少回合边界'), findsWidgets);
      await tester.tap(find.text('查看数值'));
      await tester.pumpAndSettle();
      expect(find.textContaining('101000'), findsOneWidget);
      expect(find.textContaining('106000'), findsOneWidget);
      expect(find.textContaining('5.00 s'), findsWidgets);
    },
  );

  testWidgets(
    'coverage reports seconds and denominator including empty input',
    (tester) async {
      await tester.pumpWidget(
        chartApp(
          const MonitorCoverageChart(observedMs: 7000, unclassifiedMs: 3000),
        ),
      );
      expect(find.textContaining('7.000 s'), findsWidgets);
      expect(find.textContaining('3.000 s'), findsWidgets);
      expect(find.textContaining('10.000 s'), findsWidgets);
      await tester.pumpWidget(
        chartApp(const MonitorCoverageChart(observedMs: 0, unclassifiedMs: 0)),
      );
      expect(find.textContaining('暂无可绘制覆盖数据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets('many groups remain readable at 320 and 125% dark=$dark', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        chartApp(
          MonitorChartFrame(
            title: '非常长的分组图表标题与说明',
            icon: FLucideIcons.chartColumn,
            controls: [
              MonitorChoice(
                label: '分组',
                value: 'model',
                items: const {'按模型': 'model', '按日期': 'date'},
                onChanged: (_) {},
              ),
            ],
            footnotes: const ['图表仅显示本地记录的已知数值。'],
            child: MonitorBarChart(
              bars: [
                for (var i = 0; i < 20; i++)
                  ChartBar(label: '很长的模型名称与分组标签 $i', value: i.toDouble()),
              ],
              unit: 'tokens',
              horizontal: true,
            ),
          ),
          dark: dark,
          scale: 1.25,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(MonitorBarChart)).height,
        greaterThan(800),
      );
      expect(find.text('按模型'), findsWidgets);
      expect(find.text('model'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        chartApp(
          MonitorIntervalChart(
            data: SessionActivityTimelineData.fromAnalysis({
              'timeline': timelineFixture(count: 40),
            }),
          ),
          dark: dark,
          scale: 1.25,
        ),
      );
      expect(
        tester.getSize(find.byType(MonitorIntervalChart)).height,
        greaterThan(1000),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        chartApp(
          const MonitorBarChart(bars: [], unit: 's'),
          dark: dark,
        ),
      );
      expect(find.textContaining('暂无可绘制数据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
