import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/monitor_presentation.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;
import 'session_activity_fixture.dart';
import 'session_measurement_quality_test.dart' show qualityFixture;
import 'sidebar_workspace_render_test.dart' show NoRenderDesktop;

const overviewPath = r'C:\synthetic-only\chart-overview.jsonl';
const overviewGraphKeys = [
  'account-quota-chart',
  'session-recent-chart',
  'session-configuration-chart',
  'session-activity-chart',
  'session-response-chart',
];

/// Content-free in-memory data. No native backend, filesystem session or API.
Map<String, dynamic> overviewFixture({bool partial = false}) {
  final value = qualityFixture();
  value['sourceInfo'] = {
    'id': 'overview-synthetic-session',
    'path': overviewPath,
    'cwd': r'C:\synthetic-only',
    'title': '合成图表验收会话',
  };
  value['current'] = {'turnId': 'current-cancelled', 'status': 'cancelled'};
  value['logEpoch'] = 1;
  value['terminals'] = [
    for (var i = 0; i < 20; i++)
      {
        'turnId': 'terminal-$i',
        'status': i % 5 == 0 ? 'cancelled' : 'completed',
        'durationMs': i % 5 == 0 ? null : 1000 + i * 700,
      },
  ];
  value['measurement'] = {
    ...value['measurement'] as Map<String, dynamic>,
    'sessionId': 'overview-synthetic-session',
  };
  value['verifiedGroups'] = [
    for (var i = 0; i < 3; i++)
      {
        'sessionId': 'overview-synthetic-session',
        'model': 'synthetic-model-${i + 1}',
        'effort': i == 0 ? 'high' : 'medium',
        'serviceTier': i == 2 ? 'priority' : 'default',
        'turnCount': 2 + i,
        'outputTokens': 100 + i * 100,
        'durationMs': 10000 + i * 5000,
        'tokensPerSecond': (100 + i * 100) / (10 + i * 5),
      },
  ];
  final timeline = timelineFixture();
  timeline['sourcePartial'] = partial;
  timeline['coverageInterpretation'] = partial ? 'unavailable' : 'approximate';
  timeline['items'] = [
    for (final (ordinal, category, start, end) in [
      (1, 'message', 1000, 4000),
      (2, 'reasoning', 2000, 5000),
      (3, 'tool', 5000, 8000),
      (4, 'other', 8500, 9000),
    ])
      {
        'ordinal': ordinal,
        'category': category,
        'startedAtMs': 100000 + start,
        'completedAtMs': 100000 + end,
        'offsetStartMs': start,
        'offsetEndMs': end,
        'durationMs': end - start,
        'drawable': true,
        'reasons': <String>[],
      },
  ];
  value['last'] = {
    'turnId': 'recent-completed',
    'outputTokens': 100,
    'reasoningTokens': 20,
    'durationMs': 10000,
    'firstTokenMs': 1000,
    'tokensPerSecond': 10.0,
    'verifiedTokensPerSecond': 10.0,
    'quality': {'status': 'verified', 'reasons': <String>[]},
    'analysis': {
      'timeline': timeline,
      'partial': partial,
      'coverageValid': true,
      'observedMs': 7500,
      'unclassifiedMs': 2500,
      'overlapMs': 2000,
      'messageMs': 3000,
      'reasoningMs': 3000,
      'toolMs': 3000,
      'otherMs': 500,
      'responseCount': 6,
      'responseOutputTokens': 100,
      'usageMatchesTurn': true,
      'recentResponses': [
        for (var i = 0; i < 6; i++)
          {
            'responseId': 'response-$i',
            'outputTokens': [10, 15, 20, 25, 15, 15][i],
            'reasoningTokens': [1, 2, 4, 5, 3, 5][i],
          },
      ],
    },
  };
  return value;
}

class OverviewBackend extends PageBackend {
  Map<String, dynamic> value = overviewFixture();
  int sessionCalls = 0;
  String? readFailure;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command != 'session_metrics') return super.call(command, payload);
    sessionCalls++;
    if (payload['action'] == 'list') {
      return {
        'sessions': [value['sourceInfo']],
      };
    }
    if (readFailure != null) throw StateError(readFailure!);
    return value;
  }
}

