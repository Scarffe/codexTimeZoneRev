import 'package:codex_timezone/services/session_chart_data.dart';
import 'package:codex_timezone/services/session_measurement_quality.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_activity_fixture.dart';

Map<String, dynamic> chartFixture() => {
  'catchingUp': false,
  'measurement': <String, dynamic>{
    'kind': 'observed_turn',
    'sourceLabel': '本地只读日志',
    'sessionId': 'synthetic-session',
    'tokenSource': 'turn_token_usage.output_tokens',
    'durationSource': 'task_complete.duration_ms',
    'outputIncludesReasoning': true,
  },
  'quality': <String, dynamic>{'status': 'verified', 'reasons': <String>[]},
  'terminals': <Map<String, dynamic>>[
    {'turnId': 'turn-new', 'status': 'cancelled', 'durationMs': null},
    {'turnId': 'turn-old', 'status': 'completed', 'durationMs': 0},
  ],
  'last': <String, dynamic>{
    'turnId': 'turn-old',
    'durationMs': 10000,
    'outputTokens': 100,
    'verifiedTokensPerSecond': 10.0,
    'quality': <String, dynamic>{'status': 'verified', 'reasons': <String>[]},
    'analysis': <String, dynamic>{
      'messageMs': 5000,
      'reasoningMs': 2000,
      'toolMs': 3000,
      'otherMs': 0,
      'observedMs': 7000,
      'unclassifiedMs': 3000,
      'coverageValid': true,
      'partial': false,
      'usageMatchesTurn': true,
      'timeline': timelineFixture(),
      'recentResponses': <Map<String, dynamic>>[
        {
          'responseId': 'response-new',
          'outputTokens': 20,
          'reasoningTokens': 5,
        },
        {'responseId': 'response-old', 'outputTokens': 0, 'reasoningTokens': 0},
      ],
    },
  },
  'verifiedGroups': <Map<String, dynamic>>[
    {
      'sessionId': 'synthetic-session',
      'model': 'model-a',
      'effort': 'high',
      'serviceTier': 'default',
      'turnCount': 2,
      // Two unequal turns: 10/1 s and 90/3 s => 100/4 s, not mean(10, 30).
      'outputTokens': 100,
      'durationMs': 4000,
      'tokensPerSecond': 25.0,
    },
  ],
};

Map<String, dynamic> analysisOf(Map<String, dynamic> data) =>
    (data['last'] as Map<String, dynamic>)['analysis'] as Map<String, dynamic>;

