import 'dart:async';

import 'package:codex_timezone/services/backend.dart';

Map<String, dynamic> globalSnapshotFixture({
  int revision = 1,
  String phase = 'partial',
  List<Map<String, dynamic>>? sessions,
  int offset = 0,
  bool hasMore = false,
}) => {
  'revision': revision,
  'indexEpoch': 1,
  'phase': phase,
  'observedAtMs': 1792965600000,
  'restored': false,
  'roots': [r'C:\synthetic-global'],
  'coverage': {
    'discovered': 205,
    'indexed': 203,
    'pending': 0,
    'unreadable': 1,
    'unsupported': 1,
  },
  'totals': {
    'quality': 'partial',
    'tokens': globalTokensFixture(1200, 300),
    'sessions': 203,
    'states': {
      'running': 2,
      'completed': 198,
      'cancelled': 1,
      'failed': 1,
      'unknown': 1,
    },
    'attention': {
      'input': null,
      'approval': null,
      'tool_pending': null,
      'unknown': 203,
    },
    'staleRunning': 1,
  },
  'daily': [
    {
      'key': '2026-10-26',
      'fromMs': 1792944000000,
      'toMs': 1793030400000,
      'tokens': globalTokensFixture(1200, 300),
      'sessions': 203,
    },
  ],
  'projects': [
    {
      'key': r'C:\synthetic\图像处理',
      'tokens': globalTokensFixture(900, 200),
      'sessions': 150,
    },
    {
      'key': r'C:\synthetic\long-project-name',
      'tokens': globalTokensFixture(300, 100),
      'sessions': 53,
    },
  ],
  'models': [
    {
      'key': 'synthetic-model-alpha',
      'tokens': globalTokensFixture(800, 200),
      'sessions': 130,
    },
    {
      'key': 'synthetic-model-beta',
      'tokens': globalTokensFixture(400, 100),
      'sessions': 73,
    },
  ],
  'sessions': sessions ?? [globalSessionFixture()],
  'filteredCount': 203,
  'offset': offset,
  'hasMore': hasMore,
  'warnings': ['synthetic_partial_coverage'],
};

Map<String, dynamic> globalTokensFixture(int input, int output) => {
  'inputTokens': input,
  'cachedInputTokens': 100,
  'cacheWriteInputTokens': null,
  'outputTokens': output,
  'reasoningTokens': 50,
  'totalTokens': input + output,
};

Map<String, dynamic> globalSessionFixture({
  String id = 'synthetic-thread-01',
  bool canOpenDetail = true,
  String state = 'running',
}) => {
  'path': r'C:\synthetic-global\sessions\rollout-synthetic.jsonl',
  'threadId': id,
  'sessionId': 'transport-session-01',
  'project': r'C:\synthetic\图像处理',
  'model': 'synthetic-model-alpha',
  'lifecycleState': state,
  'attentionState': 'unknown',
  'freshness': 'fresh',
  'lastEventMs': 1792965600000,
  'tokens': globalTokensFixture(1200, 300),
  'basis': 'identified_response_usage',
  'quality': 'partial',
  'reasons': ['synthetic_partial_coverage'],
  'canOpenDetail': canOpenDetail,
};

class GlobalFixtureBackend implements LauncherBackend {
  final calls = <Map<String, dynamic>>[];
  final pendingQueries = <Completer<Map<String, dynamic>>>[];
  bool holdQueries = false;
  Map<String, dynamic> snapshot = globalSnapshotFixture();
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command != 'global_monitor') throw StateError('unexpected_command');
    calls.add(Map.of(payload));
    if (payload['action'] == 'capabilities') {
      return {
        'globalVersion': 1,
        'localReadOnly': true,
        'modelRequests': false,
        'accountQueries': false,
        'queryScans': false,
      };
    }
    if (payload['action'] == 'query' && holdQueries) {
      final value = Completer<Map<String, dynamic>>();
      pendingQueries.add(value);
      return value.future;
    }
    return Map.of(snapshot);
  }
}