Widget overviewApplication(
  OverviewBackend backend,
  PageUsage usage, {
  String appearance = 'light',
}) => LauncherApplication(
  backend: backend,
  usageService: usage,
  desktop: NoRenderDesktop(),
  networkFactory: () => NetworkController(preview: true),
  initialAppearance: appearance,
);

Future<void> overviewTap(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> populateOverview(WidgetTester tester) async {
  await overviewTap(tester, 'workspace-accounts');
  await overviewTap(tester, 'query-account-usage');
  await overviewTap(tester, 'workspace-analysis');
  await overviewTap(tester, 'session-refresh');
  tester
      .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
      .controller
      .select(overviewPath);
  await tester.pumpAndSettle();
}

MonitorBarChart graph(WidgetTester tester, String key) =>
    tester.widget<MonitorBarChart>(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(MonitorBarChart),
          )
          .first,
    );

MonitorCategoryDotChart configurationGraph(WidgetTester tester) =>
    tester.widget<MonitorCategoryDotChart>(
      find.descendant(
        of: find.byKey(const ValueKey('session-configuration-chart')),
        matching: find.byType(MonitorCategoryDotChart),
      ),
    );

Future<void> chooseOverview(
  WidgetTester tester,
  String key,
  String value,
) async {
  tester.widget<MonitorChoice>(find.byKey(ValueKey(key))).onChanged(value);
  // Display-only setState is synchronous. Do not advance the unrelated 2s
  // collector timer while asserting that a selector itself performs no read.
  await tester.pump();
}

