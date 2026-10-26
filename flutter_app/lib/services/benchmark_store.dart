import 'dart:convert';
import 'dart:io';

import 'benchmark.dart';

class BenchmarkRecord {
  const BenchmarkRecord({
    required this.protocol,
    required this.scenarioId,
    this.attemptId,
    this.starting = false,
    this.snapshot,
    this.observedAtMs,
    this.executionMode = 'offline_replay',
  });
  final String protocol, scenarioId;
  final String executionMode;
  final String? attemptId;
  final bool starting;
  final BenchmarkSnapshot? snapshot;
  final int? observedAtMs;
  factory BenchmarkRecord.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 && json['version'] != 2) {
      throw const FormatException('invalid_benchmark_journal');
    }
    final protocol = benchmarkChoice(json['protocol'], benchmarkProtocols);
    final mode = json['version'] == 1
        ? 'offline_replay'
        : benchmarkChoice(json['executionMode'], ['offline_replay', 'live']);
    if (mode == 'live' &&
        json['scenarioId'] != null &&
        json['scenarioId'] != '') {
      throw const FormatException('invalid_benchmark_scenario');
    }
    final scenario = mode == 'live'
        ? ''
        : benchmarkChoice(json['scenarioId'], benchmarkScenarios);
    if (mode != 'live' &&
        !scenario.startsWith(
          protocol == 'responses' ? 'responses_' : 'chat_',
        )) {
      throw const FormatException('invalid_benchmark_scenario');
    }
    final attempt = json['attemptId'];
    if (attempt != null &&
        (attempt is! String ||
            !RegExp(r'^attempt-[0-9-]{1,60}$').hasMatch(attempt))) {
      throw const FormatException('invalid_benchmark_attempt');
    }
    final snapshot = json['snapshot'] == null
        ? null
        : BenchmarkSnapshot.fromJson(benchmarkMap(json['snapshot']));
    return BenchmarkRecord(
      protocol: protocol,
      scenarioId: scenario,
      executionMode: mode,
      attemptId: attempt as String?,
      starting: json['starting'] == true,
      snapshot: snapshot,
      observedAtMs: benchmarkInteger(json['observedAtMs']),
    );
  }
  Map<String, Object?> toJson() => {
    'version': 2,
    'executionMode': executionMode,
    'protocol': protocol,
    'scenarioId': executionMode == 'live' ? null : scenarioId,
    'attemptId': attemptId,
    'starting': starting,
    'observedAtMs': observedAtMs,
    'snapshot': snapshot?.toJson(),
  };
}

/// Last saved observation, not a claim of per-event durable logging.
class BenchmarkStore {
  BenchmarkStore(this.file);
  factory BenchmarkStore.portable() => BenchmarkStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/benchmark-state-v1.json',
    ),
  );
  final File file;
  bool _backupBeforeWrite = false;
  Future<void> _writes = Future.value();
  Future<BenchmarkRecord?> read() async {
    if (!await file.exists()) return null;
    try {
      return BenchmarkRecord.fromJson(
        benchmarkMap(jsonDecode(await file.readAsString())),
      );
    } catch (_) {
      _backupBeforeWrite = true;
      rethrow;
    }
  }

  Future<void> write(BenchmarkRecord record) {
    // Reparse the fresh DTO to enforce the same allowlist on all write paths.
    final text = jsonEncode(
      BenchmarkRecord.fromJson(benchmarkMap(record.toJson())).toJson(),
    );
    final write = _writes.then((_) async {
      if (_backupBeforeWrite && await file.exists()) {
        await file.copy(
          '${file.path}.invalid-${DateTime.now().microsecondsSinceEpoch}.bak',
        );
        _backupBeforeWrite = false;
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