void main() {
  test('latest window is selected before reversing', () {
    final fixture = chartFixture();
    fixture['terminals'] = [
      for (var i = 0; i < 70; i++)
        {'turnId': 't$i', 'status': 'completed', 'durationMs': i},
    ];
    analysisOf(fixture)['recentResponses'] = [
      for (var i = 0; i < 15; i++)
        {'responseId': 'r$i', 'outputTokens': i, 'reasoningTokens': 0},
    ];
    final data = SessionChartData.fromData(fixture);
    expect(data.recentTerminals(24).length, 24);
    expect(data.recentTerminals(24).first.id, 't23');
    expect(data.recentTerminals(24).last.id, 't0');
    expect(data.recentTerminals(100).length, 64);
    expect(data.recentTerminals(100).first.id, 't63');
    expect(data.recentTerminals(0), isEmpty);
    expect(data.recentTerminals(-1), isEmpty);
    expect(data.responses.length, 12);
    expect(data.responses.first.id, 'r11');
    expect(data.responses.last.id, 'r0');
  });

  test('cancelled missing duration stays unknown', () {
    final data = SessionChartData.fromData(chartFixture());
    final samples = data.recentTerminals(24);
    expect(samples.first.id, 'turn-old');
    expect(samples.first.status, 'completed');
    expect(samples.first.cancelled, false);
    expect(samples.first.durationMs, 0);
    expect(samples.last.id, 'turn-new');
    expect(samples.last.cancelled, true);
    expect(samples.last.durationMs, isNull);
    for (final invalid in [
      -1,
      0.5,
      double.nan,
      double.infinity,
      '2000',
      9007199254740992,
    ]) {
      final fixture = chartFixture();
      (fixture['terminals'] as List).first['durationMs'] = invalid;
      expect(
        SessionChartData.fromData(fixture).recentTerminals(24).last.durationMs,
        isNull,
        reason: '$invalid',
      );
    }
  });

  test('reasoning unknown is not zero', () {
    for (final invalid in [
      null,
      -1,
      21,
      2.5,
      double.nan,
      double.infinity,
      '5',
      9007199254740992,
    ]) {
      final fixture = chartFixture();
      (analysisOf(fixture)['recentResponses'] as List)
              .first['reasoningTokens'] =
          invalid;
      final response = SessionChartData.fromData(fixture).responses.last;
      expect(response.outputTokens, 20);
      expect(response.reasoningTokens, isNull, reason: '$invalid');
      expect(response.nonReasoningTokens, isNull, reason: '$invalid');
    }
    final valid = SessionChartData.fromData(chartFixture()).responses;
    expect(valid.first.outputTokens, 0);
    expect(valid.first.reasoningTokens, 0);
    expect(valid.first.nonReasoningTokens, 0);
    expect(valid.last.nonReasoningTokens, 15);
    final fixture = chartFixture();
    (analysisOf(fixture)['recentResponses'] as List).first['outputTokens'] = -1;
    final badTotal = SessionChartData.fromData(fixture).responses.last;
    expect(badTotal.outputTokens, isNull);
    expect(badTotal.reasoningTokens, 5);
    expect(badTotal.nonReasoningTokens, isNull);
  });

  test('coverage requires every integrity gate', () {
    final valid = SessionChartData.fromData(chartFixture());
    expect(valid.timeline.available, true);
    expect(valid.coverage!.observedMs, 7000);
    expect(valid.coverage!.unclassifiedMs, 3000);
    expect(valid.coverage!.durationMs, 10000);
    final mutations = <void Function(Map<String, dynamic>)>[
      (d) => analysisOf(d)['coverageValid'] = false,
      (d) => analysisOf(d).remove('coverageValid'),
      (d) => analysisOf(d)['partial'] = true,
      (d) => analysisOf(d)['observedMs'] = 7000.0,
      (d) => analysisOf(d)['observedMs'] = -1,
      (d) => analysisOf(d)['unclassifiedMs'] = null,
      (d) => analysisOf(d)['unclassifiedMs'] = 3001,
      (d) => (d['last'] as Map)['durationMs'] = 9999,
      (d) => (d['last'] as Map)['durationMs'] = 9007199254740992,
      (d) => analysisOf(d)['timeline'] = null,
      (d) => (analysisOf(d)['timeline'] as Map)['version'] = 2,
      (d) => (analysisOf(d)['timeline'] as Map)['coverageInterpretation'] =
          'unavailable',
      (d) {
        final timeline = analysisOf(d)['timeline'] as Map;
        timeline['coverageInterpretation'] = 'unavailable';
        timeline['sourcePartial'] = true;
      },
      (d) {
        final timeline = timelineFixture(count: 200)
          ..['totalItems'] = 201
          ..['omittedItems'] = 1
          ..['coverageInterpretation'] = 'unavailable';
        analysisOf(d)['timeline'] = timeline;
      },
    ];
    for (var i = 0; i < mutations.length; i++) {
      final fixture = chartFixture();
      mutations[i](fixture);
      expect(SessionChartData.fromData(fixture).coverage, isNull, reason: '$i');
    }
    final zero = chartFixture();
    analysisOf(zero)['observedMs'] = 0;
    analysisOf(zero)['unclassifiedMs'] = 10000;
    expect(SessionChartData.fromData(zero).coverage!.observedMs, 0);
  });

  test('activity facts retain overlap and distinguish zero from unknown', () {
    final fixture = chartFixture();
    analysisOf(fixture)['reasoningMs'] = -1;
    analysisOf(fixture)['toolMs'] = null;
    final data = SessionChartData.fromData(fixture);
    expect(data.activities.map((s) => s.category), [
      'message',
      'reasoning',
      'tool',
      'other',
    ]);
    expect(data.activities.map((s) => s.milliseconds), [5000, null, null, 0]);
    expect(data.activities.every((s) => s.label.isNotEmpty), true);
    for (final value in [true, false, null, 'true', 1]) {
      analysisOf(fixture)['usageMatchesTurn'] = value;
      expect(
        SessionChartData.fromData(fixture).usageMatchesTurn,
        value is bool ? value : null,
      );
    }
  });

  test('earlier valid groups survive bad latest sample', () {
    final fixture = chartFixture();
    fixture['quality'] = {
      'status': 'conflict',
      'reasons': ['conflicting_usage'],
    };
    (fixture['last'] as Map)['quality'] = {
      'status': 'conflict',
      'reasons': ['conflicting_usage'],
    };
    final quality = SessionMeasurementQuality.fromData(fixture);
    expect(quality.verifiedTokensPerSecond, isNull);
    final groups = ConfigurationChartSample.fromQuality(quality);
    expect(groups.length, 1);
    expect(groups.single.model, 'model-a');
    expect(groups.single.effort, 'high');
    expect(groups.single.serviceTier, 'default');
    expect(groups.single.turnCount, 2);
    expect(groups.single.outputTokens, 100);
    expect(groups.single.durationMs, 4000);
    expect(groups.single.tokensPerSecond, 25.0);
    expect(groups.single.label, contains('model-a'));
    expect(groups.single.label, contains('high'));
    expect(groups.single.label, contains('default'));
  });

  test('configuration ratios keep sum sources and all distinct groups', () {
    final fixture = chartFixture();
    final groups = fixture['verifiedGroups'] as List;
    groups.add({
      ...Map<String, dynamic>.from(groups.single as Map),
      'effort': 'low',
      'serviceTier': 'priority',
      'outputTokens': 101,
      'durationMs': 6000,
      'tokensPerSecond': 101 / 6,
    });
    final samples = ConfigurationChartSample.fromQuality(
      SessionMeasurementQuality.fromData(fixture),
    );
    expect(samples.length, 2);
    expect(samples.last.outputTokens, 101);
    expect(samples.last.durationMs, 6000);
    expect(samples.last.tokensPerSecond, closeTo(16.833333333, .00000001));
    for (final mutation in <void Function(Map)>[
      (g) => g['outputTokens'] = 9007199254740992,
      (g) => g['durationMs'] = 9007199254740992,
      (g) => g['turnCount'] = 9007199254740992,
      (g) => g['tokensPerSecond'] = 99,
    ]) {
      final data = chartFixture();
      mutation((data['verifiedGroups'] as List).single as Map);
      expect(
        ConfigurationChartSample.fromQuality(
          SessionMeasurementQuality.fromData(data),
        ),
        isEmpty,
      );
    }
  });

  test('unsafe conflicting configuration duplicate suppresses identity', () {
    final exact = chartFixture();
    final exactGroups = exact['verifiedGroups'] as List;
    exactGroups.add(Map<String, dynamic>.from(exactGroups.single as Map));
    expect(
      ConfigurationChartSample.fromQuality(
        SessionMeasurementQuality.fromData(exact),
      ).length,
      1,
    );

    for (final unsafeFirst in [false, true]) {
      final fixture = chartFixture();
      final safe = Map<String, dynamic>.from(
        (fixture['verifiedGroups'] as List).single as Map,
      );
      final unsafe = <String, dynamic>{
        ...safe,
        'turnCount': 2,
        'outputTokens': 9007199254740992,
        'durationMs': 4000,
        'tokensPerSecond': 2251799813685248.0,
      };
      fixture['verifiedGroups'] = <Map<String, dynamic>>[
        if (unsafeFirst) unsafe,
        safe,
        if (!unsafeFirst) unsafe,
      ];
      final quality = SessionMeasurementQuality.fromData(fixture);
      expect(quality.verifiedGroups.length, 2);
      expect(
        ConfigurationChartSample.fromQuality(quality),
        isEmpty,
        reason: 'unsafeFirst=$unsafeFirst',
      );
    }
  });

  test('malformed and duplicate identities fail closed', () {
    final fixture = chartFixture();
    fixture['terminals'] = [
      {'turnId': 'conflict', 'status': 'completed', 'durationMs': 50},
      {'turnId': 'same', 'status': 'completed', 'durationMs': 0},
      {'turnId': 'conflict', 'status': 'cancelled', 'durationMs': 50},
      {'turnId': 'same', 'status': 'completed', 'durationMs': 0},
      {'turnId': '', 'status': 'completed', 'durationMs': 10},
      {'turnId': 'unknown-status', 'status': 'future', 'durationMs': 10},
      'malformed',
    ];
    analysisOf(fixture)['recentResponses'] = [
      {'responseId': 'conflict', 'outputTokens': 10, 'reasoningTokens': 0},
      {'responseId': 'same', 'outputTokens': 0, 'reasoningTokens': 0},
      {'responseId': 'conflict', 'outputTokens': 11, 'reasoningTokens': 0},
      {'responseId': 'same', 'outputTokens': 0, 'reasoningTokens': 0},
      {'responseId': ' ', 'outputTokens': 10},
      {'responseId': 1, 'outputTokens': 10},
      null,
    ];
    final data = SessionChartData.fromData(fixture);
    expect(data.recentTerminals(24).map((s) => s.id), ['same']);
    expect(data.responses.map((s) => s.id), ['same']);
    expect(
      SessionChartData.fromData({'terminals': 'bad'}).recentTerminals(24),
      isEmpty,
    );
    expect(SessionChartData.fromData({'last': 'bad'}).responses, isEmpty);
    expect(SessionChartData.fromData(null).coverage, isNull);
    expect(SessionChartData.fromData(null).timeline.available, false);
  });

  test('catching up publishes no stable charts', () {
    final fixture = chartFixture()..['catchingUp'] = true;
    final data = SessionChartData.fromData(fixture);
    expect(data.catchingUp, true);
    expect(data.recentTerminals(64), isEmpty);
    expect(data.responses, isEmpty);
    expect(data.activities, isEmpty);
    expect(data.coverage, isNull);
    expect(data.usageMatchesTurn, isNull);
    expect(data.timeline.available, false);
  });
}
