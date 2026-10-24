import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/fluid_chart_effects.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/session_activity_timeline.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'monitor_charts_test.dart' show chartApp;
import 'session_activity_fixture.dart';

class _PaintTrace implements Canvas {
  final bands = <Rect>[];
  final centers = <Offset>[];
  final alphas = <double>[];
  @override
  void drawPath(Path path, Paint paint) => bands.add(path.getBounds());
  @override
  void drawCircle(Offset center, double radius, Paint paint) {
    if (radius < 2) {
      centers.add(center);
      alphas.add(paint.color.a);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

_PaintTrace _trace(ChartHoverPainter painter, Size size, int ms) {
  (painter.elapsed as ValueNotifier<Duration?>).value = Duration(
    milliseconds: ms,
  );
  final trace = _PaintTrace();
  painter.paint(trace, size);
  return trace;
}

ChartHoverPainter _painter(ValueNotifier<Duration?> clock) => ChartHoverPainter(
  elapsed: clock,
  color: const Color(0xff356d7d),
  viewport: const Rect.fromLTWH(-12, -12, 224, 174),
);

void main() {
  test('column band travels upward without transverse motion', () {
    final clock = ValueNotifier<Duration?>(Duration.zero);
    addTearDown(clock.dispose);
    final painter = _painter(clock);
    final first = _trace(painter, const Size(38, 150), 100).bands;
    final later = _trace(painter, const Size(38, 150), 200).bands;
    expect(first, isNotEmpty);
    expect(later.length, first.length);
    for (var i = 0; i < first.length; i++) {
      expect(later[i].center.dy, lessThan(first[i].center.dy));
      expect(later[i].center.dx, first[i].center.dx);
    }
  });

  test('perimeter particles drift outward more than tangentially', () {
    final clock = ValueNotifier<Duration?>(Duration.zero);
    addTearDown(clock.dispose);
    final painter = _painter(clock);
    final first = _trace(painter, const Size(200, 20), 100);
    final later = _trace(painter, const Size(200, 20), 200);
    // Particle zero emits on the top edge; negative Y is outward.
    final movement = later.centers.first - first.centers.first;
    expect(movement.dy, lessThan(0));
    expect(movement.dx.abs(), lessThan(-movement.dy));
    expect(first.centers.length, lessThanOrEqualTo(16));
  });

  test('particle positions stay continuous through liquid period wrap', () {
    final clock = ValueNotifier<Duration?>(Duration.zero);
    addTearDown(clock.dispose);
    final painter = _painter(clock);
    final before = _trace(painter, const Size(200, 20), 1249);
    final after = _trace(painter, const Size(200, 20), 1251);
    var checked = 0;
    for (var i = 0; i < before.centers.length; i++) {
      if (before.alphas[i] > .1 && after.alphas[i] > .1) {
        expect((after.centers[i] - before.centers[i]).distance, lessThan(.1));
        checked++;
      }
    }
    expect(checked, greaterThan(8));
  });

  test('particle cycle is 1700ms independent of the liquid cycle', () {
    final clock = ValueNotifier<Duration?>(Duration.zero);
    addTearDown(clock.dispose);
    final painter = _painter(clock);
    final first = _trace(painter, const Size(200, 20), 100);
    final liquidCycle = _trace(painter, const Size(200, 20), 1350);
    final particleCycle = _trace(painter, const Size(200, 20), 1800);
    expect(particleCycle.centers, first.centers);
    expect(particleCycle.alphas, first.alphas);
    expect(liquidCycle.centers, isNot(first.centers));
  });

  test('every edge emits a bounded outward plume without perimeter travel', () {
    final clock = ValueNotifier<Duration?>(Duration.zero);
    addTearDown(clock.dispose);
    final painter = _painter(clock);
    const size = Size(200, 150);
    final first = _trace(painter, size, 100);
    final later = _trace(painter, size, 120);
    final edges = <Offset>{};
    for (var i = 0; i < first.centers.length; i++) {
      final origin = first.centers[i];
      final normal = origin.dy < 0
          ? const Offset(0, -1)
          : origin.dx > size.width
          ? const Offset(1, 0)
          : origin.dy > size.height
          ? const Offset(0, 1)
          : const Offset(-1, 0);
      final movement = later.centers[i] - origin;
      final outward = movement.dx * normal.dx + movement.dy * normal.dy;
      // Ignore a particle's own invisible rebirth; the others keep their edge.
      if (outward < 0 && first.alphas[i] < .1) continue;
      final tangent = movement.dx * -normal.dy + movement.dy * normal.dx;
      expect(outward, greaterThan(0));
      expect(tangent.abs(), lessThan(outward));
      edges.add(normal);
    }
    expect(edges.length, 4);
  });

  final placements = <(String, Widget, List<String>, bool)>[
    (
      'columns',
      const MonitorBarChart(
        bars: [ChartBar(label: 'value', value: 3, secondaryValue: 2)],
        unit: 's',
        stacked: true,
      ),
      ['monitor-bar-0-primary', 'monitor-bar-0-secondary'],
      false,
    ),
    (
      'horizontal stack',
      const MonitorBarChart(
        bars: [ChartBar(label: 'value', value: 3, secondaryValue: 2)],
        unit: 's',
        stacked: true,
        horizontal: true,
      ),
      ['monitor-bar-0-primary', 'monitor-bar-0-secondary'],
      true,
    ),
    (
      'short quota',
      const MonitorBarChart(
        bars: [ChartBar(label: 'quota', value: .01)],
        unit: '%',
        horizontal: true,
        compactMeters: true,
        maxValue: 100,
      ),
      ['monitor-bar-0-primary'],
      true,
    ),
    (
      'coverage',
      const MonitorCoverageChart(observedMs: 3000, unclassifiedMs: 2000),
      ['monitor-bar-0-primary', 'monitor-bar-0-secondary'],
      true,
    ),
    (
      'interval',
      MonitorIntervalChart(
        data: SessionActivityTimelineData.fromAnalysis({
          'timeline': timelineFixture(count: 1),
        }),
      ),
      ['monitor-interval-1'],
      true,
    ),
  ];
  for (final (name, chart, keys, horizontal) in placements) {
    testWidgets('$name wires direction and retains measured geometry', (
      tester,
    ) async {
      await tester.pumpWidget(chartApp(chart));
      for (final key in keys) {
        final mark = find.byKey(ValueKey(key));
        final bounds = tester.getRect(mark);
        final paint = tester.widget<CustomPaint>(
          find.ancestor(of: mark, matching: find.byType(CustomPaint)).first,
        );
        final painter = paint.foregroundPainter! as ChartHoverPainter;
        final first = _trace(painter, bounds.size, 100).bands;
        final later = _trace(painter, bounds.size, 200).bands;
        expect(first, isNotEmpty);
        for (var i = 0; i < first.length; i++) {
          final movement = later[i].center - first[i].center;
          if (horizontal) {
            expect(movement.dx, greaterThan(0), reason: key);
            expect(movement.dy, closeTo(0, .00001));
          } else {
            expect(movement.dy, lessThan(0), reason: key);
            expect(movement.dx, closeTo(0, .00001));
          }
        }
        expect(tester.getRect(mark), bounds);
      }
    });
  }

  final frames = Platform.environment['DIRECTIONAL_CHART_RENDER_DIR'];
  if (frames != null) {
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
    for (final horizontal in [false, true]) {
      for (final dark in [false, true]) {
        for (final width in [320.0, 600.0]) {
          testWidgets('timed frames $horizontal $dark $width', (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 480);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final capture = GlobalKey();
            await tester.pumpWidget(
              chartApp(
                RepaintBoundary(
                  key: capture,
                  child: ColoredBox(
                    color: (dark ? darkLauncherTheme : lightLauncherTheme)
                        .colors
                        .background,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: MonitorBarChart(
                        bars: const [
                          ChartBar(
                            label: 'Synthetic A',
                            value: 30,
                            secondaryValue: 20,
                          ),
                          ChartBar(
                            label: 'Synthetic B',
                            value: 20,
                            secondaryValue: 10,
                          ),
                        ],
                        unit: 's',
                        horizontal: horizontal,
                        stacked: true,
                      ),
                    ),
                  ),
                ),
                dark: dark,
              ),
            );
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: const Offset(1, 1));
            final mark = find.byKey(const ValueKey('monitor-bar-0-primary'));
            final measured = tester.getRect(mark);
            await mouse.moveTo(tester.getCenter(mark));
            await tester.pump();
            var previous = 0;
            for (final ms in [100, 200, 600, 1249, 1251, 1699, 1701]) {
              await tester.pump(Duration(milliseconds: ms - previous));
              previous = ms;
              if (ms >= 600) expect(tester.getRect(mark), measured);
              await tester.runAsync(() async {
                final image =
                    await (capture.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await Directory(frames).create(recursive: true);
                  await File(
                    '$frames/task1-${horizontal ? 'horizontal' : 'vertical'}-${dark ? 'dark' : 'light'}-${width.toInt()}-$ms.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
            }
            await mouse.removePointer();
            await tester.pumpAndSettle();
            expect(tester.binding.transientCallbackCount, 0);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
