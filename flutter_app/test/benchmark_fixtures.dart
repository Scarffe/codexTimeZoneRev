import 'dart:async';

import 'package:codex_timezone/services/backend.dart';

const metricKeys = [
  'ttftMs',
  'ttfoMs',
  'streamTokensPerSecond',
  'e2eTokensPerSecond',
  'fullResponseTokensPerSecond',
];
Map<String, dynamic> benchmarkFixture({
  String id = 'run-1',
  String state = 'completed',
  bool cleaning = false,
  String protocol = 'chat_completions',
  String? scenario,
  bool success = true,
}) => {
  'runId': id,
  'state': state,
  'measurementKind': 'independent_api',
  'protocol': protocol,
  'executionMode': 'offline_replay',
  'source': {
    'kind': 'offline_fixture',
    'scenarioId':
        scenario ??
        (protocol == 'responses'
            ? 'responses_text_complete'
            : 'chat_text_complete'),
    'networkScope': 'literal_loopback_only',
  },
  'requestedModel': 'fixture-model',
  'responseModel': 'fixture-response-model',
  'engineVersion': 'm3-rust-v1+aiperf-b1746a84',
  'cleanupPending': cleaning,
  'elapsedNs': 4000000000,
  'successfulSample': success,
  'protocolTerminal': protocol == 'responses'
      ? 'response.completed'
      : 'chat_done',
  'reasons': <String>[],
  'timingsNs': {
    'start': 0,
    'firstContent': 1000000000,
    'firstVisible': 1000000000,
    'lastContent': 3000000000,
    'lastVisible': 3000000000,
    'usage': 3500000000,
    'done': 3500000000,
    'httpEnd': 4000000000,
  },
  'usage': {'inputTokens': 10, 'outputTokens': 100, 'reasoningTokens': 0},
  'metrics': {
    for (final key in metricKeys)
      key: {
        'value': key.endsWith('Ms') ? 1000.0 : 25.0,
        'unit': key.endsWith('Ms') ? 'ms' : 'tokens/s',
        'quality': key == 'streamTokensPerSecond' ? 'estimated' : 'reported',
        'reasons': key == 'streamTokensPerSecond'
            ? ['first_chunk_assumed_one']
            : <String>[],
        'numeratorTokens': key.endsWith('Ms') ? null : 100,
        'denominatorNs': key.endsWith('Ms') ? 1000000000 : 4000000000,
        'countSource': key.endsWith('Ms')
            ? 'monotonic_clock'
            : 'reported_completion_tokens_including_reasoning',
      },
  },
};

class BenchmarkBackend implements LauncherBackend {
  final calls = <String>[];
  final payloads = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? pendingStart,
      pendingStatus,
      pendingShutdown,
      pendingCancel;
  String state = 'streaming';
  bool cleaning = true;
  int sequence = 0;
  String protocol = 'chat_completions', scenario = 'chat_text_complete';
  bool malformedStart = false;
  Future<void> Function()? beforeStart;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add(command);
    payloads.add(Map.of(payload));
    if (command == 'benchmark_catalog') {
      return {
        'offlineOnly': true,
        'liveExecutionEnabled': false,
        'protocols': ['chat_completions', 'responses'],
        'scenarios': [
          for (final p in ['chat_completions', 'responses'])
            for (final s in [
              'text_complete',
              'reasoning_complete',
              'missing_usage',
              'truncated',
              'slow',
              if (p == 'responses') ...['failed', 'incomplete'],
            ])
              {
                'scenarioId': '${p == 'responses' ? 'responses' : 'chat'}_$s',
                'protocol': p,
                'label': s,
                'description': s,
              },
        ],
      };
    }
    if (command == 'benchmark_start') {
      await beforeStart?.call();
      sequence++;
      protocol = payload['protocol'] as String;
      scenario = payload['scenarioId'] as String;
      if (malformedStart) {
        return benchmarkFixture(
          id: 'run-$sequence',
          state: 'streaming',
          cleaning: true,
        )..['elapsedNs'] = -1;
      }
      return pendingStart?.future ??
          benchmarkFixture(
            id: 'run-$sequence',
            state: state,
            cleaning: cleaning,
            protocol: protocol,
            scenario: scenario,
          );
    }
    if (command == 'benchmark_clear') {
      return {'cleared': true, 'runId': payload['runId']};
    }
    if (command == 'benchmark_shutdown') {
      state = 'cancelled';
      cleaning = false;
      return pendingShutdown?.future ??
          {
            'accepting': false,
            'cleanupComplete': true,
            'runId': payload['runId'],
          };
    }
    if (command == 'benchmark_cancel' || command == 'benchmark_interrupt') {
      state = command == 'benchmark_cancel' ? 'cancelled' : 'interrupted';
      cleaning = false;
      if (pendingCancel != null) return pendingCancel!.future;
    }
    if (command == 'benchmark_status' && pendingStatus != null) {
      return pendingStatus!.future;
    }
    return benchmarkFixture(
      id: 'run-$sequence',
      state: state,
      cleaning: cleaning,
      protocol: protocol,
      scenario: scenario,
      success: state == 'completed',
    );
  }
}
