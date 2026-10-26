import 'dart:async';

import 'package:codex_timezone/services/backend.dart';

Map<String, dynamic> taskFixture({
  String id = 'task-test-1',
  String state = 'prepared',
  String mode = 'offline_preview',
  String source = 'preview-a',
  int generation = 1,
}) => {
  'taskId': id,
  'mode': mode,
  'sourceId': source,
  'sourceEpoch': 41,
  'generation': generation,
  'workspace': 'synthetic-workspace-a',
  'model': 'synthetic-model',
  'sandbox': 'read-only',
  'state': state,
  'threadId': null,
  'turnId': null,
  'output': 'session-only output',
  'outputTruncated': false,
  'approvals': <dynamic>[],
  'inputRequests': <dynamic>[],
  'usage': null,
  'cleanupPending': false,
  'errorKind': null,
  'observedIdentity': null,
  'strongPrincipalVerified': false,
};

class TasksBackend implements LauncherBackend {
  final calls = <String>[];
  final payloads = <Map<String, dynamic>>[];
  final tasks = <String, Map<String, dynamic>>{};
  Completer<Map<String, dynamic>>? pendingStart,
      pendingPrepare,
      pendingStatus,
      pendingCancel;
  int sequence = 0;
  String? startError;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add(command);
    payloads.add(Map.of(payload));
    if (command == 'task_catalog') {
      return {
        'adapterAvailable': true,
        'officialExecutionValidated': false,
        'strongPrincipalVerified': false,
        'maxRunning': 2,
        'previewSources': ['preview-a', 'preview-b'],
        'modes': ['offline_preview', 'official'],
        'sandboxes': ['read-only', 'workspace-write'],
      };
    }
    if (command == 'task_prepare') {
      if (pendingPrepare != null) return pendingPrepare!.future;
      final value = taskFixture(
        id: 'task-test-${++sequence}',
        mode: payload['mode'] as String,
        source: payload['sourceId'] as String,
      );
      for (final key in ['workspace', 'model', 'sandbox']) {
        value[key] = payload[key];
      }
      tasks[value['taskId'] as String] = value;
      return Map.of(value);
    }
    if (command == 'task_shutdown') {
      return {'accepting': false, 'cleanupComplete': true};
    }
    if (command == 'task_list') return {'tasks': tasks.values.toList()};
    final id = payload['taskId'] as String;
    final task = tasks[id]!;
    if (command == 'task_status' && pendingStatus != null) {
      return pendingStatus!.future;
    }
    if (command == 'task_start') {
      if (startError != null) throw StateError(startError!);
      if (pendingStart != null) return pendingStart!.future;
      task['state'] = 'running';
    }
    if (command == 'task_cancel') {
      if (pendingCancel != null) return pendingCancel!.future;
      task['state'] = 'cancelled';
      task['cleanupPending'] = false;
    }
    if (command == 'task_clear') {
      tasks.remove(id);
      return {'taskId': id, 'cleared': true};
    }
    if (command == 'task_approval') task['approvals'] = <dynamic>[];
    if (command == 'task_input') task['inputRequests'] = <dynamic>[];
    return Map.of(task);
  }
}
