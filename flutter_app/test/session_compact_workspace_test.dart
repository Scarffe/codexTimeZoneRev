import 'package:codex_timezone/app/session_measurement_workspace.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'session_activity_fixture.dart';
import 'session_activity_timeline_widget_test.dart' show timelineApp;
import 'session_measurement_quality_test.dart'
    show QualityBackend, qualityFixture;
import 'session_metrics_test.dart' show panelApp;

const sourcePath =
    r'C:\fixture\private-project\sessions\original-session.jsonl';

Map<String, dynamic> compactFixture({String status = 'verified'}) {
  final value = qualityFixture(status: status);
  value['sourceInfo'] = {
    'id': 'original-session-id',
    'title': '同名会话',
    'cwd': r'C:\fixture\private-project',
    'path': sourcePath,
  };
  value['current'] = {'status': 'running', 'turnId': 'current-turn'};
  (value['last'] as Map).addAll(<String, dynamic>{
    'turnId': 'previous-completed-turn',
    'firstTokenMs': 0,
    'analysis': {
      'timeline': timelineFixture(),
      'partial': false,
      'overlapMs': 1000,
      'unclassifiedMs': 2000,
      'recentResponses': [
        {'responseId': 'response-original', 'outputTokens': 20},
      ],
    },
  });
  return value;
}

