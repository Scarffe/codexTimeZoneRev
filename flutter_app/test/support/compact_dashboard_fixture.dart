// Test-only synthetic facts shared by widget renders and the unshipped native
// acceptance entry. No IO, native calls, networking, or flutter_test dependency.
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/account_usage.dart';

enum CompactDashboardScenario {
  populated,
  dense64,
  manyGroups,
  longLabel,
  empty,
  error,
  partial,
}

const compactDashboardSessionPath =
    r'C:\synthetic-only\compact-dashboard.jsonl';
const _sessionId = 'synthetic-compact-dashboard-session';
final _instant = DateTime.utc(2026, 10, 23, 8, 30);

Map<String, dynamic> compactDashboardSessionData({
  CompactDashboardScenario scenario = CompactDashboardScenario.populated,
}) {
  final partial = scenario == CompactDashboardScenario.partial;
  final long = scenario == CompactDashboardScenario.longLabel;
  final empty = scenario == CompactDashboardScenario.empty;
  return {
    'sourceInfo': {
      'id': _sessionId,
      'path': compactDashboardSessionPath,
      'cwd': r'C:\synthetic-only',
      'title': long ? List.filled(8, '合成验收会话长名称').join() : '合成视觉验收会话',
      'modifiedMs': _instant.millisecondsSinceEpoch,
    },
    'logEpoch': 1,
    'current': {'turnId': 'synthetic-current-cancelled', 'status': 'cancelled'},
    'measurement': {
      'kind': 'observed_turn',
      'sourceLabel': '合成会话 · 本地只读日志格式',
      'sessionId': _sessionId,
      'tokenSource': 'turn_token_usage.output_tokens',
      'durationSource': 'task_complete.duration_ms',
      'outputIncludesReasoning': true,
    },
    'quality': {
      'status': empty ? 'incomplete' : 'verified',
      'reasons': <String>[],
    },
    'terminals': [
      if (!empty)
        for (var i = 0; i < 64; i++)
          {
            'turnId': 'synthetic-terminal-$i',
            'status': i % 11 == 0 ? 'cancelled' : 'completed',
            'durationMs': i % 11 == 0 || i % 13 == 0
                ? null
                : i == 1
                ? 0
                : 1000 + (i * 613) % 23000,
          },
    ],
    'verifiedGroups': [
      if (!empty)
        for (
          var i = 0;
          i < (scenario == CompactDashboardScenario.manyGroups ? 20 : 3);
          i++
        )
          {
            'sessionId': _sessionId,
            'model': long
                ? 'synthetic-model-with-a-very-long-configuration-name-$i'
                : 'synthetic-model-${i + 1}',
            'effort': i.isEven ? 'high' : 'medium',
            'serviceTier': i == 2 ? 'priority' : 'default',
            'turnCount': 2 + i,
            'outputTokens': 100 + i * 100,
            'durationMs': 10000 + i * 5000,
            'tokensPerSecond': (100 + i * 100) / (10 + i * 5),
          },
    ],
    if (!empty)
      'last': {
        'turnId': 'synthetic-completed',
        'outputTokens': 100,
        'reasoningTokens': 20,
        'durationMs': 10000,
        'firstTokenMs': 1000,
        'tokensPerSecond': 10.0,
        'verifiedTokensPerSecond': 10.0,
        'quality': {'status': 'verified', 'reasons': <String>[]},
        'analysis': {
          'partial': partial,
          'coverageValid': !partial,
          'observedMs': 7500,
          'unclassifiedMs': 2500,
          'overlapMs': 2000,
          'messageMs': 3000,
          'reasoningMs': 3000,
          'toolMs': 3000,
          'otherMs': 500,
          'responseCount': 6,
          'responseOutputTokens': 100,
          'usageMatchesTurn': !partial,
          'recentResponses': [
            for (var i = 0; i < 6; i++)
              {
                'responseId': 'synthetic-response-$i',
                'outputTokens': [10, 15, 20, 25, 15, 15][i],
                'reasoningTokens': partial && i == 2
                    ? null
                    : [1, 2, 4, 5, 3, 5][i],
              },
          ],
          'timeline': {
            'version': 1,
            'coordinateKind': 'logged_turn_window',
            'limit': 200,
            'order': 'start_end_id',
            'totalItems': 4,
            'shownItems': 4,
            'startEpochMs': 100000,
            'endEpochMsExclusive': 110000,
            'spanMs': 10000,
            'boundsResolutionMs': 1000,
            'sourcePartial': partial,
            'coverageInterpretation': partial ? 'unavailable' : 'approximate',
            'omittedItems': 0,
            'items': [
              for (final (ordinal, category, start, end) in [
                (1, 'message', 1000, 4000),
                (2, 'reasoning', 2000, 5000),
                (3, 'tool', 5000, 8000),
                (4, 'other', 8500, 9000),
              ])
                {
                  'ordinal': ordinal,
                  'category': category,
                  'startedAtMs': 100000 + start,
                  'completedAtMs': 100000 + end,
                  'offsetStartMs': start,
                  'offsetEndMs': end,
                  'durationMs': end - start,
                  'drawable': true,
                  'reasons': <String>[],
                },
            ],
          },
        },
      },
  };
}

