import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/dashboard_motion.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/session_activity_timeline.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'session_activity_fixture.dart';

const _sample = MonitorBarChart(
  bars: [ChartBar(label: '合成精确值', value: 1.23456789, secondaryValue: 2.5)],
  unit: 's',
  stacked: true,
);

Widget _surface(
  Widget chart, {
  bool reduced = false,
  bool osReduced = false,
  bool visible = true,
  bool dark = false,
  GlobalKey? capture,
  double scale = 1,
}) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (context, child) => FTheme(
    data: dark ? darkLauncherTheme : lightLauncherTheme,
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: osReduced,
        textScaler: TextScaler.linear(scale),
      ),
      child: DashboardMotionScope(
        reducedMotion: reduced,
        child: TickerMode(
          enabled: visible,
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 14,
              fontFamily: 'Segoe UI',
              fontFamilyFallback: const ['Microsoft YaHei'],
              color: (dark ? darkLauncherTheme : lightLauncherTheme)
                  .colors
                  .foreground,
            ),
            child: RepaintBoundary(key: capture, child: child!),
          ),
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) => PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => ColoredBox(
      color: dark ? const Color(0xff15171c) : const Color(0xfffafbfc),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [const Text('SYNTHETIC · 图表悬停演示'), chart]),
      ),
    ),
  ),
);

Finder _mark([String name = 'monitor-bar-0-primary']) =>
    find.byKey(ValueKey(name));
Finder _region(Finder mark) =>
    find.ancestor(of: mark, matching: find.byType(MouseRegion)).first;
Finder _transform(Finder mark) =>
    find.ancestor(of: mark, matching: find.byType(Transform));
Finder _effect(Finder mark) =>
    find.ancestor(of: mark, matching: find.byType(CustomPaint)).first;

Future<TestGesture> _hover(WidgetTester tester, Finder mark) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  await mouse.moveTo(tester.getCenter(mark));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  return mouse;
}

void _expectNoParticles(WidgetTester tester, Finder mark) {
  final painter = tester.widget<CustomPaint>(_effect(mark)).foregroundPainter;
  expect(painter, isNotNull);
  expect(
    (Canvas canvas) => painter!.paint(canvas, tester.getSize(mark)),
    paintsNothing,
  );
}

