import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/app/theme.dart';

import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class Backend implements LauncherBackend {
  final calls = <Map<String, dynamic>>[];
  String listedPath = 'a';
  Map<String, dynamic>? analysis;
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    expect(command, 'session_metrics');
    calls.add(payload);
    if (payload['action'] == 'list') {
      return {
        'sessions': [
          {
            'path': listedPath,
            'id': 'main',
            'cwd': 'fixture',
            'timestamp': '2026-10-21',
          },
        ],
      };
    }
    if (pending != null) return pending!.future;
    return {
      'sourceInfo': {'id': 'main', 'path': listedPath, 'cwd': 'fixture'},
      'active': true,
      'last': {
        'tokensPerSecond': 10.0,
        'outputTokens': 20,
        'analysis': analysis,
      },
    };
  }
}

class NoUsage implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) async =>
      throw StateError('quota must not be queried');
}

Widget panelApp(SessionMetricsController c) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (context, child) => FTheme(
    data: lightLauncherTheme,
    child: FToaster(
      child: FTooltipGroup(
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 14),
          child: child!,
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) => PageRouteBuilder<void>(
    pageBuilder: (_, _, _) =>
        SingleChildScrollView(child: SessionMetricsPanel(controller: c)),
  ),
);

void main() {
  testWidgets(
    'timing analysis labels observed intervals and expands numeric usage',
    (tester) async {
      final b = Backend()
        ..analysis = {
          'responseCount': 2,
          'responseOutputTokens': 20,
          'usageMatchesTurn': true,
          'messageMs': 1000,
          'reasoningMs': 2000,
          'toolMs': 5000,
          'otherMs': null,
          'observedMs': 7000,
          'overlapMs': 1000,
          'unclassifiedMs': 3000,
          'partial': false,
          'recentResponses': [
            {
              'responseId': 'response-fixture',
              'outputTokens': 20,
              'reasoningTokens': 5,
            },
          ],
        };
      final c = SessionMetricsController(b)..select('a');
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-information')));
      await tester.pumpAndSettle();
      expect(find.textContaining('与回合总数：一致'), findsOneWidget);
      expect(find.text('未归类时间：3.000 s'), findsOneWidget);
      expect(find.textContaining('response-fixture'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('old logs show unavailable timing rather than invented zero', (
    tester,
  ) async {
    final c = SessionMetricsController(Backend())..select('a');
    await tester.pumpWidget(panelApp(c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-information')));
    await tester.pumpAndSettle();
    expect(find.text('未归类时间：不可用'), findsNothing);
    expect(find.textContaining('计时数据不完整'), findsOneWidget);
    expect(find.textContaining('未归类时间：0.000'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final outsideList in [false, true]) {
    testWidgets('refresh after startup selection, outside list=$outsideList', (
      tester,
    ) async {
      final backend = Backend()
        ..listedPath = r'\\?\C:\Users\fixture\sessions\main.jsonl';
      final c = SessionMetricsController(backend);
      c.select(
        outsideList
            ? r'C:\Users\fixture\sessions\older.jsonl'
            : r'c:/Users/fixture/sessions/main.jsonl',
      );
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-refresh')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(c.selectorValue, outsideList ? null : backend.listedPath);
      expect(find.textContaining('样本质量：日志报告值 · 未充分核验'), findsOneWidget);
      if (outsideList) {
        expect(find.textContaining('当前采集会话不在最近列表中'), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('session-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('未命名会话 · fixture · main').last);
      await tester.pumpAndSettle();
      expect(
        c.selected,
        outsideList
            ? backend.listedPath
            : r'c:/Users/fixture/sessions/main.jsonl',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('session selector chooses by identity, renders rate, and stops', (
    tester,
  ) async {
    final c = SessionMetricsController(Backend());
    await tester.pumpWidget(panelApp(c));
    await tester.tap(find.byKey(const ValueKey('session-refresh')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('未命名会话 · fixture · main').last);
    await tester.pumpAndSettle();
    expect(c.selected, 'a');
    expect(find.textContaining('样本质量：日志报告值 · 未充分核验'), findsOneWidget);
    await tester.ensureVisible(find.text('停止会话采集'));
    await tester.tap(find.text('停止会话采集'));
    await tester.pumpAndSettle();
    expect(c.selected, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets(
    'hidden main publishes independent session result to tray and pet',
    (tester) async {
      final snapshots = <Map<Object?, Object?>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
        if (call.method == 'publish') {
          snapshots.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        if (call.method == 'mainVisible') return false;
        return null;
      });
      final usage = AccountUsageController(NoUsage())..savedMonitoring = false;
      final metrics = SessionMetricsController(Backend());
      final monitor = DesktopMonitor(usage, () => 'unused', metrics: metrics)
        ..start();
      metrics.select('a');
      await tester.pump();
      expect(usage.mainWindowVisible, false);
      expect(usage.attempts, 0);
      expect(snapshots.last['sessionRate'], -1.0);
      expect(snapshots.last['text'], contains('未充分核验'));
      expect(snapshots.last['text'], isNot(contains('10.00 tokens/s')));
      expect(snapshots.last['sessionSummary'], contains('回合平均吞吐'));
      metrics.select(null);
      await tester.pump();
      expect(snapshots.last['sessionSummary'], '');
      monitor.dispose();
      metrics.dispose();
      usage.dispose();
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );
  test(
    'only explicit selection polls, publishes whole-turn label, stop cancels',
    () async {
      final b = Backend();
      final c = SessionMetricsController(b);
      await c.list();
      expect(b.calls.length, 1);
      expect(c.selected, isNull);
      c.select('a');
      await Future<void>.delayed(Duration.zero);
      expect(c.summary, contains('未充分核验'));
      expect(c.summary, isNot(contains('10.00 tokens/s')));
      expect(c.summary, contains('本轮进行中'));
      expect(c.petSummary, contains('回合平均吞吐'));
      c.select(null);
      await c.poll();
      expect(b.calls.length, 2);
      expect(c.summary, '');
      c.dispose();
    },
  );
  test(
    'switch or stop discards previous in-flight result; dispose is safe',
    () async {
      final b = Backend()..pending = Completer();
      final c = SessionMetricsController(b);
      c.select('a');
      c.select('b');
      b.pending!.complete({
        'last': {'tokensPerSecond': 999},
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.data, isNull);
      b.pending = null;
      await c.poll();
      expect(c.last!['tokensPerSecond'], 10);
      b.pending = Completer();
      final request = c.poll();
      c.dispose();
      b.pending!.complete({});
      await request;
    },
  );
}