void main() {
  testWidgets(
    'configuration uses aggregate category dots without sample clouds',
    (tester) async {
      await tester.pumpWidget(
        overviewApplication(OverviewBackend(), PageUsage()),
      );
      await tester.pumpAndSettle();
      await populateOverview(tester);
      final configuration = find.byKey(
        const ValueKey('session-configuration-chart'),
      );
      expect(
        find.descendant(
          of: configuration,
          matching: find.byKey(const ValueKey('monitor-dot-0')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: configuration,
          matching: find.byKey(const ValueKey('monitor-dot-1')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: configuration,
          matching: find.byKey(const ValueKey('monitor-dot-2')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: configuration,
          matching: find.byKey(const ValueKey('monitor-dot-3')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: configuration,
          matching: find.byType(MonitorBarChart),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('session read failure dismisses open long chart details', (
    tester,
  ) async {
    final backend = OverviewBackend();
    backend.value['terminals'][0]['turnId'] = List.filled(
      80,
      'terminal-0',
    ).join('\n');
    await tester.pumpWidget(overviewApplication(backend, PageUsage()));
    await tester.pumpAndSettle();
    await populateOverview(tester);
    final controller = tester
        .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
        .controller;
    final inspect = find.descendant(
      of: find.byKey(const ValueKey('session-recent-chart')),
      matching: find.text('查看数值'),
    );
    await tester.ensureVisible(inspect);
    await tester.tap(inspect);
    await tester.pumpAndSettle();
    expect(find.text('图表数值'), findsOneWidget);
    expect(find.textContaining('回合 terminal-0'), findsOneWidget);

    backend.readFailure = 'synthetic read failure';
    await controller.poll();
    await tester.pumpAndSettle();

    expect(controller.data, isNull);
    expect(find.text('图表数值'), findsNothing);
    expect(find.textContaining('回合 terminal-0'), findsNothing);
    expect(find.textContaining('读取失败'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'five direct graphs keep strict facts and distinguish recent completed from cancelled',
    (tester) async {
      final backend = OverviewBackend();
      await tester.pumpWidget(overviewApplication(backend, PageUsage()));
      await tester.pumpAndSettle();
      await populateOverview(tester);
      for (final key in overviewGraphKeys) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.byType(MonitorDisclosure), findsNothing);
      expect(find.textContaining('最近完成'), findsWidgets);
      expect(find.textContaining('已取消'), findsWidgets);
      expect(graph(tester, 'session-recent-chart').bars.length, 16);
      expect(configurationGraph(tester).bars.length, 3);
      final responses = graph(tester, 'session-response-chart');
      expect(responses.stacked, isTrue);
      expect(
        responses.bars.fold<double>(
          0,
          (sum, b) => sum + b.value! + b.secondaryValue!,
        ),
        100,
      );
      expect(
        responses.bars.fold<double>(0, (sum, b) => sum + b.secondaryValue!),
        20,
      );
      await overviewTap(tester, 'session-information');
      expect(find.textContaining('recent-completed'), findsWidgets);
      expect(find.textContaining('current-cancelled'), findsWidgets);
      await overviewTap(tester, 'monitor-information-close');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selectors change values and units and survive source page session and width changes without reads',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final backend = OverviewBackend();
      final usage = PageUsage();
      await tester.pumpWidget(overviewApplication(backend, usage));
      await tester.pumpAndSettle();
      await populateOverview(tester);
      final controller = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      final sessionCalls = backend.sessionCalls;
      await chooseOverview(tester, 'session-recent-range', '8');
      expect(graph(tester, 'session-recent-chart').bars.length, 8);
      await chooseOverview(tester, 'session-recent-metric', 'status');
      expect(graph(tester, 'session-recent-chart').unit, '回合');
      expect(
        graph(tester, 'session-recent-chart').bars.map((bar) => bar.label),
        ['完成', '取消'],
      );
      expect(
        graph(tester, 'session-recent-chart').bars.map((bar) => bar.value),
        [6, 2],
      );
      await chooseOverview(tester, 'session-configuration-metric', 'output');
      expect(configurationGraph(tester).unit, 'tokens');
      expect(configurationGraph(tester).bars.map((b) => b.value), [
        100,
        200,
        300,
      ]);
      await chooseOverview(tester, 'session-activity-view', 'duration');
      expect(graph(tester, 'session-activity-chart').bars.map((b) => b.value), [
        3,
        3,
        3,
        .5,
      ]);
      await chooseOverview(tester, 'session-response-view', 'total');
      expect(graph(tester, 'session-response-chart').stacked, isFalse);
      expect(graph(tester, 'session-response-chart').bars.map((b) => b.value), [
        15,
        15,
        25,
        20,
        15,
        10,
      ]);
      expect(find.text('总输出 · 含推理'), findsWidgets);
      await overviewTap(tester, 'workspace-benchmark', settle: false);
      await overviewTap(tester, 'workspace-analysis', settle: false);
      await overviewTap(tester, 'workspace-launcher', settle: false);
      await overviewTap(tester, 'workspace-analysis', settle: false);
      for (final width in [320.0, 600.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pump();
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(SessionMetricsPanel)))
              .width,
          width,
        );
        expect(tester.takeException(), isNull);
      }
      controller.data = overviewFixture();
      controller.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('session-response-view')),
            )
            .value,
        'total',
      );
      expect(
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('session-recent-range')),
            )
            .value,
        '8',
      );
      expect(backend.sessionCalls, sessionCalls);
      expect(usage.calls, 1);
      expect(controller.selected, overviewPath);
      await tester.ensureVisible(find.text('停止会话采集'));
      await tester.tap(find.text('停止会话采集'));
      await tester.pumpAndSettle();
      expect(controller.selected, isNull);
      // Count assertions are complete and stop cancelled the collector timer.
      // Let Forui's focus-exit animation and 300ms tooltip-group timer finish
      // while mounted, then drain disposal callbacks without suppressing them.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial coverage fails closed and read error clears chart samples',
    (tester) async {
      final backend = OverviewBackend()..value = overviewFixture(partial: true);
      await tester.pumpWidget(overviewApplication(backend, PageUsage()));
      await tester.pumpAndSettle();
      await populateOverview(tester);
      await chooseOverview(tester, 'session-activity-view', 'coverage');
      expect(find.textContaining('覆盖不可核验'), findsOneWidget);
      expect(find.byType(MonitorCoverageChart), findsNothing);
      final controller = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      controller.data = null;
      controller.error = 'synthetic read failure';
      controller.notifyListeners();
      await tester.pumpAndSettle();
      for (final key in overviewGraphKeys.skip(1)) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(MonitorBarChart),
          ),
          findsNothing,
        );
      }
      expect(find.textContaining('读取失败'), findsWidgets);
      expect(find.text('10.00 tokens/s'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
