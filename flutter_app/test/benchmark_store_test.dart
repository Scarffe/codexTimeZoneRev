import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/services/benchmark_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';

void main() {
  late Directory temp;
  late BenchmarkStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tz-benchmark-store-');
    store = BenchmarkStore(File('${temp.path}/state.json'));
  });
  tearDown(() async => temp.delete(recursive: true));
  test('fresh allowlist serialization strips arbitrary nested data', () async {
    final raw = benchmarkFixture()
      ..['prompt'] = 'secret'
      ..['url'] = 'https://secret.invalid';
    (raw['metrics'] as Map)['ttftMs']['answer'] = 'secret';
    final snapshot = BenchmarkSnapshot.fromJson(raw);
    await store.write(
      BenchmarkRecord(
        protocol: 'chat_completions',
        scenarioId: 'chat_text_complete',
        attemptId: 'attempt-1',
        snapshot: snapshot,
      ),
    );
    final text = await store.file.readAsString();
    expect(text, isNot(contains('secret')));
    expect((await store.read())!.snapshot!.metrics.length, 5);
  });
  test(
    'corrupt journal is preserved until next write then backed up',
    () async {
      await store.file.writeAsString('{broken');
      await expectLater(store.read(), throwsFormatException);
      expect(await store.file.readAsString(), '{broken');
      await store.write(
        const BenchmarkRecord(
          protocol: 'responses',
          scenarioId: 'responses_slow',
        ),
      );
      final backups = await temp
          .list()
          .where((f) => f.path.endsWith('.bak'))
          .toList();
      expect(backups, hasLength(1));
      expect(await File(backups.single.path).readAsString(), '{broken');
    },
  );
  test('parser rejects nonfinite negative counts and unsafe fields', () {
    for (final invalid in [double.nan, double.infinity, -1]) {
      final raw = benchmarkFixture();
      raw['metrics']['ttftMs']['value'] = invalid;
      expect(() => BenchmarkSnapshot.fromJson(raw), throwsFormatException);
    }
    final raw = benchmarkFixture();
    raw['source']['scenarioId'] = 'https://secret.invalid';
    expect(() => BenchmarkSnapshot.fromJson(raw), throwsFormatException);
    final record = BenchmarkRecord.fromJson({
      'version': 1,
      'protocol': 'responses',
      'scenarioId': 'responses_slow',
      'apiKey': 'secret',
    });
    expect(jsonEncode(record.toJson()), isNot(contains('secret')));
    final arbitraryModel = benchmarkFixture()..['requestedModel'] = 'sk-secret';
    expect(
      () => BenchmarkSnapshot.fromJson(arbitraryModel),
      throwsFormatException,
    );
    final missingElapsed = benchmarkFixture()..['elapsedNs'] = null;
    expect(
      () => BenchmarkSnapshot.fromJson(missingElapsed),
      throwsFormatException,
    );
    final missingDenominator = benchmarkFixture();
    missingDenominator['metrics']['e2eTokensPerSecond']['denominatorNs'] = null;
    expect(
      () => BenchmarkSnapshot.fromJson(missingDenominator),
      throwsFormatException,
    );
    final missingOutput = benchmarkFixture();
    missingOutput['usage'] = {
      ...Map<String, dynamic>.from(missingOutput['usage'] as Map),
      'outputTokens': null,
    };
    expect(
      () => BenchmarkSnapshot.fromJson(missingOutput),
      throwsFormatException,
    );
  });
}
