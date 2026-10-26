import 'dart:convert';

import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/services/benchmark_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';

Map<String, dynamic> liveObservation() => benchmarkFixture()
  ..['executionMode'] = 'live'
  ..['source'] = {
    'kind': 'user_endpoint',
    'scenarioId': null,
    'networkScope': 'user_configured_endpoint',
  }
  ..['engineVersion'] = 'm4-rust-v1+aiperf-b1746a84'
  ..['requestedModel'] = 'provider/model v1'
  ..['responseModel'] = 'provider/model v2';

void main() {
  test(
    'catalog accepts live capability while preserving offline scenarios',
    () async {
      final raw = await BenchmarkBackend().call('benchmark_catalog');
      raw['offlineOnly'] = false;
      raw['liveExecutionEnabled'] = true;
      final parsed = BenchmarkCatalog.fromJson(raw);
      expect(parsed.scenarios, hasLength(12));
      expect(
        parsed.scenarios.map((s) => s.protocol),
        containsAll(benchmarkProtocols),
      );
    },
  );

  test('live observation roundtrip preserves origin and strips private request facts', () {
    final raw = liveObservation()
      ..['apiKey'] = 'SYNTHETIC_SECRET_NOT_FOR_STORAGE'
      ..['prompt'] = 'SYNTHETIC_PROMPT_NOT_FOR_STORAGE'
      ..['baseUrl'] = 'https://synthetic-private.invalid/v1'
      ..['resolvedProxy'] = 'PROXY synthetic-private.invalid:8080';
    final parsed = BenchmarkSnapshot.fromJson(raw);
    final saved = parsed.copy(state: 'cancelled').recover().toJson();
    expect(saved['executionMode'], 'live');
    expect(saved['source'], {
      'kind': 'user_endpoint',
      'scenarioId': null,
      'networkScope': 'user_configured_endpoint',
    });
    expect(saved['requestedModel'], 'provider/model v1');
    expect(saved['responseModel'], 'provider/model v2');
    expect(parsed.scenarioId, isEmpty);
    final serialized = jsonEncode(saved);
    expect(serialized, isNot(contains('SYNTHETIC_SECRET')));
    expect(serialized, isNot(contains('SYNTHETIC_PROMPT')));
    expect(serialized, isNot(contains('synthetic-private.invalid')));
    expect(
      BenchmarkSnapshot.fromJson(Map<String, dynamic>.from(saved)).toJson(),
      saved,
    );
  });

  test('v2 live journal restores as live interrupted without credentials or auto ownership', () {
    final raw = liveObservation()
      ..['state'] = 'streaming'
      ..['successfulSample'] = false;
    final record = BenchmarkRecord.fromJson({
      'version': 2,
      'executionMode': 'live',
      'protocol': 'chat_completions',
      'scenarioId': null,
      'attemptId': 'attempt-1',
      'starting': false,
      'snapshot': raw,
      'apiKey': 'SYNTHETIC_SECRET',
      'prompt': 'SYNTHETIC_PROMPT',
    });
    final snapshot = record.snapshot!.recover();
    expect(snapshot.state, 'interrupted');
    expect(snapshot.toJson()['executionMode'], 'live');
    expect(record.toJson()['version'], 2);
    expect(jsonEncode(record.toJson()), isNot(contains('SYNTHETIC_')));
  });
}
