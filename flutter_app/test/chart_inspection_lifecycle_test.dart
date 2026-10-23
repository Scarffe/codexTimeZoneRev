import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'monitor_charts_test.dart' show chartApp;

const _firstChart = MonitorBarChart(
  bars: [ChartBar(label: '精确样本', value: 1.23456789)],
  unit: 's',
);
const _nextChart = MonitorBarChart(
  bars: [ChartBar(label: '新样本', value: 9.87654321)],
  unit: 's',
);

Future<NavigatorState> _openInspection(
  WidgetTester tester,
  ValueNotifier<Widget> chart,
) async {
  await tester.pumpWidget(
    chartApp(
      ValueListenableBuilder<Widget>(
        valueListenable: chart,
        builder: (_, child, _) => child,
      ),
    ),
  );
  final navigator = Navigator.of(
    tester.element(find.byType(MonitorBarChart)),
    rootNavigator: true,
  );
  await tester.tap(find.text('查看数值'));
  await tester.pumpAndSettle();
  expect(find.text('图表数值'), findsOneWidget);
  expect(find.text('精确样本：1.23456789 s'), findsOneWidget);
  return navigator;
}

void _pushUnrelatedOverlay(NavigatorState navigator) {
  navigator.push<void>(
    RawDialogRoute<void>(
      pageBuilder: (_, _, _) => const Center(child: Text('另一项操作')),
      barrierDismissible: false,
    ),
  );
}

void main() {
  testWidgets('unchanged chart refresh keeps current exact values available', (
    tester,
  ) async {
    final chart = ValueNotifier<Widget>(_firstChart);
    addTearDown(chart.dispose);
    await _openInspection(tester, chart);

    // A poll rebuilds the chart and its records even when all facts are equal.
    chart.value = MonitorBarChart(
      bars: [ChartBar(label: '精确样本', value: 1.23456789)],
      unit: 's',
    );
    await tester.pumpAndSettle();

    expect(find.text('图表数值'), findsOneWidget);
    expect(find.text('精确样本：1.23456789 s'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('successful chart refresh dismisses the previous exact values', (
    tester,
  ) async {
    final chart = ValueNotifier<Widget>(_firstChart);
    addTearDown(chart.dispose);
    await _openInspection(tester, chart);

    chart.value = _nextChart;
    await tester.pumpAndSettle();

    expect(find.text('图表数值'), findsNothing);
    expect(find.text('精确样本：1.23456789 s'), findsNothing);
    await tester.tap(find.text('查看数值'));
    await tester.pumpAndSettle();
    expect(find.text('新样本：9.87654321 s'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('removing a chart dismisses its inspection while page stays', (
    tester,
  ) async {
    final chart = ValueNotifier<Widget>(_firstChart);
    addTearDown(chart.dispose);
    final navigator = await _openInspection(tester, chart);

    chart.value = const Text('当前没有图表');
    await tester.pumpAndSettle();

    expect(find.text('图表数值'), findsNothing);
    expect(find.text('精确样本：1.23456789 s'), findsNothing);
    expect(find.text('当前没有图表'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final removeChart in [false, true]) {
    testWidgets(
      'chart ${removeChart ? 'removal' : 'refresh'} never dismisses an unrelated overlay',
      (tester) async {
        final chart = ValueNotifier<Widget>(_firstChart);
        addTearDown(chart.dispose);
        final navigator = await _openInspection(tester, chart);
        _pushUnrelatedOverlay(navigator);
        await tester.pumpAndSettle();

        chart.value = removeChart ? const Text('当前没有图表') : _nextChart;
        await tester.pumpAndSettle();

        expect(find.text('另一项操作'), findsOneWidget);
        expect(find.text('图表数值', skipOffstage: false), findsNothing);
        expect(
          find.text('精确样本：1.23456789 s', skipOffstage: false),
          findsNothing,
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(navigator.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('normally closed inspection cannot later pop another route', (
    tester,
  ) async {
    final chart = ValueNotifier<Widget>(_firstChart);
    addTearDown(chart.dispose);
    final navigator = await _openInspection(tester, chart);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('图表数值'), findsNothing);
    _pushUnrelatedOverlay(navigator);
    await tester.pumpAndSettle();

    chart.value = _nextChart;
    await tester.pumpAndSettle();
    chart.value = const Text('当前没有图表');
    await tester.pumpAndSettle();

    expect(find.text('另一项操作'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
