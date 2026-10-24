import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/dashboard_motion.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/domain/settings.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'monitor_charts_test.dart' show chartApp;

const _samples = [
  ChartBar(identity: 'known', label: '已知', value: 25.123456),
  ChartBar(identity: 'zero', label: '零', value: 0),
  ChartBar(identity: 'unknown', label: '缺失', value: null),
];

Widget _chart(
  bool ring, {
  Object identity = 'source-a',
  List<ChartBar> bars = _samples,
  bool hover = true,
}) => ring
    ? MonitorRingChart(
        bars: bars,
        inspectionIdentity: identity,
        hoverDetails: hover,
      )
    : MonitorCategoryDotChart(
        bars: bars,
        unit: 'tokens/s',
        inspectionIdentity: identity,
        hoverDetails: hover,
      );

void main() {
  setUpAll(timezone.initializeTimeZones);

  test('palette separates blue data from gold decorative chrome', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      final palette = DashboardPalette.forBrightness(brightness);
      expect(palette.background, Color(dark ? 0xff111723 : 0xffe7ebf1));
      expect(palette.panel, Color(dark ? 0xff1a2232 : 0xfff1f3f6));
      expect(palette.dataBlue, Color(dark ? 0xff5987ff : 0xff2459eb));
      expect(palette.chromeGold, Color(dark ? 0xffe6ca93 : 0xffd6ba84));
      expect(palette.accent, palette.dataBlue);
      expect(palette.dataBlue, isNot(palette.chromeGold));
    }
  });

  testWidgets(
    'rings preserve independent percent arcs and distinguish zero unknown and invalid',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        chartApp(
          const MonitorRingChart(
            bars: [
              ChartBar(label: '四分之一', value: 25),
              ChartBar(label: '四分之三', value: 75),
              ChartBar(label: '零', value: 0),
              ChartBar(label: '满', value: 100),
              ChartBar(label: '缺失', value: null),
              ChartBar(label: '超出百分比', value: 101),
              ChartBar(label: '无穷', value: double.infinity),
            ],
          ),
        ),
      );
      for (final i in [0, 1, 2, 3]) {
        expect(find.byKey(ValueKey('monitor-ring-$i')), findsOneWidget);
      }
      for (final i in [4, 5, 6]) {
        expect(find.byKey(ValueKey('monitor-ring-$i-unknown')), findsOneWidget);
        expect(find.byKey(ValueKey('monitor-ring-$i')), findsNothing);
      }
      expect(find.bySemanticsLabel(RegExp('零：0.00 %')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('缺失：未知')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('独立额度环图.*每项分母 100%')),
        findsOneWidget,
      );

      // Rasterize the actual production painter: the second ring's denominator
      // remains 100, not 25+75; the zero track has no data-colored circumference.
      Future<bool> blueAt(int index, double angle) async {
        final paint = tester
            .widget<CustomPaint>(find.byKey(ValueKey('monitor-ring-$index')))
            .painter!;
        final recorder = ui.PictureRecorder();
        paint.paint(Canvas(recorder), const Size(88, 88));
        final picture = recorder.endRecording();
        final image = await picture.toImage(88, 88);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        final x = (44 + 39 * math.cos(angle)).round();
        final y = (44 + 39 * math.sin(angle)).round();
        final offset = (y * 88 + x) * 4;
        final result =
            bytes!.getUint8(offset) == 0x24 &&
            bytes.getUint8(offset + 1) == 0x59 &&
            bytes.getUint8(offset + 2) == 0xeb;
        image.dispose();
        picture.dispose();
        return result;
      }

      await tester.runAsync(() async {
        expect(await blueAt(0, -math.pi / 4), isTrue);
        expect(await blueAt(0, math.pi / 4), isFalse);
        expect(await blueAt(1, math.pi / 4), isTrue);
        expect(await blueAt(1, -3 * math.pi / 4), isFalse);
        expect(await blueAt(2, -math.pi / 4), isFalse);
        expect(await blueAt(3, -3 * math.pi / 4), isTrue);
      });
      semantics.dispose();
    },
  );

  testWidgets(
    'category dots are aggregate rows with common domain and true zero gaps',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        chartApp(
          const MonitorCategoryDotChart(
            bars: [
              ChartBar(label: '组甲 · 8 回合', value: 25),
              ChartBar(label: '组乙 · 3 回合', value: 50),
              ChartBar(label: '零', value: 0),
              ChartBar(label: '缺失', value: null),
              ChartBar(label: '中断', value: 90, cancelled: true),
            ],
            unit: 'tokens/s',
          ),
        ),
      );
      for (final i in [0, 1, 2]) {
        expect(find.byKey(ValueKey('monitor-dot-$i')), findsOneWidget);
      }
      for (final i in [3, 4]) {
        expect(find.byKey(ValueKey('monitor-dot-$i')), findsNothing);
      }
      final zero = tester
          .getCenter(find.byKey(const ValueKey('monitor-dot-2')))
          .dx;
      final a =
          tester.getCenter(find.byKey(const ValueKey('monitor-dot-0'))).dx -
          zero;
      final b =
          tester.getCenter(find.byKey(const ValueKey('monitor-dot-1'))).dx -
          zero;
      expect(b, closeTo(a * 2, .01));
      expect(find.bySemanticsLabel(RegExp('分类点图.*每组一个点')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('中断：取消')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('缺失：未知')), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets(
    'pure quota entry preserves used remaining expiry and has no query controls',
    (tester) async {
      final now = DateTime.utc(2026, 10, 24, 12);
      final bucket = UsageBucket(
        id: 'bucket',
        label: '额度组',
        windows: [
          UsageWindow(
            usedPercent: 20.123456,
            durationMinutes: 300,
            resetsAt: now.subtract(const Duration(seconds: 1)),
          ),
          const UsageWindow(durationMinutes: 60),
        ],
      );
      Widget presentation(String view) => AccountQuotaPresentation(
        bucket: bucket,
        settings: const LauncherSettings(),
        useLocalTime: true,
        now: now,
        view: view,
      );
      await tester.pumpWidget(chartApp(presentation('remaining')));
      final remaining = tester.widget<MonitorRingChart>(
        find.byType(MonitorRingChart),
      );
      expect(remaining.bars.first.value, closeTo(79.876544, .000001));
      expect(remaining.hoverDetails, isFalse);
      expect(remaining.bars.first.detail, contains('到期 · 待查询'));
      expect(remaining.bars.last.value, isNull);
      expect(find.byType(MonitorChoice), findsNothing);
      expect(find.byKey(const ValueKey('query-account-usage')), findsNothing);
      expect(find.byKey(const ValueKey('toggle-usage-monitor')), findsNothing);
      await tester.pumpWidget(chartApp(presentation('used')));
      expect(
        tester
            .widget<MonitorRingChart>(find.byType(MonitorRingChart))
            .bars
            .first
            .value,
        20.123456,
      );
      await tester.pumpWidget(chartApp(presentation('reset')));
      expect(find.byType(MonitorRingChart), findsNothing);
      final reset = tester.widget<MonitorBarChart>(
        find.byType(MonitorBarChart),
      );
      expect(reset.bars.map((bar) => bar.value), [null, null]);
      expect(reset.unit, '小时');
    },
  );

  for (final ring in [true, false]) {
    final type = ring ? 'ring' : 'dot';
    testWidgets(
      '$type explicit numeric inspector supports keyboard precision and unknown',
      (tester) async {
        await tester.pumpWidget(chartApp(_chart(ring)));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('图表数值'), findsOneWidget);
        expect(find.textContaining('已知：25.12'), findsOneWidget);
        expect(find.textContaining('缺失：未知'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          chartApp(
            _chart(ring, bars: [const ChartBar(label: '小值', value: .00001)]),
          ),
        );
        await tester.tap(find.text('查看数值'));
        await tester.pumpAndSettle();
        expect(find.textContaining('小值：<0.01'), findsOneWidget);
      },
    );

    testWidgets(
      '$type identity closes obsolete disclosure but preserves unrelated overlay',
      (tester) async {
        final chart = ValueNotifier<Widget>(_chart(ring));
        addTearDown(chart.dispose);
        await tester.pumpWidget(
          chartApp(
            ValueListenableBuilder<Widget>(
              valueListenable: chart,
              builder: (_, value, _) => value,
            ),
          ),
        );
        await tester.tap(find.text('查看数值'));
        await tester.pumpAndSettle();
        chart.value = _chart(
          ring,
        ); // equivalent refresh retains useful inspection
        await tester.pumpAndSettle();
        expect(find.text('图表数值'), findsOneWidget);
        final navigator = Navigator.of(
          tester.element(find.text('查看数值')),
          rootNavigator: true,
        );
        navigator.push<void>(
          RawDialogRoute<void>(
            pageBuilder: (_, _, _) => const Center(child: Text('其他操作')),
            barrierDismissible: false,
          ),
        );
        await tester.pumpAndSettle();
        chart.value = _chart(
          ring,
          identity: 'source-b',
        ); // equal values, new owner
        await tester.pumpAndSettle();
        expect(find.text('图表数值'), findsNothing);
        expect(find.text('其他操作'), findsOneWidget);
        navigator.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('查看数值'));
        await tester.pumpAndSettle();
        chart.value = const Text('已移除');
        await tester.pumpAndSettle();
        expect(find.text('图表数值'), findsNothing);
        expect(navigator.canPop(), isFalse);
      },
    );

    testWidgets(
      '$type generic hover default and account suppression retain motion policy',
      (tester) async {
        final state = ValueNotifier<(bool, bool, bool)>((true, false, true));
        addTearDown(state.dispose);
        await tester.pumpWidget(
          chartApp(
            ValueListenableBuilder<(bool, bool, bool)>(
              valueListenable: state,
              builder: (_, value, _) => DashboardMotionScope(
                reducedMotion: value.$2,
                child: TickerMode(
                  enabled: value.$3,
                  child: _chart(ring, hover: value.$1),
                ),
              ),
            ),
          ),
        );
        final mark = find.byKey(
          ValueKey(ring ? 'monitor-ring-0' : 'monitor-dot-0'),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(mark));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('monitor-chart-hover')),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.binding.transientCallbackCount, greaterThan(0));
        state.value = (false, true, true);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        await mouse.moveTo(const Offset(1, 1));
        await tester.pump();
        await mouse.moveTo(tester.getCenter(mark));
        await tester.pump();
        expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        state.value = (true, false, false);
        await tester.pump();
        await tester.pump();
        expect(tester.binding.transientCallbackCount, 0);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets('ring and dot labels fit 320 width and 125% dark=$dark', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        chartApp(
          Column(children: [_chart(true), _chart(false)]),
          dark: dark,
          scale: 1.25,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('查看数值').last);
      await tester.tap(find.text('查看数值').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('已知：25.12 tokens/s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