void main() {
  final frameDirectory = Platform.environment['CHART_MOTION_RENDER_DIR'];
  if (frameDirectory != null) {
    setUpAll(() async {
      for (final (family, asset) in [
        ('packages/forui/Inter', 'packages/forui/assets/fonts/inter/Inter.ttf'),
        (
          'packages/forui_lucide/ForuiLucideIcons',
          'packages/forui_lucide/assets/lucide.ttf',
        ),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
      }
      for (final (family, path) in [
        ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
        ('Segoe UI Variable Text', r'C:\Windows\Fonts\SegUIVar.ttf'),
        ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ]) {
        final font = File(path);
        if (font.existsSync()) {
          await (FontLoader(
            family,
          )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
        }
      }
    });
  }
  testWidgets(
    'hover without clicking widens columns but preserves baseline stack and hit region',
    (tester) async {
      await tester.pumpWidget(_surface(_sample));
      final mark = _mark();
      final secondary = _mark('monitor-bar-0-secondary');
      final resting = tester.getRect(mark);
      final stack = tester.getRect(secondary);
      final hit = tester.getRect(_region(mark));
      final axis = tester.getRect(
        find.byKey(const ValueKey('monitor-axis-tick-0')),
      );
      final mouse = await _hover(tester, mark);
      expect(
        _transform(mark),
        findsOneWidget,
        reason: 'actual mark needs paint-only hover feedback',
      );
      final active = tester.getRect(mark);
      expect(active.width, greaterThan(resting.width));
      expect(active.width, lessThanOrEqualTo(resting.width * 1.06 + .001));
      expect(active.top, closeTo(resting.top, .001));
      expect(active.bottom, closeTo(resting.bottom, .001));
      expect(tester.getRect(secondary), stack);
      expect(active.top, closeTo(stack.bottom, .001));
      expect(tester.getRect(_region(mark)), hit);
      expect(
        tester.getRect(find.byKey(const ValueKey('monitor-axis-tick-0'))),
        axis,
      );
      expect(find.textContaining('1.23456789 s'), findsWidgets);
      final painter = tester
          .widget<CustomPaint>(_effect(mark))
          .foregroundPainter!;
      expect(
        (Canvas canvas) => painter.paint(canvas, resting.size),
        paintsExactlyCountTimes(#drawCircle, 6),
      );
      await tester.pump(const Duration(milliseconds: 480));
      expect(tester.getRect(mark), resting);
      _expectNoParticles(tester, mark);
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
    },
  );

  for (final meters in [false, true]) {
    testWidgets(
      'horizontal ${meters ? 'meters' : 'stacks'} thicken without moving quantitative endpoints',
      (tester) async {
        await tester.pumpWidget(
          _surface(
            MonitorBarChart(
              bars: const [ChartBar(label: '合成', value: 3, secondaryValue: 6)],
              unit: 'tokens',
              horizontal: true,
              stacked: true,
              compactMeters: meters,
            ),
          ),
        );
        final mark = _mark();
        final secondary = _mark('monitor-bar-0-secondary');
        final before = tester.getRect(mark);
        final next = tester.getRect(secondary);
        final hit = tester.getRect(_region(mark));
        final mouse = await _hover(tester, mark);
        expect(_transform(mark), findsOneWidget);
        final during = tester.getRect(mark);
        expect(during.left, before.left);
        expect(during.right, before.right);
        expect(during.right, next.left);
        expect(during.center.dy, before.center.dy);
        expect(during.height, greaterThan(before.height));
        expect(during.height, lessThanOrEqualTo(before.height * 1.08 + .001));
        expect(tester.getRect(_region(mark)), hit);
        await mouse.removePointer();
        await tester.pump();
        expect(tester.getRect(mark), before);
        _expectNoParticles(tester, mark);
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }

  testWidgets(
    'line hover keeps point center and connecting path fixed and announces line',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _surface(
          const MonitorBarChart(
            bars: [
              ChartBar(label: '零', value: 0),
              ChartBar(label: '合成点', value: 4),
            ],
            unit: 's',
            line: true,
          ),
        ),
      );
      final mark = _mark('monitor-bar-1-primary');
      final before = tester.getRect(mark);
      final line = find.byKey(const ValueKey('monitor-duration-line'));
      final path = tester.widget<CustomPaint>(line).painter;
      final rect = tester.getRect(line);
      expect(find.bySemanticsLabel(RegExp('折线图，')), findsOneWidget);
      final mouse = await _hover(tester, mark);
      expect(_transform(mark), findsOneWidget);
      final during = tester.getRect(mark);
      expect(during.center, before.center);
      expect(during.width, greaterThan(before.width));
      expect(during.width, lessThanOrEqualTo(before.width * 1.18 + .001));
      expect(tester.getRect(line), rect);
      expect(tester.widget<CustomPaint>(line).painter, same(path));
      await mouse.removePointer();
      semantics.dispose();
    },
  );

  testWidgets('interval hover preserves both time endpoints', (tester) async {
    await tester.pumpWidget(
      _surface(
        MonitorIntervalChart(
          data: SessionActivityTimelineData.fromAnalysis({
            'timeline': timelineFixture(count: 1),
          }),
        ),
      ),
    );
    final mark = _mark('monitor-interval-1');
    final before = tester.getRect(mark);
    final mouse = await _hover(tester, mark);
    expect(_transform(mark), findsOneWidget);
    final during = tester.getRect(mark);
    expect(during.left, before.left);
    expect(during.right, before.right);
    expect(during.center.dy, before.center.dy);
    expect(during.height, greaterThan(before.height));
    expect(during.height, lessThanOrEqualTo(before.height * 1.08 + .001));
    await mouse.removePointer();
  });

  testWidgets(
    'dense edge points keep the finite paint response inside the chart boundary',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _surface(
          MonitorBarChart(
            bars: [
              for (var i = 0; i < 64; i++) ChartBar(label: '合成$i', value: 4),
            ],
            unit: 's',
            line: true,
          ),
        ),
      );
      final edge = _mark('monitor-bar-63-primary');
      final before = tester.getRect(edge);
      final bounds = tester.getRect(find.byType(MonitorBarChart));
      final mouse = await _hover(tester, edge);
      final during = tester.getRect(edge);
      expect(during.center, before.center);
      expect(during.right, lessThanOrEqualTo(bounds.right));
      final painter = tester
          .widget<CustomPaint>(_effect(edge))
          .foregroundPainter!;
      expect(
        (Canvas canvas) => painter.paint(canvas, before.size),
        paintsExactlyCountTimes(#drawCircle, 6),
      );
      await mouse.removePointer();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'rapid mark crossing replaces the finite burst without accumulating particles',
    (tester) async {
      await tester.pumpWidget(
        _surface(
          const MonitorBarChart(
            bars: [
              ChartBar(label: '第一合成值', value: 3),
              ChartBar(label: '第二合成值', value: 4),
            ],
            unit: 's',
          ),
        ),
      );
      final first = _mark();
      final second = _mark('monitor-bar-1-primary');
      final mouse = await _hover(tester, first);
      await mouse.moveTo(tester.getCenter(second));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      _expectNoParticles(tester, first);
      expect(find.byKey(const ValueKey('monitor-chart-hover')), findsOneWidget);
      expect(find.text('第二合成值：4 s'), findsOneWidget);
      final painter = tester
          .widget<CustomPaint>(_effect(second))
          .foregroundPainter!;
      expect(
        (Canvas canvas) => painter.paint(canvas, tester.getSize(second)),
        paintsExactlyCountTimes(#drawCircle, 6),
      );
      await mouse.moveTo(const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(second));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final replaced = tester
          .widget<CustomPaint>(_effect(second))
          .foregroundPainter!;
      expect(
        (Canvas canvas) => replaced.paint(canvas, tester.getSize(second)),
        paintsExactlyCountTimes(#drawCircle, 6),
      );
      await tester.pump(const Duration(milliseconds: 480));
      _expectNoParticles(tester, second);
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
    },
  );

  for (final stop in [
    'exit',
    'changed',
    'equal',
    'app',
    'os',
    'hidden',
    'dispose',
  ]) {
    testWidgets('$stop cancels an active burst and never replays it', (
      tester,
    ) async {
      final settings = ValueNotifier(0);
      addTearDown(settings.dispose);
      const stableChart = MonitorBarChart(
        bars: [ChartBar(label: '合成值', value: 4)],
        unit: 's',
      );
      await tester.pumpWidget(
        _surface(
          ValueListenableBuilder<int>(
            valueListenable: settings,
            child: stableChart,
            builder: (_, state, retained) => MediaQuery(
              data: MediaQueryData(
                disableAnimations: stop == 'os' && state == 1,
              ),
              child: DashboardMotionScope(
                reducedMotion: stop == 'app' && state == 1,
                child: TickerMode(
                  enabled: !(stop == 'hidden' && state == 1),
                  child: stop == 'dispose' && state == 1
                      ? const Text('removed')
                      : stop == 'changed' || stop == 'equal'
                      ? MonitorBarChart(
                          bars: [
                            ChartBar(
                              label: '合成值',
                              value: stop == 'changed' && state == 1 ? 7 : 4,
                            ),
                          ],
                          unit: 's',
                        )
                      : retained!,
                ),
              ),
            ),
          ),
        ),
      );
      final mark = _mark();
      final mouse = await _hover(tester, mark);
      expect(_transform(mark), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      if (stop == 'exit') {
        await mouse.moveTo(const Offset(1, 1));
      } else {
        settings.value = 1;
      }
      await tester.pump();
      await tester.pump();
      if (stop != 'dispose') _expectNoParticles(tester, mark);
      expect(tester.binding.transientCallbackCount, 0);
      if (stop == 'hidden' ||
          stop == 'changed' ||
          stop == 'equal' ||
          stop == 'dispose') {
        expect(find.byKey(const ValueKey('monitor-chart-hover')), findsNothing);
      }
      if (stop == 'app' || stop == 'os') {
        expect(find.text('合成值：4 s'), findsOneWidget);
        await mouse.moveTo(const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(mark));
        await tester.pump(const Duration(milliseconds: 100));
        _expectNoParticles(tester, mark);
        expect(find.text('合成值：4 s'), findsOneWidget);
      }
      if (stop == 'dispose') await mouse.moveTo(const Offset(1, 1));
      settings.value = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _expectNoParticles(tester, mark);
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'unknown cancelled and true zero never receive invented motion geometry',
    (tester) async {
      await tester.pumpWidget(
        _surface(
          const MonitorBarChart(
            bars: [
              ChartBar(label: '零', value: 0),
              ChartBar(label: '未知', value: null),
              ChartBar(label: '取消', value: 9, cancelled: true),
            ],
            unit: 's',
            horizontal: true,
          ),
        ),
      );
      expect(tester.getSize(_mark()).width, 0);
      expect(_mark('monitor-bar-1-primary'), findsNothing);
      expect(_mark('monitor-bar-2-primary'), findsNothing);
      for (final name in ['monitor-bar-1-unknown', 'monitor-bar-2-cancelled']) {
        final glyph = _mark(name);
        final before = tester.getRect(glyph);
        final mouse = await _hover(tester, glyph);
        expect(tester.getRect(glyph), before);
        expect(tester.binding.transientCallbackCount, 0);
        await mouse.removePointer();
      }
    },
  );

  testWidgets(
    'tall hover fits live viewport and full precision remains in numeric inspector',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = List.generate(
        30,
        (i) => '合成记录 $i：1.234567890123456789',
      ).join('\n');
      await tester.pumpWidget(
        _surface(
          MonitorBarChart(
            bars: [ChartBar(label: '高卡片', value: 1.23456789, detail: detail)],
            unit: 's',
          ),
          scale: 1.25,
        ),
      );
      final mouse = await _hover(tester, _mark());
      final card = tester.getRect(
        find.byKey(const ValueKey('monitor-chart-hover')),
      );
      expect(card.left, greaterThanOrEqualTo(0));
      expect(card.right, lessThanOrEqualTo(320));
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(400));
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看数值'));
      await tester.tap(find.text('查看数值'));
      await tester.pumpAndSettle();
      expect(find.textContaining(detail), findsOneWidget);
      expect(find.textContaining('高卡片：1.23456789 s'), findsOneWidget);
    },
  );

  if (frameDirectory != null) {
    for (final dark in [false, true]) {
      for (final width in [320.0, 600.0, 1280.0]) {
        testWidgets(
          'capture synthetic actual Flutter chart motion $dark $width',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 900);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final capture = GlobalKey();
            await tester.pumpWidget(
              _surface(
                Column(
                  children: [
                    const Text('响应输出 tokens（合成示例）'),
                    const MonitorBarChart(
                      bars: [
                        ChartBar(
                          label: '响应 01',
                          value: 120,
                          secondaryValue: 64,
                        ),
                        ChartBar(
                          label: '响应 02',
                          value: 84,
                          secondaryValue: 130,
                        ),
                        ChartBar(
                          label: '响应 03',
                          value: 184.23456789,
                          secondaryValue: 96,
                        ),
                        ChartBar(label: '响应 04', value: 62, secondaryValue: 42),
                        ChartBar(
                          label: '响应 05',
                          value: 220,
                          secondaryValue: 170,
                        ),
                        ChartBar(
                          label: '响应 06',
                          value: 132,
                          secondaryValue: 76,
                        ),
                      ],
                      unit: 'tokens',
                      stacked: true,
                      primaryLabel: '非推理输出',
                      secondaryLabel: '推理',
                      xLabel: '响应顺序',
                    ),
                    const Text('账户配额（合成示例）'),
                    const MonitorBarChart(
                      bars: [
                        ChartBar(label: '合成配额', value: 63.456789),
                        ChartBar(label: '缺失', value: null),
                      ],
                      unit: '%',
                      horizontal: true,
                      compactMeters: true,
                    ),
                    const Text('最近 64 回合时长（合成示例，含缺失）'),
                    MonitorBarChart(
                      bars: [
                        for (var i = 0; i < 64; i++)
                          ChartBar(
                            label: '合成$i',
                            value: i == 17 ? null : (i % 7).toDouble(),
                          ),
                      ],
                      unit: 's',
                      line: true,
                    ),
                  ],
                ),
                dark: dark,
                capture: capture,
                scale: 1.25,
              ),
            );
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: const Offset(1, 1));
            var previous = 0;
            for (final elapsed in [0, 80, 160, 280, 440, 560]) {
              if (elapsed == 80) {
                await mouse.moveTo(
                  tester.getCenter(_mark('monitor-bar-2-primary').first),
                );
                await tester.pump();
              }
              await tester.pump(Duration(milliseconds: elapsed - previous));
              previous = elapsed;
              await tester.runAsync(() async {
                final image =
                    await (capture.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await Directory(frameDirectory).create(recursive: true);
                  await File(
                    '$frameDirectory/synthetic-charts-${dark ? 'dark' : 'light'}-${width.toInt()}-$elapsed.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
            }
            await mouse.removePointer();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
