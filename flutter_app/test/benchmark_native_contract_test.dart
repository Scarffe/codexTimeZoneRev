import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all twelve fresh native C ABI synthetic observations parse without semantic loss', () {
    // Captured by root's loopback-only release ABI acceptance at 0ac1bab.
    // DLL SHA256 59563cb5f1ce94331e07e68193a61c30460b49f1bbf8eeb40e6f7f9dc309c475.
    // These are historic observations only. No manager call or native DLL load.
    final observations = jsonDecode(
      File('test/fixtures/benchmark-native-m3.json').readAsStringSync(),
    ) as List;
    expect(observations, hasLength(12));
    for (final raw in observations) {
      final snapshot = BenchmarkSnapshot.fromJson(raw as Map<String, dynamic>);
      expect(snapshot.toJson(), raw);
      expect(snapshot.requestedModel, 'fixture-model');
      expect(snapshot.responseModel, anyOf(isNull, 'fixture-response-model'));
      expect(snapshot.cleanupPending, false);
      expect(snapshot.metrics.keys, unorderedEquals(benchmarkMetricKeys));
      expect(snapshot.scenarioId, isIn(benchmarkScenarios));
    }
  });
}
