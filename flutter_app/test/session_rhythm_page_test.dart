import 'package:codex_timezone/app/application.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/session_rhythm_charts.dart';
import 'package:codex_timezone/services/session_rhythm.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:timezone/timezone.dart' as tz;

import 'session_rhythm_application_test.dart' show RhythmAppBackend;
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