class CompactDashboardBackend implements LauncherBackend {
  CompactDashboardBackend({this.scenario = CompactDashboardScenario.populated});
  final CompactDashboardScenario scenario;
  final List<String> calls = [];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add(command);
    if (command == 'bootstrap' && payload.isEmpty) {
      return {
        'settings': {
          'mode': 'zone',
          'zoneId': 'Asia/Shanghai',
          'offset': 8,
          'executable': '',
          'dreamSkinCompatible': false,
        },
        'zones': [
          {'id': 'Asia/Shanghai', 'label': '中国标准时间（上海 / 北京）'},
        ],
        'detected': '',
        'platform': 'windows',
      };
    }
    if (command == 'session_metrics') {
      final value = compactDashboardSessionData(scenario: scenario);
      if (payload.length == 1 && payload['action'] == 'list') {
        return {
          'sessions': [value['sourceInfo']],
        };
      }
      if (payload.length == 1 &&
          payload['path'] == compactDashboardSessionPath) {
        if (scenario == CompactDashboardScenario.error) {
          throw StateError('synthetic_session_read_failure');
        }
        return value;
      }
    }
    throw StateError('synthetic_fixture_operation_denied');
  }
}

class CompactDashboardUsageService implements AccountUsageService {
  CompactDashboardUsageService({
    this.scenario = CompactDashboardScenario.populated,
  });
  final CompactDashboardScenario scenario;
  int calls = 0;
  @override
  Future<AccountUsage> query(String desktopPath) async {
    calls++;
    if (desktopPath.isNotEmpty) {
      throw StateError('synthetic_fixture_path_denied');
    }
    if (scenario == CompactDashboardScenario.error) {
      throw StateError('synthetic_account_read_failure');
    }
    return AccountUsage(
      email: 'synthetic-account@example.test',
      identityKey: 'synthetic-account',
      plan: 'synthetic',
      fetchedAt: _instant,
      tokensFetchedAt: _instant,
      lifetimeTokens: 1234567,
      latestDailyTokens: 12345,
      latestDate: '2026-10-23',
      tokensError: scenario == CompactDashboardScenario.partial
          ? 'synthetic_token_partial_failure'
          : null,
      buckets: [
        if (scenario != CompactDashboardScenario.empty)
          UsageBucket(
            label: 'Synthetic Codex',
            windows: [
              UsageWindow(
                usedPercent: 28,
                durationMinutes: 300,
                resetsAt: DateTime.utc(2026, 10, 24),
              ),
              UsageWindow(
                usedPercent: scenario == CompactDashboardScenario.partial
                    ? null
                    : 54,
                durationMinutes: 10080,
                resetsAt: DateTime.utc(2026, 10, 30),
              ),
            ],
          ),
      ],
    );
  }
}
