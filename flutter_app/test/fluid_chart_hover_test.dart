import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/fluid_chart_effects.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'monitor_charts_test.dart' show chartApp;

Future<Uint8List> _pixels(Duration time, {bool liquid = false}) async {
  final elapsed = ValueNotifier<Duration?>(time);
  final recording = ui.PictureRecorder();
  final canvas = Canvas(recording)..translate(20, 20);
  if (liquid) {
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 40, 20),
      Paint()..color = const Color(0xff356d7d),
    );
  }
  ChartHoverPainter(
    elapsed: elapsed,
    color: const Color(0xff356d7d),
    viewport: const Rect.fromLTWH(-12, -12, 64, 44),
    liquid: liquid,
  ).paint(canvas, const Size(40, 20));
  final picture = recording.endRecording();
  final image = await picture.toImage(96, 64);
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  image.dispose();
  picture.dispose();
  elapsed.dispose();
  return bytes!.buffer.asUint8List();
}

Finder get _mark => find.byKey(const ValueKey('monitor-bar-0-primary'));
Finder get _tooltip => find.byKey(const ValueKey('monitor-chart-hover'));

Future<TestGesture> _enter(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  await mouse.moveTo(tester.getCenter(_mark));
  await tester.pump();
  return mouse;
}

void main() {
  test(
    'halo pixels use the segment hue outside its rectangle within plot gutters',
    () async {
      final pixels = await _pixels(const Duration(milliseconds: 380));
      var outside = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 96; x++) {
          final offset = (y * 96 + x) * 4;
          final alpha = pixels[offset + 3];
          if (alpha == 0) continue;
          expect(x, inInclusiveRange(8, 71));
          expect(y, inInclusiveRange(8, 51));
          expect(x < 20 || x >= 60 || y < 20 || y >= 40, isTrue);
          if (alpha > 80) {
            // Low-alpha antialiasing quantizes premultiplied channels before
            // rawStraightRgba expands them; four levels bound that rounding.
            expect(pixels[offset], closeTo(0x35, 4));
            expect(pixels[offset + 1], closeTo(0x6d, 4));
            expect(pixels[offset + 2], closeTo(0x7d, 4));
          }
          outside++;
        }
      }
      expect(outside, greaterThan(24));
    },
  );

  test('liquid actually changes interior pixels while leaving measured bounds fixed', () async {
    final first = await _pixels(
      const Duration(milliseconds: 100),
      liquid: true,
    );
    final next = await _pixels(const Duration(milliseconds: 600), liquid: true);
    var changed = 0;
    for (var y = 20; y < 40; y++) {
      for (var x = 20; x < 60; x++) {
        final offset = (y * 96 + x) * 4;
        expect(first[offset + 3], 255);
        expect(next[offset + 3], 255);
        if (first[offset] != next[offset] ||
            first[offset + 1] != next[offset + 1]) {
          changed++;
        }
      }
    }
    expect(changed, greaterThan(20));
  });

  testWidgets(
    'positive mark keeps moving after two seconds until pointer exit',
    (tester) async {
      await tester.pumpWidget(
        chartApp(
          const MonitorBarChart(
            bars: [ChartBar(label: '响应 10', value: 10)],
            unit: 's',
          ),
        ),
      );
      final original = tester.getRect(_mark);
      final mouse = await _enter(tester);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(_tooltip, findsOneWidget);
      expect(
        tester.binding.transientCallbackCount,
        greaterThan(0),
        reason: 'flow and the external halo continue while actually hovered',
      );
      expect(tester.getRect(_mark), original);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(_tooltip, findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
    },
  );

  testWidgets('same semantic row survives successful two-second value polls', (
    tester,
  ) async {
    final value = ValueNotifier(0);
    addTearDown(value.dispose);
    var builds = 0;
    await tester.pumpWidget(
      chartApp(
        ValueListenableBuilder<int>(
          valueListenable: value,
          builder: (_, next, _) {
            builds++;
            return MonitorBarChart(
              bars: [
                ChartBar(
                  label: '响应 10',
                  value: [10.0, 10.0, 11.234, 12.0][next],
                  detail: '响应 stable-10',
                ),
              ],
              unit: 's',
              maxValue: 20,
            );
          },
        ),
      ),
    );
    final mouse = await _enter(tester);
    final originalBuilds = builds;
    for (var next = 1; next <= 3; next++) {
      await tester.pump(const Duration(seconds: 2));
      expect(builds, originalBuilds + next - 1);
      value.value = next;
      await tester.pump();
      await tester.pump();
      expect(_tooltip, findsOneWidget);
      expect(find.textContaining('响应 stable-10'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    }
    expect(find.textContaining('响应 10：12.00 s'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'inspection formats measured values without rounding the samples',
    (tester) async {
      const bars = [
        ChartBar(label: '响应 10', value: 10, detail: '响应 id-123 · 共 7 项'),
        ChartBar(label: '比率', value: 1.23456789),
        ChartBar(label: '微量', value: .001),
        ChartBar(label: '零', value: 0),
        ChartBar(label: '未知', value: null),
        ChartBar(label: '取消', value: 8, cancelled: true),
      ];
      await tester.pumpWidget(
        chartApp(const MonitorBarChart(bars: bars, unit: 's')),
      );
      await tester.tap(find.text('查看数值'));
      await tester.pumpAndSettle();
      expect(find.textContaining('响应 10：10.00 s'), findsOneWidget);
      expect(find.textContaining('响应 id-123 · 共 7 项'), findsOneWidget);
      expect(find.text('比率：1.23 s'), findsOneWidget);
      expect(find.text('微量：<0.01 s'), findsOneWidget);
      expect(find.text('零：0.00 s'), findsOneWidget);
      expect(find.text('未知：未知'), findsOneWidget);
      expect(find.text('取消：取消'), findsOneWidget);
      expect(bars[1].value, 1.23456789);
      expect(bars[2].value, .001);
    },
  );

  testWidgets(
    'explicit row identity updates facts without replaying its bounce',
    (tester) async {
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      await tester.pumpWidget(
        chartApp(
          ValueListenableBuilder<int>(
            valueListenable: revision,
            builder: (_, value, _) => MonitorBarChart(
              inspectionIdentity: ('session-a', 'duration'),
              bars: [
                ChartBar(
                  identity: 'turn-10',
                  label: '响应 ${value + 10}',
                  value: value == 0 ? 10 : 11.234,
                  detail: '事实修订 $value',
                ),
              ],
              unit: 's',
              maxValue: 20,
            ),
          ),
        ),
      );
      final mouse = await _enter(tester);
      await tester.pump(const Duration(milliseconds: 2100));
      final before = tester.getRect(_mark);
      final painter =
          tester
                  .widget<CustomPaint>(
                    find
                        .ancestor(of: _mark, matching: find.byType(CustomPaint))
                        .first,
                  )
                  .foregroundPainter!
              as ChartHoverPainter;
      final clock = painter.elapsed;
      revision.value = 1;
      await tester.pump();
      await tester.pump();
      expect(_tooltip, findsOneWidget);
      expect(find.textContaining('响应 11：11.23 s\n事实修订 1'), findsOneWidget);
      expect(tester.getRect(_mark).width, before.width);
      final updated =
          tester
                  .widget<CustomPaint>(
                    find
                        .ancestor(of: _mark, matching: find.byType(CustomPaint))
                        .first,
                  )
                  .foregroundPainter!
              as ChartHoverPainter;
      expect(updated.elapsed, same(clock));
      expect(clock.value!.inMilliseconds, greaterThanOrEqualTo(2100));
      await mouse.removePointer();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('changing the session scope dismisses identical row facts', (
    tester,
  ) async {
    final scope = ValueNotifier('session-a');
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      chartApp(
        ValueListenableBuilder<String>(
          valueListenable: scope,
          builder: (_, identity, _) => MonitorBarChart(
            inspectionIdentity: identity,
            bars: const [
              ChartBar(identity: 'same-local-id', label: '回合 10', value: 10),
            ],
            unit: 's',
          ),
        ),
      ),
    );
    final mouse = await _enter(tester);
    await tester.pump(const Duration(milliseconds: 2100));
    expect(_tooltip, findsOneWidget);
    scope.value = 'session-b';
    await tester.pump();
    await tester.pump();
    expect(_tooltip, findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'true zero line point remains static but still exposes its fact',
    (tester) async {
      await tester.pumpWidget(
        chartApp(
          const MonitorBarChart(
            bars: [
              ChartBar(label: '零', value: 0),
              ChartBar(label: '四', value: 4),
            ],
            unit: 's',
            line: true,
          ),
        ),
      );
      final before = tester.getRect(_mark);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      // A zero point straddles the baseline; use its visible half in the plot.
      await mouse.moveTo(before.topLeft + const Offset(2, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2100));
      expect(tester.getRect(_mark), before);
      expect(find.text('零：0.00 s'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
      await tester.pumpAndSettle();
    },
  );
}
