import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';

import 'benchmark_fixtures.dart';

import 'dart:async';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_projection.dart';
import 'package:codex_timezone/services/quota_history_store.dart';
import 'package:codex_timezone/state/quota_history_controller.dart';
import 'package:codex_timezone/app/quota_history_panel.dart';
import 'package:codex_timezone/app/quota_history_charts.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'support/quota_history_fixture.dart';
import 'monitor_charts_test.dart' show chartApp;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/account_sources_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';

void main() {
  testWidgets(
    'first failure with no known window stays visible on history timeline',
    (tester) async {
      final f = await HistoryFixture.create(
        records: [historyRecord(1, failed: true)],
      );
      addTearDown(f.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      expect(find.text('尚无已知窗口'), findsOneWidget);
      expect(find.textContaining('查询失败 · network'), findsOneWidget);
      expect(f.controller.projection!.sampleCount, 0);
      expect(f.controller.projection!.trendSegments, isEmpty);
      expect(f.service.queries, isEmpty);
    },
  );
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'history switches locally and retains one source manager and session/API selection',
    (tester) async {
      final f = await syntheticMultiFixture();
      final selected = f.metrics.selected;
      final benchmark = BenchmarkController(
        BenchmarkService(BenchmarkBackend()),
      );
      await benchmark.initialize();
      await benchmark.selectProtocol('responses');
      final scenario = benchmark.scenarioId;
      final history = await HistoryFixture.create(records: []);
      addTearDown(history.owner.dispose);
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: f.backend,
          sourceController: f.owner,
          historyController: history.controller,
          benchmarkController: benchmark,
          sessionMetricsController: f.metrics,
          desktop: SyntheticMultiDesktop(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
      await tester.pumpAndSettle();
      final queries = f.service.queries.length;
      expect(find.byKey(const ValueKey('accounts-history')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('accounts-history')));
      await tester.pumpAndSettle();

      expect(find.byType(AccountSourcesPanel), findsOneWidget);
      expect(find.text('当前登录段暂无观测'), findsOneWidget);
      expect(f.service.queries.length, queries);
      expect(f.metrics.selected, selected);
      tester
          .widget<MonitorChoice>(find.byKey(const ValueKey('history-range')))
          .onChanged('1');
      await tester.pumpAndSettle();
      expect(benchmark.protocol, 'responses');
      expect(benchmark.scenarioId, scenario);
      expect(f.metrics.selected, selected);
      expect(f.owner.pinnedId, 'profile-primary');
      await tester.tap(find.byKey(const ValueKey('accounts-current')));
      await tester.pumpAndSettle();
      expect(f.service.queries.length, queries);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'current empty segment never silently selects recorded previous segment',
    (tester) async {
      final f = await HistoryFixture.create(current: 'new-empty');
      addTearDown(f.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前登录段暂无观测'), findsOneWidget);
      expect(f.controller.filter!.segmentId, 'new-empty');
      final selector = tester.widget<MonitorChoice>(
        find.byKey(const ValueKey('history-segment')),
      );
      expect(selector.items.values, contains('old-segment'));
      selector.onChanged('old-segment');
      await tester.pumpAndSettle();
      expect(f.controller.filter!.segmentId, 'old-segment');
      expect(f.controller.projection!.sampleCount, 1);
      expect(f.service.queries, isEmpty);
    },
  );
  testWidgets(
    'local filters isolate tuple and source without pinning or querying',
    (tester) async {
      final f = await HistoryFixture.create();
      addTearDown(f.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      expect(f.controller.projection!.sampleCount, 19);
      expect(find.text('51.88%'), findsOneWidget);
      tester
          .widget<MonitorChoice>(find.byKey(const ValueKey('history-range')))
          .onChanged('1');
      await tester.pumpAndSettle();
      expect(
        f.controller.filter!.toUtc
            .difference(f.controller.filter!.fromUtc)
            .inHours,
        24,
      );
      tester
          .widget<MonitorChoice>(find.byKey(const ValueKey('history-window')))
          .onChanged('secondary:10080');
      await tester.pumpAndSettle();
      expect(f.controller.projection!.minimumRemaining, 40);
      f.owner.select('profile-second');
      await tester.pumpAndSettle();
      expect(f.controller.projection!.sampleCount, 0);
      expect(f.owner.pinnedId, 'profile-primary');
      expect(f.service.queries, isEmpty);
      await f.owner.remove('profile-primary');
      await f.owner.remove('profile-second');
      await tester.pumpAndSettle();
      expect(find.text('添加来源后可查看额度历史'), findsOneWidget);
    },
  );
  testWidgets(
    'storage gaps and write failures are visible beside readable old samples',
    (tester) async {
      final f = await HistoryFixture.create(storageGaps: true);
      addTearDown(f.dispose);
      f.owner.historyError = '历史保存失败。';
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      expect(find.text('历史保存失败。'), findsOneWidget);
      expect(find.textContaining('历史文件有缺失'), findsOneWidget);
      expect(find.byType(QuotaHistoryTrendChart), findsOneWidget);
    },
  );
  testWidgets('no sources and local read error retain safe empty states', (
    tester,
  ) async {
    final f = await HistoryFixture.create(emptyOwner: true);
    addTearDown(f.dispose);
    await tester.pumpWidget(
      chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加来源后可查看额度历史'), findsOneWidget);
    final broken = await HistoryFixture.create(readError: true);
    addTearDown(broken.dispose);
    await tester.pumpWidget(
      chartApp(
        QuotaHistoryPanel(controller: broken.controller, owner: broken.owner),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('历史读取失败'), findsOneWidget);
  });
  testWidgets(
    'event selection highlights exact observed interval and timeline stays lazy',
    (tester) async {
      final f = await HistoryFixture.create(
        records: [
          for (var i = 0; i < 1500; i++)
            historyRecord(
              i,
              minutesAgo: 3000 - i * 2,
              used: (i % 80).toDouble(),
            ),
        ],
      );
      addTearDown(f.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('history-timeline-list'));
      await tester.ensureVisible(list);
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('history-event-0'));
      await tester.tap(first);
      await tester.pumpAndSettle();
      final chart = tester.widget<QuotaHistoryTrendChart>(
        find.byType(QuotaHistoryTrendChart),
      );
      expect(chart.highlightedInterval, isNotNull);
      final latest = f.controller.projection!.events.last;
      expect(chart.highlightedInterval, (latest.fromUtc, latest.toUtc));
      expect(find.byKey(const ValueKey('history-event-1000')), findsNothing);
    },
  );
  testWidgets(
    'hover persists and keyboard exposes precise readout without dialog',
    (tester) async {
      final f = await HistoryFixture.create(
        records: [historyRecord(1, used: 48.1234)],
      );
      addTearDown(f.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: f.controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      final chart = find.byType(QuotaHistoryTrendChart);
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getTopLeft(chart) + const Offset(100, 60));
      await tester.pump(const Duration(seconds: 10));
      f.owner.rename('profile-primary', '更名');
      await tester.pumpAndSettle();
      expect(find.textContaining('已用 48.12%'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(find.textContaining('已用 48.12%'), findsNothing);
      final focus = find
          .descendant(of: chart, matching: find.byType(Focus))
          .first;
      Focus.of(
        tester.element(
          find
              .descendant(of: focus, matching: find.byType(LayoutBuilder))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.textContaining('已用 48.12%'), findsOneWidget);
      expect(find.text('查看数值'), findsNothing);
      await mouse.removePointer();
    },
  );
  testWidgets(
    'completed observations refresh open history range locally without extra query',
    (tester) async {
      var now = historyNow;
      final service = _ClockSources(() => now);
      final f = await HistoryFixture.create(
        records: [],
        now: () => now,
        sourceService: service,
      );
      addTearDown(f.dispose);
      final store = QuotaHistoryStore.memory(now: () => now);
      f.owner.historySink = store;
      final controller = QuotaHistoryController(
        store,
        projector: (result, filter) => projectQuotaHistory(
          result.records,
          filter,
          toDisplayTime: (t) => t,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: controller, owner: f.owner)),
      );
      await tester.pumpAndSettle();
      now = now.add(const Duration(minutes: 3));
      await f.owner.refresh('profile-primary');
      await tester.pumpAndSettle();
      expect(service.queries, ['profile-primary']);
      expect(controller.filter!.toUtc, now);
      expect(controller.projection!.sampleCount, 1);
      expect(controller.projection!.latestPoint!.usedPercent, 42.25);
      expect(f.owner.pinnedId, 'profile-primary');
    },
  );
  testWidgets(
    'switching sources clears old projection before pending read completes',
    (tester) async {
      final f = await HistoryFixture.create();
      addTearDown(f.dispose);
      final pending = Completer<QuotaHistoryReadResult>();
      final controller = QuotaHistoryController(
        QuotaHistoryStore.memory(),
        read: (filter) => filter.sourceId == 'profile-primary'
            ? pending.future
            : Future.value(QuotaHistoryReadResult(records: [])),
        projector: (result, filter) => projectQuotaHistory(
          result.records,
          filter,
          toDisplayTime: (t) => t,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        chartApp(QuotaHistoryPanel(controller: controller, owner: f.owner)),
      );
      await tester.pump();
      f.owner.select('profile-second');
      await tester.pumpAndSettle();
      pending.complete(QuotaHistoryReadResult(records: f.records));
      await tester.pumpAndSettle();
      expect(controller.filter!.sourceId, 'profile-second');
      expect(controller.projection!.sampleCount, 0);
      expect(find.text('51.88%'), findsNothing);
      expect(f.owner.pinnedId, 'profile-primary');
      expect(f.service.queries, isEmpty);
    },
  );
  testWidgets(
    'enlarged heatmap date and offset rows reserve two readable lines',
    (tester) async {
      final f = await HistoryFixture.create();
      addTearDown(f.dispose);
      await tester.pumpWidget(
        chartApp(
          QuotaHistoryPanel(controller: f.controller, owner: f.owner),
          scale: 1.25,
        ),
      );
      await tester.pumpAndSettle();
      final map = find.byType(QuotaHistoryHeatmap);
      final paint = find.descendant(
        of: map,
        matching: find.byKey(const ValueKey('小时观测-canvas')),
      );
      expect(tester.getSize(paint).height, greaterThanOrEqualTo(8 * 42 + 26));
    },
  );
  testWidgets(
    'repeated DST hours stay distinct and failed zero has contrasting marker',
    (tester) async {
      final cells = [
        for (final offset in [-240, -300])
          QuotaHistoryHourCell(
            localDate: '2026-11-01',
            localHour: 1,
            utcOffsetMinutes: offset,
            fromUtc: DateTime.utc(2026, 11, 1, offset == -240 ? 5 : 6),
            toUtc: DateTime.utc(2026, 11, 1, offset == -240 ? 6 : 7),
            sampleCount: 1,
            failureCount: offset == -240 ? 1 : 0,
            hasGap: false,
            observedRemaining: offset == -240 ? 0 : 75,
          ),
      ];
      await tester.pumpWidget(chartApp(QuotaHistoryHeatmap(cells: cells)));
      final map = find.byType(QuotaHistoryHeatmap);
      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: map,
              matching: find.byKey(const ValueKey('小时观测-canvas')),
            ),
          )
          .painter!;
      expect(
        (Canvas c) => painter.paint(c, const Size(600, 120)),
        paintsExactlyCountTimes(#drawLine, 2),
      );
      final focus = find
          .descendant(of: map, matching: find.byType(Focus))
          .first;
      Focus.of(
        tester.element(
          find
              .descendant(of: focus, matching: find.byType(LayoutBuilder))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.textContaining('UTC-05:00 · 观测剩余 75.00%'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.textContaining('UTC-04:00 · 观测剩余 0.00%'), findsOneWidget);
      expect(find.textContaining('仅 1 次观测 · 查询失败 1 次'), findsOneWidget);
    },
  );
  test('dense gap columns forbid internal and neighboring connectors', () {
    QuotaHistoryPoint point(int minute) => QuotaHistoryPoint(
      attemptId: 'p:$minute',
      completedAtUtc: historyNow.subtract(Duration(minutes: minute)),
      usedPercent: 50,
      spanId: minute,
      timeQuality: UsageObservationTimeQuality.nativeCompletion,
      expectedIntervalSec: 120,
    );
    final projection = QuotaHistoryProjection(
      requiresSelection: false,
      trendSegments: [
        QuotaHistoryTrendSegment(
          column: 0,
          points: [point(8)],
          spanCount: 1,
          hasInternalGaps: false,
          connectToPrevious: false,
        ),
        QuotaHistoryTrendSegment(
          column: 1,
          points: [point(6), point(4)],
          spanCount: 3000,
          hasInternalGaps: true,
          connectToPrevious: false,
        ),
        QuotaHistoryTrendSegment(
          column: 2,
          points: [point(2)],
          spanCount: 1,
          hasInternalGaps: false,
          connectToPrevious: false,
        ),
        QuotaHistoryTrendSegment(
          column: 3,
          points: [point(1)],
          spanCount: 1,
          hasInternalGaps: false,
          connectToPrevious: true,
        ),
      ],
    );
    final palette = DashboardPalette.forBrightness(Brightness.light);
    final painter = QuotaHistoryTrendPainter(
      projection: projection,
      filter: QuotaHistoryFilter(
        sourceId: 'profile-primary',
        fromUtc: historyNow.subtract(const Duration(hours: 1)),
        toUtc: historyNow,
      ),
      palette: palette,
      style: const TextStyle(fontSize: 12),
    );
    final canvas = TestRecordingCanvas();
    painter.paint(canvas, const Size(600, 220));
    expect(
      (Canvas c) => painter.paint(c, const Size(600, 220)),
      paintsExactlyCountTimes(#drawLine, 7),
    );
    expect(
      (Canvas c) => painter.paint(c, const Size(600, 220)),
      paintsExactlyCountTimes(#drawCircle, 5),
    );
  });
}

class _ClockSources extends SyntheticMultiSources {
  _ClockSources(this.now);
  final DateTime Function() now;
  @override
  Future<AccountUsage> query(
    String id, {
    String desktopPath = '',
    bool details = false,
  }) async {
    queries.add(id);
    return AccountUsage(
      email: 'same-synthetic-identity@example.test',
      plan: 'synthetic',
      identityKey: 'same-synthetic-identity',
      fetchedAt: now(),
      buckets: [
        UsageBucket(
          label: 'Codex',
          windows: [
            UsageWindow(
              role: UsageWindowRole.primary,
              durationMinutes: 300,
              usedPercent: 42.25,
            ),
          ],
        ),
      ],
    );
  }
}