Future<void> openDetail(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'compact summary shows checked metrics and chart before raw facts',
    (tester) async {
      final c = SessionMetricsController(QualityBackend())
        ..selected = sourcePath
        ..data = compactFixture();
      addTearDown(c.dispose);
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-timeline-chart')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('session-timeline-list')), findsNothing);
      expect(find.text('10.00 tokens/s'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('session-first-token-value')),
            )
            .data,
        '0.000 s',
      );
      expect(find.text('2.000 s'), findsOneWidget);
      expect(find.textContaining('可能含推理'), findsOneWidget);
      expect(find.text('重叠 1.000 s · 未归类 2.000 s（非等待判定）'), findsOneWidget);
      expect(find.textContaining(sourcePath), findsNothing);
      expect(find.textContaining('Unix epoch'), findsNothing);
      expect(find.textContaining('÷'), findsNothing);
      await openDetail(tester, 'session-source-details');
      expect(find.text('日志：$sourcePath'), findsOneWidget);
      expect(find.text('会话 ID：original-session-id'), findsOneWidget);
      await openDetail(tester, 'session-measurement-details');
      expect(find.textContaining('÷'), findsOneWidget);
      await openDetail(tester, 'session-timing-details');
      expect(find.textContaining('首模型 token 后的回合耗时'), findsOneWidget);
      await openDetail(tester, 'session-response-details');
      expect(find.textContaining('response-original'), findsOneWidget);
      await openDetail(tester, 'session-timeline-toggle');
      expect(find.textContaining('Unix epoch'), findsWidgets);
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
    'source details preserve selected log-write time distinct from last read',
    (tester) async {
      final c = SessionMetricsController(QualityBackend())
        ..selected = sourcePath
        ..data = compactFixture()
        ..lastRead = DateTime(2026, 10, 23, 11, 12, 13)
        ..sessions = [
          {
            'path': r'\\?\C:\fixture\private-project\sessions\original-session.jsonl',
            'id': 'original-session-id',
            'modifiedMs': DateTime(
              2026,
              10,
              23,
              8,
              9,
              10,
            ).millisecondsSinceEpoch,
          },
          {
            'path': 'other-log.jsonl',
            'id': 'other-session',
            'modifiedMs': DateTime(
              2026,
              10,
              23,
              1,
              2,
              3,
            ).millisecondsSinceEpoch,
          },
        ];
      addTearDown(c.dispose);
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      expect(find.textContaining('日志写入时间：'), findsNothing);
      await openDetail(tester, 'session-source-details');
      expect(find.text('日志写入时间：2026-10-23 08:09:10'), findsOneWidget);
      expect(find.text('最近成功读取：2026-10-23 11:12:13'), findsOneWidget);
      expect(find.text('日志写入时间：2026-10-23 11:12:13'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source log-write time remains unknown without selected metadata',
    (tester) async {
      for (final sessions in <List<Map<String, dynamic>>>[
        [],
        [
          {'path': sourcePath, 'id': 'original-session-id'},
        ],
      ]) {
        final c = SessionMetricsController(QualityBackend())
          ..selected = sourcePath
          ..data = compactFixture()
          ..lastRead = DateTime(2026, 10, 23, 11, 12, 13)
          ..sessions = sessions;
        await tester.pumpWidget(panelApp(c));
        await tester.pumpAndSettle();
        await openDetail(tester, 'session-source-details');
        expect(find.text('日志写入时间：活动时间未知'), findsOneWidget);
        expect(find.text('日志写入时间：2026-10-23 11:12:13'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );

  testWidgets(
    'short duplicate labels keep path values and search full ID and path',
    (tester) async {
      final c = SessionMetricsController(QualityBackend());
      addTearDown(c.dispose);
      c.sessions = [
        for (final suffix in ['alpha', 'beta'])
          {
            'path': 'C:/hidden/$suffix/original.jsonl',
            'cwd': 'C:/hidden/$suffix/project',
            'title': '同名会话',
            'id': 'same-prefix-$suffix',
          },
      ];
      await tester.pumpWidget(panelApp(c));
      await tester.tap(find.byKey(const ValueKey('session-selector')));
      await tester.pumpAndSettle();
      expect(find.textContaining('C:/hidden/'), findsNothing);
      final field = find.descendant(
        of: find.byType(FTextField),
        matching: find.byType(EditableText),
      );
      // The selector field is also editable; the last field is popup search.
      await tester.enterText(field.last, 'same-prefix-beta');
      await tester.pumpAndSettle();
      final choices = find.textContaining('同名会话');
      expect(choices, findsOneWidget);
      await tester.tap(choices);
      await tester.pumpAndSettle();
      expect(c.selected, 'C:/hidden/beta/original.jsonl');
      await tester.tap(find.byKey(const ValueKey('session-selector')));
      await tester.pumpAndSettle();
      await tester.enterText(field.last, 'C:/hidden/alpha/original.jsonl');
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('同名会话').last);
      await tester.pumpAndSettle();
      expect(c.selected, 'C:/hidden/alpha/original.jsonl');
      c.select(null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'primary rate never promotes reported conflict or partial and preserves zero',
    (tester) async {
      final c = SessionMetricsController(QualityBackend())
        ..selected = sourcePath;
      addTearDown(c.dispose);
      for (final status in [
        'reported_only',
        'conflict',
        'incomplete',
        'verified',
      ]) {
        c.data = compactFixture(status: status);
        if (status == 'verified') {
          (c.data!['last'] as Map)['verifiedTokensPerSecond'] = 0.0;
          (c.data!['last'] as Map)['outputTokens'] = 0;
        }
        await tester.pumpWidget(panelApp(c));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('session-rate-value')))
              .data,
          status == 'verified' ? '0.00 tokens/s' : '不可用',
        );
        expect(find.text('10.00 tokens/s'), findsNothing);
      }
    },
  );

  testWidgets(
    'known first token survives missing duration and retained sample is explicitly old on read failure',
    (tester) async {
      final c = SessionMetricsController(QualityBackend())
        ..selected = sourcePath
        ..data = compactFixture()
        ..error = 'fixture read failure';
      addTearDown(c.dispose);
      (c.data!['last'] as Map)['durationMs'] = null;
      (c.data!['last'] as Map)['firstTokenMs'] = 2500;
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      expect(find.textContaining('状态未知 · 读取失败'), findsOneWidget);
      expect(find.textContaining('保留的上轮样本'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('session-first-token-value')),
            )
            .data,
        '2.500 s',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('session-duration-value')))
            .data,
        '不可用',
      );
      await openDetail(tester, 'session-source-details');
      expect(find.textContaining('previous-completed-turn'), findsOneWidget);
    },
  );

  testWidgets(
    'read error exposes failure but keeps full source path in details',
    (tester) async {
      final c = SessionMetricsController(QualityBackend())
        ..selected = sourcePath
        ..error = 'FileSystemException: missing, path = $sourcePath';
      addTearDown(c.dispose);
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      expect(find.textContaining('读取失败'), findsWidgets);
      expect(find.textContaining(sourcePath), findsNothing);
      await openDetail(tester, 'session-error-details');
      expect(find.textContaining('path = $sourcePath'), findsOneWidget);
    },
  );

  for (final width in [320.0, 600.0, 760.0, 1280.0]) {
    testWidgets(
      'compact session keeps actions and details usable at $width with 125% text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final c = SessionMetricsController(QualityBackend())
          ..selected = sourcePath
          ..data = compactFixture();
        addTearDown(c.dispose);
        (c.data!['sourceInfo'] as Map)['title'] = List.filled(
          16,
          '很长的测试会话名',
        ).join();
        await tester.pumpWidget(
          timelineApp(
            MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
              child: SingleChildScrollView(
                child: SessionMetricsPanel(controller: c),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('session-timeline-chart')),
          findsOneWidget,
        );
        for (final key in [
          'session-source-details',
          'session-measurement-details',
          'session-timing-details',
          'session-timeline-toggle',
        ]) {
          await openDetail(tester, key);
          expect(tester.takeException(), isNull);
        }
        await tester.ensureVisible(find.text('停止会话采集'));
        await tester.tap(find.text('停止会话采集'));
        await tester.pumpAndSettle();
        expect(c.selected, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'API source stays a request-free pending page after M2 acceptance',
    (tester) async {
      await tester.pumpWidget(
        timelineApp(
          const SessionMeasurementWorkspace(
            currentSession: Text('local fixture'),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('measurement-independent-api')),
      );
      await tester.pumpAndSettle();
      expect(find.text('待实现'), findsOneWidget);
      expect(find.textContaining('M2 离线内核已验收'), findsOneWidget);
      expect(find.byType(SessionMetricsPanel), findsNothing);
    },
  );
}
