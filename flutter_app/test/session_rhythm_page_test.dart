import 'package:codex_timezone/app/application.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/session_rhythm_charts.dart';
import 'package:codex_timezone/app/session_rhythm_panel.dart';
import 'package:codex_timezone/services/session_rhythm.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:timezone/timezone.dart' as tz;

import 'session_rhythm_application_test.dart' show RhythmAppBackend;
import 'session_rhythm_controller_test.dart' show HeldReadStore;
import 'monitor_charts_test.dart' show chartApp;
import 'account_usage_page_test.dart' show PageUsage;
import 'support/session_rhythm_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

class UnreadableRhythmStore extends SessionRhythmStore {
  UnreadableRhythmStore() : super.memory();
  @override
  Future<RhythmCache> read() async =>
      throw StateError('synthetic damaged cache');
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  for (final restoredCount in [7, 8]) {
    testWidgets(
      'source Add waits cache readiness and then honors restored $restoredCount/8 capacity',
      (tester) async {
        final store = HeldReadStore(), backend = RhythmAppBackend();
        final cached = RhythmCache(
          sources: rhythmFixtureSources.take(restoredCount).toList(),
        );
        await store.write(cached);
        final gate = store.holdNextRead();
        final rhythm = SessionRhythmController(
          backend: backend,
          store: store,
          now: () => rhythmFixtureNow,
        );
        final initialized = rhythm.initialize();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
          rhythm.dispose();
        });
        await store.entered.future;
        expect(rhythm.cacheReady, false);
        const candidate = RhythmSource(
          path: 'C:/synthetic/ninth.jsonl',
          sessionId: 'ninth',
          title: 'Ninth',
        );
        await tester.pumpWidget(
          chartApp(
            SessionRhythmPanel(
              controller: rhythm,
              available: [
                {
                  'path': candidate.path,
                  'id': candidate.sessionId,
                  'title': candidate.title,
                },
              ],
              onList: () {},
              onOpen: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('rhythm-sources')));
        await tester.pumpAndSettle();
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('rhythm-source-choice')),
            )
            .onChanged(candidate.key);
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey('rhythm-add'));
        final disabledWhileRestoring =
            tester.widget<FButton>(add).onPress == null;
        expect(find.text('来源 0/8'), findsOneWidget);
        await tester.ensureVisible(add);
        if (disabledWhileRestoring) await tester.tap(add);
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        expect(backend.calls, isEmpty);
        gate.complete();
        await tester.pump();
        await initialized;
        await tester.pumpAndSettle();
        expect(rhythm.cacheReady, true);
        expect(find.text('来源 $restoredCount/8'), findsOneWidget);
        if (restoredCount == 8) {
          expect(tester.widget<FButton>(add).onPress, isNull);
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pump(const Duration(milliseconds: 200));
        } else {
          expect(tester.widget<FButton>(add).onPress, isNotNull);
        }
        expect(tester.takeException(), isNull);
        expect(backend.calls, isEmpty);
        expect(store.writes, 0);
        expect((await store.read()).toJson(), cached.toJson());
        await tester.pumpWidget(const SizedBox());
        await rhythm.shutdown();
        expect(disabledWhileRestoring, true);
      },
    );
  }
  for (final overlapping in [false, true]) {
    testWidgets(
      'lane click selects activity owner and opens its turn, overlap=$overlapping',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = RhythmAppBackend(), store = SessionRhythmStore.memory();
        final source = rhythmFixtureSources.first;
        int time(int hour, int minute) =>
            DateTime.utc(2026, 10, 25, hour, minute).millisecondsSinceEpoch;
        RhythmTurn turn(
          String id,
          int order,
          int fromHour,
          int fromMinute,
          int toHour,
          int toMinute,
        ) => RhythmTurn(
          sourceKey: source.key,
          order: order,
          turnId: id,
          status: RhythmStatus.completed,
          startedAtMs: time(fromHour, fromMinute),
          completedAtMs: time(toHour, toMinute),
          durationMs: time(toHour, toMinute) - time(fromHour, fromMinute),
          activityAvailable: true,
          activityIntervals: [
            RhythmInterval(time(fromHour, fromMinute), time(toHour, toMinute)),
          ],
        );
        final a = turn('turn-A', 1, 9, 58, 9, 59),
            b = turn('turn-B', 2, 10, 0, 10, 20);
        final unknown = RhythmTurn(
          sourceKey: source.key,
          order: 4,
          turnId: 'turn-undated',
          status: RhythmStatus.unknown,
          partial: true,
        );
        // Reversed cache order ensures overlap choice is independent of list ordering.
        await store.write(
          RhythmCache(
            sources: [source],
            turns: [
              if (overlapping) turn('turn-C', 3, 10, 1, 10, 5),
              a,
              b,
              unknown,
            ],
          ),
        );
        final rhythm = SessionRhythmController(
          backend: backend,
          store: store,
          now: () => DateTime.utc(2026, 10, 25, 11),
        );
        final metrics = SessionMetricsController(backend);
        await tester.pumpWidget(
          LauncherApplication(
            preview: true,
            backend: backend,
            rhythmController: rhythm,
            sessionMetricsController: metrics,
          ),
        );
        await tester.pumpAndSettle();
        rhythm.setRange(RhythmRange.hours24);
        await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('会话节奏'));
        await tester.pumpAndSettle();
        final lane = find.descendant(
          of: find.byKey(const ValueKey('rhythm-lanes')),
          matching: find.byType(RhythmInspection),
        );
        final plot = find
            .descendant(of: lane, matching: find.byType(CustomPaint))
            .first;
        await tester.ensureVisible(plot);
        await tester.pumpAndSettle();
        final size = tester.getSize(plot);
        final p = rhythm.projection;
        final x =
            100 +
            (time(10, 2) - p.fromUtc.millisecondsSinceEpoch) /
                (p.toUtc.millisecondsSinceEpoch -
                    p.fromUtc.millisecondsSinceEpoch) *
                (size.width - 100);
        final point = tester.getTopLeft(plot) + Offset(x, 36);
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        final summary = find.byKey(const ValueKey('rhythm-turn-summary'));
        expect(summary, findsOneWidget);
        expect(
          tester
              .widgetList<Text>(
                find.descendant(of: summary, matching: find.byType(Text)),
              )
              .first
              .data,
          '${source.title} · turn-B',
          reason: '10:02 belongs to B activity, not the closer A completion; overlap uses lowest stable order',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: summary,
            matching: find.text('${source.title} · turn-undated'),
          ),
          findsOneWidget,
          reason: 'interval-less facts remain accessible by keyboard',
        );
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('rhythm-open-source')),
        );
        await tester.tap(find.byKey(const ValueKey('rhythm-open-source')));
        await tester.pumpAndSettle();
        expect(find.textContaining('原回合 turn-B'), findsOneWidget);
        expect(metrics.selected, source.path);
        expect(
          find.byKey(const ValueKey('notice-analysis-context')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'explicit sources cap at eight, charts stay isolated and source opens historical context',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = RhythmAppBackend(), store = SessionRhythmStore.memory();
      await store.write(rhythmFixtureCache(sources: 8));
      final rhythm = SessionRhythmController(
        backend: backend,
        store: store,
        now: () => rhythmFixtureNow,
      );
      final metrics = SessionMetricsController(backend), usage = PageUsage();
      await tester.pumpWidget(
        LauncherApplication(
          preview: true,
          backend: backend,
          usageService: usage,
          rhythmController: rhythm,
          sessionMetricsController: metrics,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话节奏'));
      await tester.pumpAndSettle();
      for (final key in [
        'rhythm-heatmap',
        'rhythm-lanes',
        'rhythm-distribution',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.textContaining('时间未知 1'), findsOneWidget);
      expect(find.textContaining('部分 9'), findsOneWidget);
      expect(
        backend.calls.where((c) => c['command'] == 'session_metrics'),
        isEmpty,
      );
      final points = rhythm.projection.distribution.pointsMs;
      final duplicate = [
        for (var i = 1; i < points.length; i++)
          if (points[i] == points[i - 1] && i % 3 != (i - 1) % 3) i,
      ].first;
      final distribution = tester.widget<RhythmInspection>(
        find.byType(RhythmInspection).at(2),
      );
      final x =
          12 +
          points[duplicate] / rhythm.projection.distribution.maximumMs! * 976;
      expect(
        distribution.hit(
          Offset(x, 54 + (duplicate % 3) * 4),
          const Size(1000, 84),
        ),
        duplicate,
        reason: 'overlapping durations remain independently hittable at their drawn vertical offset',
      );
      distribution.onSelect(duplicate - 1);
      await tester.pumpAndSettle();
      final previousSummary = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('rhythm-turn-summary')),
              matching: find.byType(Text),
            ),
          )
          .first
          .data;
      distribution.onSelect(duplicate);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('rhythm-turn-summary')),
                matching: find.byType(Text),
              ),
            )
            .first
            .data,
        isNot(previousSummary),
      );
      final range = tester
          .widgetList<MonitorChoice>(find.byType(MonitorChoice))
          .firstWhere((w) => w.label == '统计范围');
      range.onChanged('days30');
      await tester.pumpAndSettle();
      expect(rhythm.range, RhythmRange.days30);
      range.onChanged('hours24');
      await tester.pumpAndSettle();
      expect(rhythm.range, RhythmRange.hours24);
      final partialDay = tester.widget<RhythmInspection>(
        find.byType(RhythmInspection).first,
      );
      expect(
        partialDay.hit(const Offset(90, 32), const Size(1000, 80)),
        isNull,
        reason:
            'first partial civil day must not shift noon into midnight column',
      );
      range.onChanged('days7');
      await tester.pumpAndSettle();
      final inspections = find.byType(RhythmInspection);
      final heat = tester.widget<RhythmInspection>(inspections.at(0));
      heat.onSelect(rhythm.projection.hours.length - 2);
      await tester.pumpAndSettle();
      expect(rhythm.selectedHour, isNotNull);
      expect(find.byKey(const ValueKey('rhythm-clear-hour')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rhythm-clear-hour')));
      await tester.pumpAndSettle();
      expect(rhythm.selectedHour, isNull);
      final plot = find
          .descendant(of: inspections.at(0), matching: find.byType(CustomPaint))
          .first;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getTopLeft(plot) + const Offset(110, 32));
      await tester.pump();
      final readout = tester
          .widget<Text>(find.byKey(const ValueKey('rhythm-hour-readout')))
          .data;
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('rhythm-hour-readout')))
            .data,
        readout,
      );
      await tester.tapAt(tester.getTopLeft(plot) + const Offset(110, 32));
      await tester.pump();
      final first = rhythm.selectedHour!.key;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(rhythm.selectedHour!.key, isNot(first));
      rhythm.clearHour();
      await tester.pumpAndSettle();
      expect(usage.calls, 0);
      expect(metrics.selected, isNull);
      expect(metrics.alertSerial, 0);
      expect(
        backend.calls.where((c) => c['command'] == 'session_metrics'),
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('rhythm-sources')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rhythm-list')));
      await tester.pumpAndSettle();
      final choice = tester.widget<MonitorChoice>(
        find.byKey(const ValueKey('rhythm-source-choice')),
      );
      choice.onChanged(rhythmFixtureSources.first.key);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FButton>(find.byKey(const ValueKey('rhythm-add')))
            .onPress,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('rhythm-remove-rhythm-7')),
      );
      await tester.tap(find.byKey(const ValueKey('rhythm-remove-rhythm-7')));
      await tester.pumpAndSettle();
      expect(rhythm.sources.length, 7);
      choice.onChanged(rhythmFixtureSources.last.key);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('rhythm-add')));
      await tester.tap(find.byKey(const ValueKey('rhythm-add')));
      await tester.pumpAndSettle();
      expect(rhythm.sources.length, 8);
      expect(metrics.selected, isNull);
      expect(usage.calls, 0);
      expect(metrics.alertSerial, 0);
      await tester.ensureVisible(find.byKey(const ValueKey('rhythm-sources')));
      await tester.tap(find.byKey(const ValueKey('rhythm-sources')));
      await tester.pumpAndSettle();
      tester
          .widget<RhythmInspection>(find.byType(RhythmInspection).at(1))
          .onSelect(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rhythm-turn-summary')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('rhythm-open-source')),
      );
      await tester.tap(find.byKey(const ValueKey('rhythm-open-source')));
      await tester.pumpAndSettle();
      expect(find.text('历史来源分析 · 缓存回合上下文'), findsOneWidget);
      expect(find.textContaining('历史回合五图不可回放'), findsOneWidget);
      expect(metrics.selected, rhythmFixtureSources.first.path);
      expect(
        find.byKey(const ValueKey('notice-analysis-context')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('analysis-quota-card')), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'fallback day keeps both repeated hours independently selectable',
    (tester) async {
      final backend = RhythmAppBackend(), store = SessionRhythmStore.memory();
      await store.write(RhythmCache(sources: [rhythmFixtureSources.first]));
      final location = tz.getLocation('America/New_York');
      final rhythm = SessionRhythmController(
        backend: backend,
        store: store,
        now: () => DateTime.utc(2026, 11, 1, 10),
        calendar: RhythmCalendar(
          toLocal: (u) => tz.TZDateTime.from(u, location),
          localDate: (y, m, d) => tz.TZDateTime(location, y, m, d),
        ),
      );
      await tester.pumpWidget(
        LauncherApplication(
          preview: true,
          backend: backend,
          rhythmController: rhythm,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话节奏'));
      await tester.pumpAndSettle();
      final repeated = rhythm.projection.hours
          .where((h) => h.localStart.day == 1 && h.localStart.hour == 1)
          .toList();
      expect(repeated.length, 2);
      expect(repeated[0].label, isNot(repeated[1].label));
      final heat = tester.widget<RhythmInspection>(
        find.byType(RhythmInspection).first,
      );
      heat.onSelect(rhythm.projection.hours.indexOf(repeated[0]));
      await tester.pumpAndSettle();
      expect(rhythm.selectedHour!.key, repeated[0].key);
      expect(find.text('小时筛选：${repeated[0].label}'), findsOneWidget);
      rhythm.clearHour();
      await tester.pumpAndSettle();
      tester
          .widget<RhythmInspection>(find.byType(RhythmInspection).first)
          .onSelect(
            rhythm.projection.hours.indexWhere((h) => h.key == repeated[1].key),
          );
      await tester.pumpAndSettle();
      expect(rhythm.selectedHour!.key, repeated[1].key);
      expect(find.text('小时筛选：${repeated[1].label}'), findsOneWidget);
      expect(
        backend.calls.where((c) => c['command'] == 'session_metrics'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('damaged cache is visible and does not initiate a source read', (
    tester,
  ) async {
    final backend = RhythmAppBackend();
    final rhythm = SessionRhythmController(
      backend: backend,
      store: UnreadableRhythmStore(),
    );
    await tester.pumpWidget(
      LauncherApplication(
        preview: true,
        backend: backend,
        rhythmController: rhythm,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('会话节奏'));
    await tester.pumpAndSettle();
    expect(find.textContaining('缓存错误：'), findsOneWidget);
    expect(
      backend.calls.where((c) => c['command'] == 'session_metrics'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('analysis exposes isolated rhythm and preserves current view', (
    tester,
  ) async {
    await tester.pumpWidget(const LauncherApplication(preview: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analysis-quota-card')), findsOneWidget);
    expect(find.text('会话节奏'), findsOneWidget);
    await tester.tap(find.text('会话节奏'));
    await tester.pumpAndSettle();
    expect(find.text('明确加入来源后显示会话节奏'), findsOneWidget);
    expect(find.byKey(const ValueKey('analysis-quota-card')), findsNothing);
    await tester.tap(find.text('当前会话'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analysis-quota-card')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
