// Unshipped synthetic data shared by renders and the isolated desktop entry.
// No native backend, file reads, credentials, CLI, model or network requests.
import 'dart:async';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/services/memory_attention_store.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';

import 'compact_dashboard_fixture.dart';
import 'multi_account_fixture.dart';
import '../benchmark_fixtures.dart';

const workspacePathA = r'C:\synthetic-only\workspace-A.jsonl';
const workspacePathB = r'C:\synthetic-only\workspace-B.jsonl';

class WorkspaceAttentionBackend implements SyntheticSessionBackend {
  final values = <String, Map<String, dynamic>>{};
  final failures = <String>{};
  final calls = <String>[];
  WorkspaceAttentionBackend() {
    transition(workspacePathA, 'a-current', 'running');
    transition(workspacePathB, 'b-history', 'completed');
  }
  void transition(String path, String turn, String status) {
    final id = path == workspacePathA ? 'synthetic-A' : 'synthetic-B';
    final history = compactDashboardSessionData();
    values[path] = {
      ...history,
      'measurement': {
        ...history['measurement'] as Map<String, dynamic>,
        'sessionId': id,
      },
      'verifiedGroups': [
        for (final group in history['verifiedGroups'] as List)
          {...group as Map<String, dynamic>, 'sessionId': id},
      ],
      'catchingUp': false,
      'sourceInfo': {
        'id': id,
        'path': path,
        'cwd': r'C:\synthetic-only',
        'title': path == workspacePathA ? '合成 A · 图像处理' : '合成 B · 课程草稿',
      },
      'current': {'turnId': turn, 'status': status},
      'terminals': [
        for (var i = 0; i < 8; i++)
          {
            'turnId': 'history-$i',
            'status': i == 3 ? 'cancelled' : 'completed',
            'durationMs': i == 3 ? null : 3000 + i * 1300,
          },
        if (status != 'running')
          {'turnId': turn, 'status': status, 'durationMs': 12000},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add('$command:${payload['path'] ?? payload['action'] ?? ''}');
    if (command == 'bootstrap') return const PreviewBackend().call('bootstrap');
    if (command == 'session_metrics') {
      if (payload['action'] == 'list') {
        return {'sessions': values.values.map((v) => v['sourceInfo']).toList()};
      }
      final path = payload['path'];
      if (failures.contains(path) || !values.containsKey(path)) {
        throw StateError('synthetic_read_unavailable');
      }
      return values[path]!;
    }
    throw StateError('synthetic_workspace_operation_denied');
  }
}

class WorkspaceAttentionFixture {
  WorkspaceAttentionFixture._(
    this.backend,
    this.attention,
    this.metrics,
    this.sources,
    this.sourceService,
    this.benchmark,
  );
  final WorkspaceAttentionBackend backend;
  final SessionAttentionController attention;
  final SessionMetricsController metrics;
  final AccountSourcesController sources;
  final SyntheticMultiSources sourceService;
  final BenchmarkController benchmark;
  static Future<WorkspaceAttentionFixture> create() async {
    final multi = await syntheticMultiFixture();
    multi.metrics.dispose();
    final backend = WorkspaceAttentionBackend();
    final attention = SessionAttentionController(backend);
    await attention.initialize(MemoryAttentionStore());
    await attention.refreshSessions();
    await attention.watch(workspacePathA);
    await attention.watch(workspacePathB);
    await attention.poll(); // Historical B completion is silent.
    final metrics = SessionMetricsController(backend);
    await metrics.list();
    metrics.select(workspacePathB, expectedId: 'synthetic-B');
    await Future<void>.value();
    final benchmark = BenchmarkController(
      BenchmarkService(BenchmarkBackend()),
      pollInterval: const Duration(days: 1),
    );
    await benchmark.initialize();
    return WorkspaceAttentionFixture._(
      backend,
      attention,
      metrics,
      multi.owner,
      multi.service,
      benchmark,
    );
  }

  Future<void> completeA() async {
    backend.transition(workspacePathA, 'a-current', 'completed');
    await attention.poll();
  }

  Future<void> cancelB() async {
    backend.transition(workspacePathB, 'b-cancelled', 'cancelled');
    await attention.poll();
    await metrics.poll();
  }

  Future<void> unreadableB() async {
    backend.failures.add(workspacePathB);
    await attention.poll();
  }
}
