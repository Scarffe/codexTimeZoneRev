import 'package:codex_timezone/services/session_measurement_quality.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_metrics_test.dart' show Backend, NoUsage;

class QualityBackend extends Backend {
  Map<String, dynamic> value = qualityFixture();
  bool fail = false;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    expect(command, 'session_metrics');
    if (fail) throw StateError('fixture read failure');
    return value;
  }
}

Map<String, dynamic> qualityFixture({String status = 'verified'}) => {
  'measurement': {
    'kind': 'observed_turn',
    'sourceLabel': '所选 Codex 会话 · 本地只读日志',
    'sessionId': 'fixture-session',
    'tokenSource': 'turn_token_usage.output_tokens',
    'durationSource': 'task_complete.duration_ms',
    'outputIncludesReasoning': true,
  },
  'quality': {'status': status, 'reasons': <String>[]},
  'last': {
    'outputTokens': 20,
    'reasoningTokens': 5,
    'durationMs': 2000,
    'tokensPerSecond': 10.0,
    'verifiedTokensPerSecond': status == 'verified' ? 10.0 : null,
    'quality': {'status': status, 'reasons': <String>[]},
  },
  'verifiedGroups': [
    {
      'sessionId': 'fixture-session',
      'model': 'fixture-model',
      'effort': 'high',
      'serviceTier': 'default',
      'turnCount': 2,
      'outputTokens': 100,
      'durationMs': 6000,
      'tokensPerSecond': 100 / 6,
    },
  ],
};

void main() {
  test(
    'verified local turn retains source, output scope and weighted groups',
    () {
      final quality = SessionMeasurementQuality.fromData(qualityFixture());
      expect(quality.status, 'verified');
      expect(quality.label, '已核验');
      expect(quality.verifiedTokensPerSecond, 10);
      expect(quality.reportedTokensPerSecond, 10);
      expect(quality.sourceLabel, contains('本地只读日志'));
      expect(
        quality.verifiedGroups.single['tokensPerSecond'],
        closeTo(16.6667, .001),
      );
    },
  );

  test('old DLL numbers and unknown quality never promote a raw ratio', () {
    final legacy = SessionMeasurementQuality.fromData({
      'last': {'tokensPerSecond': 10},
    });
    expect(legacy.status, 'reported_only');
    expect(legacy.verifiedTokensPerSecond, isNull);
    expect(legacy.reportedTokensPerSecond, 10);
    expect(legacy.reasons, isNotEmpty);
    expect(SessionMeasurementQuality.fromData(null).status, 'incomplete');
    final unknown = qualityFixture()..['quality'] = {'status': 'future'};
    expect(
      SessionMeasurementQuality.fromData(unknown).verifiedTokensPerSecond,
      isNull,
    );
  });

  test(
    'all nonverified qualities and conflicting top level suppress numeric rate',
    () {
      for (final status in [
        'reported_only',
        'incomplete',
        'conflict',
        'unsupported',
      ]) {
        final fixture = qualityFixture(status: status);
        (fixture['last'] as Map)['verifiedTokensPerSecond'] = 10;
        final quality = SessionMeasurementQuality.fromData(fixture);
        expect(quality.status, status);
        expect(quality.verifiedTokensPerSecond, isNull);
      }
      final fixture = qualityFixture();
      fixture['quality'] = {
        'status': 'conflict',
        'reasons': ['conflicting_usage'],
      };
      expect(
        SessionMeasurementQuality.fromData(fixture).verifiedTokensPerSecond,
        isNull,
      );
    },
  );

  test('malformed aggregate rows cannot create a checked summary', () {
    final fixture = qualityFixture();
    fixture['verifiedGroups'] = [
      {'tokensPerSecond': 99},
      {
        'sessionId': 'fixture-session',
        'model': 'm',
        'effort': 'high',
        'serviceTier': 'default',
        'turnCount': 1,
        'outputTokens': 20,
        'durationMs': 0,
        'tokensPerSecond': double.infinity,
      },
    ];
    expect(SessionMeasurementQuality.fromData(fixture).verifiedGroups, isEmpty);
  });

  test(
    'malformed payloads fail closed and reasons have safe Chinese fallback',
    () {
      for (final malformed in [
        {'last': 'invalid', 'quality': 1},
        {
          'last': {'tokensPerSecond': double.nan},
        },
        qualityFixture()..['measurement'] = [],
        qualityFixture()
          ..['quality'] = {'status': 'verified', 'reasons': 'invalid'},
        qualityFixture()
          ..['last'] = {'verifiedTokensPerSecond': double.infinity},
        qualityFixture()
          ..['last'] = {
            'quality': {'status': 'verified', 'reasons': []},
            'verifiedTokensPerSecond': -1,
          },
      ]) {
        expect(
          SessionMeasurementQuality.fromData(malformed).verifiedTokensPerSecond,
          isNull,
        );
      }
      final fixture = qualityFixture(status: 'incomplete');
      fixture['quality'] = {
        'status': 'incomplete',
        'reasons': ['missing_usage', 'new_backend_reason'],
      };
      (fixture['last'] as Map)['quality'] = fixture['quality'];
      final quality = SessionMeasurementQuality.fromData(fixture);
      expect(quality.reasons, contains('缺少回合用量'));
      expect(quality.reasons, contains('核验信息不完整，暂无法核验'));
      expect(quality.reasons.join(), isNot(contains('new_backend_reason')));
    },
  );

  test(
    'controller summary exposes checked rate only and keeps raw for details',
    () {
      final controller = SessionMetricsController(Backend())
        ..selected = 'fixture';
      addTearDown(controller.dispose);
      controller.data = qualityFixture();
      expect(controller.verifiedTokensPerSecond, 10);
      expect(controller.summary, contains('已核验'));
      expect(controller.summary, contains('回合平均吞吐 10.00 tokens/s'));
      controller.data = {
        'last': {'tokensPerSecond': 99},
      };
      expect(controller.verifiedTokensPerSecond, isNull);
      expect(controller.summary, contains('未充分核验'));
      expect(controller.summary, isNot(contains('99')));
      expect(controller.measurementQuality.reportedTokensPerSecond, 99);
    },
  );

  testWidgets(
    'tray publishes observed verified rate then clears on conflict malformed and read failure',
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
      final backend = QualityBackend();
      final metrics = SessionMetricsController(backend);
      final usage = AccountUsageController(NoUsage())..savedMonitoring = false;
      final monitor = DesktopMonitor(usage, () => 'unused', metrics: metrics)
        ..start();
      metrics.select('fixture');
      await tester.pump();
      expect(snapshots.last['sessionRate'], 10.0);
      expect(snapshots.last['sessionSummary'], contains('已核验回合平均吞吐'));
      for (final value in [
        qualityFixture(status: 'conflict'),
        {
          'last': {'tokensPerSecond': 99.0},
        },
        {'quality': 'malformed', 'last': 'malformed'},
      ]) {
        backend.value = value;
        await metrics.poll();
        await tester.pump();
        expect(snapshots.last['sessionRate'], -1.0);
        expect(
          snapshots.last['sessionSummary'],
          isNot(contains('99.00 tokens/s')),
        );
      }
      backend.fail = true;
      await metrics.poll();
      await tester.pump();
      expect(snapshots.last['sessionRate'], -1.0);
      expect(snapshots.last['sessionSummary'], contains('读取失败'));
      expect(usage.attempts, 0);
      expect(tester.takeException(), isNull);
      monitor.dispose();
      metrics.dispose();
      usage.dispose();
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );
}
