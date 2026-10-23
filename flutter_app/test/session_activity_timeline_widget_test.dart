import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/session_timing_panel.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'session_activity_fixture.dart';

Widget timelineApp(Widget child, {bool dark = false}) => WidgetsApp(
  key: UniqueKey(),
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (context, child) => FTheme(
    data: dark ? darkLauncherTheme : lightLauncherTheme,
    child: FToaster(
      child: FTooltipGroup(
        child: DefaultTextStyle(
          style: TextStyle(
            fontSize: 14,
            fontFamily: 'Microsoft YaHei',
            color: (dark ? darkLauncherTheme : lightLauncherTheme)
                .colors
                .foreground,
          ),
          child: child!,
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) =>
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => child),
);

Widget panel({
  Map<String, dynamic>? timeline,
  Object? wait = 2500,
  Object? duration = 9000,
  Object? identity = 'turn-a',
}) => SessionTimingPanel(
  analysis: {
    'messageMs': 5000,
    'observedMs': 7000,
    'unclassifiedMs': 2000,
    'partial': false,
    'timeline': ?timeline,
  },
  firstTokenMs: wait,
  durationMs: duration,
  turnIdentity: identity,
);

void main() {
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      await (FontLoader('Microsoft YaHei')
            ..addFont(file.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
      await (FontLoader('packages/forui/Inter')..addFont(
            rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
          ))
          .load();
    }
  });

  testWidgets(
    'first model token wait honors explicit zero missing invalid and safe range',
    (tester) async {
      for (final value in [0, 2500, null, -1, 10000, 9007199254740992, 1.5]) {
        await tester.pumpWidget(
          timelineApp(SingleChildScrollView(child: panel(wait: value))),
        );
        await tester.pumpAndSettle();
        final waitText = tester
            .widget<Text>(
              find.byKey(const ValueKey('session-first-model-wait')),
            )
            .data!;
        final afterText = tester
            .widget<Text>(
              find.byKey(const ValueKey('session-after-first-duration')),
            )
            .data!;
        if (value == 0) {
          expect(waitText, contains('0.000 s'));
          expect(afterText, contains('9.000 s'));
        } else if (value == 2500) {
          expect(waitText, contains('2.500 s'));
          expect(afterText, contains('6.500 s'));
        } else {
          expect(waitText, contains('不可用'));
          expect(afterText, contains('不可用'));
        }
        expect(find.textContaining('tokens/s'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'old or malformed timeline leaves H2 totals independently usable',
    (tester) async {
      for (final timeline in [
        null,
        {'version': 99},
        timelineFixture()..['spanMs'] = -1,
      ]) {
        await tester.pumpWidget(
          timelineApp(SingleChildScrollView(child: panel(timeline: timeline))),
        );
        await tester.pumpAndSettle();
        expect(find.text('未归类时间：2.000 s'), findsOneWidget);
        expect(find.textContaining('时间线不可用'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('session-timeline-chart')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'missing total duration preserves valid raw first token but no subtraction',
    (tester) async {
      for (final c in <(int, String)>[(0, '0.000 s'), (2500, '2.500 s')]) {
        await tester.pumpWidget(
          timelineApp(
            SingleChildScrollView(child: panel(wait: c.$1, duration: null)),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('session-first-model-wait')),
              )
              .data,
          contains(c.$2),
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('session-after-first-duration')),
              )
              .data,
          contains('不可用'),
        );
      }
    },
  );

  testWidgets(
    'unlocatable rows retain each recorded epoch endpoint independently',
    (tester) async {
      for (final c in <(int?, int?, int?, String)>[
        (101000, 102000, 1000, 'missing_turn_bounds'),
        (99000, 102000, 3000, 'outside_bounds'),
        (106000, 101000, null, 'reversed'),
        (null, 106000, null, 'missing_start'),
        (101000, null, null, 'missing_end'),
      ]) {
        final fixture = timelineFixture(count: 1)
          ..['sourcePartial'] = true
          ..['coverageInterpretation'] = 'unavailable';
        if (c.$4 == 'missing_turn_bounds') {
          fixture['startEpochMs'] = null;
          fixture['endEpochMsExclusive'] = null;
          fixture['spanMs'] = null;
        }
        final row = fixture['items'][0] as Map;
        row['startedAtMs'] = c.$1;
        row['completedAtMs'] = c.$2;
        row['durationMs'] = c.$3;
        row['offsetStartMs'] = null;
        row['offsetEndMs'] = null;
        row['drawable'] = false;
        row['reasons'] = [c.$4];
        await tester.pumpWidget(
          timelineApp(SingleChildScrollView(child: panel(timeline: fixture))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('session-timeline-toggle')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            '记录开始：${c.$1?.toString() ?? '未知'} · 记录结束：${c.$2?.toString() ?? '未知'} · Unix epoch 毫秒',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('偏移 未知 → 未知'), findsOneWidget);
        expect(find.textContaining(' · 未绘制'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'collapsed timeline expands overlapping labelled bands and bounded safe list',
    (tester) async {
      final fixture = timelineFixture()
        ..['privateContent'] = 'PRIVATE prompt command answer';
      fixture['items'][0]['rawId'] = 'PRIVATE id';
      await tester.pumpWidget(
        timelineApp(SingleChildScrollView(child: panel(timeline: fixture))),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-timeline-chart')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('session-timeline-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-timeline-chart')),
        findsOneWidget,
      );
      for (final category in ['消息', '推理', '工具', '其他']) {
        expect(find.text('$category 项'), findsOneWidget);
      }
      expect(find.textContaining('消息 #1'), findsOneWidget);
      expect(find.textContaining('推理 #2'), findsOneWidget);
      expect(find.textContaining('边界不确定'), findsOneWidget);
      expect(find.textContaining('空白不代表等待'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('session-timeline-list')))
            .height,
        lessThanOrEqualTo(220),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial omitted rows explain absence without treating it as empty waiting',
    (tester) async {
      final fixture = timelineFixture(count: 200)
        ..['sourcePartial'] = true
        ..['coverageInterpretation'] = 'unavailable'
        ..['totalItems'] = 203
        ..['omittedItems'] = 3;
      await tester.pumpWidget(
        timelineApp(SingleChildScrollView(child: panel(timeline: fixture))),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('session-timeline-toggle')),
      );
      await tester.tap(find.byKey(const ValueKey('session-timeline-toggle')));
      await tester.pumpAndSettle();
      expect(find.textContaining('来源不完整'), findsOneWidget);
      expect(find.textContaining('省略 3 项'), findsOneWidget);
      expect(find.textContaining('不计算空白占比'), findsOneWidget);
      expect(find.textContaining('100%'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing axis keeps zero duration and unlocatable text facts', (
    tester,
  ) async {
    final fixture = timelineFixture(count: 1)
      ..['startEpochMs'] = null
      ..['endEpochMsExclusive'] = null
      ..['spanMs'] = null
      ..['coverageInterpretation'] = 'unavailable';
    final row = fixture['items'][0] as Map;
    row['completedAtMs'] = row['startedAtMs'];
    row['offsetStartMs'] = null;
    row['offsetEndMs'] = null;
    row['durationMs'] = 0;
    row['drawable'] = false;
    row['reasons'] = ['zero_duration', 'missing_turn_bounds'];
    await tester.pumpWidget(
      timelineApp(SingleChildScrollView(child: panel(timeline: fixture))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-timeline-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-timeline-chart')), findsNothing);
    expect(find.textContaining('偏移 未知 → 未知 · 项时长 0.000 s'), findsOneWidget);
    expect(find.textContaining('仅列出文字事实'), findsOneWidget);
    expect(find.textContaining('零时长（不绘制条形）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final width in [600.0, 760.0, 1280.0]) {
      testWidgets('populated timeline readable render $width dark=$dark', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1240);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final capture = GlobalKey();
        final fixture = timelineFixture(count: 200)
          ..['sourcePartial'] = true
          ..['coverageInterpretation'] = 'unavailable'
          ..['totalItems'] = 203
          ..['omittedItems'] = 3;
        // Exercise realistic 13-digit recorded timestamps at the narrow widths.
        const epochShift = 1792710000000;
        fixture['startEpochMs'] += epochShift;
        fixture['endEpochMsExclusive'] += epochShift;
        for (final row in fixture['items'] as List) {
          row['startedAtMs'] += epochShift;
          row['completedAtMs'] += epochShift;
        }
        fixture['items'][1]['drawable'] = false;
        fixture['items'][1]['reasons'] = [
          'missing_turn_bounds',
          'missing_start',
          'missing_end',
          'future_reason',
        ];
        await tester.pumpWidget(
          timelineApp(
            RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: dark ? const Color(0xff171717) : const Color(0xffffffff),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: panel(timeline: fixture),
                  ),
                ),
              ),
            ),
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('session-timeline-toggle')),
        );
        await tester.tap(find.byKey(const ValueKey('session-timeline-toggle')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('session-timeline-chart')),
          findsOneWidget,
        );
        expect(find.textContaining('其他无法核验'), findsOneWidget);
        expect(find.textContaining('future_reason'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../environment/stage-l1-finalfix-timeline-${dark ? 'dark' : 'light'}-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
