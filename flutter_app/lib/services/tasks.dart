import 'backend.dart';

const taskModes = {'offline_preview', 'official'};
const taskSandboxes = {'read-only', 'workspace-write'};
const taskStates = {
  'prepared',
  'starting',
  'running',
  'awaiting_approval',
  'awaiting_input',
  'cancelling',
  'completed',
  'cancelled',
  'failed',
  'interrupted',
};
const taskErrorKinds = {
  'invalid_request',
  'unsupported',
  'source_invalid',
  'source_busy',
  'workspace_busy',
  'auth_required',
  'identity_changed',
  'isolation_failed',
  'policy_mismatch',
  'cli_changed',
  'startup_failed',
  'protocol_error',
  'unsupported_request',
  'cancelled',
  'timeout',
  'disconnected',
  'shutdown',
  'cleanup_failed',
  'interrupted_previous_process',
  'unknown',
  'store_failed',
};

String taskErrorKind(Object? value) =>
    value is String && taskErrorKinds.contains(value) ? value : 'unknown';

class TaskFailure implements Exception {
  const TaskFailure(this.kind);
  final String kind;
  @override
  String toString() => 'TaskFailure(${taskErrorKind(kind)})';
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_task');
  }
  return value;
}

String _text(Object? value, {bool empty = false, int max = 32768}) {
  if (value is! String || (!empty && value.isEmpty) || value.length > max) {
    throw const FormatException('invalid_task');
  }
  return value;
}

int _positive(Object? value) {
  if (value is! int || value <= 0) {
    throw const FormatException('invalid_task_identity');
  }
  return value;
}

List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) parse) {
  if (value is! List || value.length > 256) {
    throw const FormatException('invalid_task');
  }
  return List.unmodifiable(value.map((v) => parse(_map(v))));
}

String? _nullableText(Object? value) => value == null ? null : _text(value);

class TaskCatalog {
  const TaskCatalog({
    required this.adapterAvailable,
    required this.maxRunning,
    required this.previewSources,
  });
  final bool adapterAvailable;
  final int maxRunning;
  final List<String> previewSources;
  factory TaskCatalog.fromJson(Map<String, dynamic> json) {
    final sources = json['previewSources'];
    if (json['adapterAvailable'] is! bool ||
        json['maxRunning'] != 2 ||
        sources is! List ||
        !sources.contains('preview-a') ||
        !sources.contains('preview-b') ||
        json['strongPrincipalVerified'] != false ||
        json['officialExecutionValidated'] != false ||
        json['modes'] is! List ||
        !(json['modes'] as List).contains('offline_preview') ||
        json['sandboxes'] is! List ||
        !(json['sandboxes'] as List).contains('read-only')) {
      throw const FormatException('invalid_task_catalog');
    }
    return TaskCatalog(
      adapterAvailable: json['adapterAvailable'] as bool,
      maxRunning: 2,
      previewSources: List.unmodifiable(
        sources.whereType<String>().where(
          (s) => s == 'preview-a' || s == 'preview-b',
        ),
      ),
    );
  }
}

class TaskApproval {
  const TaskApproval(
    this.approvalId,
    this.kind,
    this.summary,
    this.command,
    this.cwd,
    this.files, [
    this.decisions = const ['accept', 'decline', 'cancel'],
  ]);
  final String approvalId, kind, summary;
  final String? command, cwd;
  final List<String> files;
  final List<String> decisions;
  factory TaskApproval.fromJson(Map<String, dynamic> json) {
    if (!{'command', 'file'}.contains(json['kind']) || json['files'] is! List) {
      throw const FormatException('invalid_task_approval');
    }
    final rawDecisions = json.containsKey('decisions')
        ? json['decisions']
        : const ['accept', 'decline', 'cancel'];
    if (rawDecisions is! List ||
        rawDecisions.isEmpty ||
        rawDecisions.length > 3 ||
        rawDecisions.any(
          (value) =>
              value is! String ||
              !{'accept', 'decline', 'cancel'}.contains(value),
        ) ||
        rawDecisions.toSet().length != rawDecisions.length) {
      throw const FormatException('invalid_task_approval_decisions');
    }
    return TaskApproval(
      _text(json['approvalId'], max: 512),
      json['kind'] as String,
      _text(json['summary'], empty: true),
      _nullableText(json['command']),
      _nullableText(json['cwd']),
      List.unmodifiable((json['files'] as List).map((v) => _text(v))),
      List.unmodifiable(rawDecisions.cast<String>()),
    );
  }
}

class TaskQuestionOption {
  const TaskQuestionOption(this.label, this.description);
  final String label, description;
  factory TaskQuestionOption.fromJson(Map<String, dynamic> json) =>
      TaskQuestionOption(
        _text(json['label']),
        _text(json['description'], empty: true),
      );
}

class TaskQuestion {
  const TaskQuestion(
    this.id,
    this.header,
    this.question,
    this.isOther,
    this.isSecret,
    this.options,
  );
  final String id, header, question;
  final bool isOther, isSecret;
  final List<TaskQuestionOption> options;
  factory TaskQuestion.fromJson(Map<String, dynamic> json) {
    if (json['isOther'] is! bool || json['isSecret'] is! bool) {
      throw const FormatException('invalid_task_question');
    }
    return TaskQuestion(
      _text(json['id']),
      _text(json['header'], empty: true),
      _text(json['question'], empty: true),
      json['isOther'] as bool,
      json['isSecret'] as bool,
      _list(json['options'] ?? [], TaskQuestionOption.fromJson),
    );
  }
}

class TaskInputRequest {
  const TaskInputRequest(this.requestId, this.questions);
  final String requestId;
  final List<TaskQuestion> questions;
  factory TaskInputRequest.fromJson(Map<String, dynamic> json) =>
      TaskInputRequest(
        _text(json['requestId'], max: 512),
        _list(json['questions'], TaskQuestion.fromJson),
      );
}

class TaskUsage {
  const TaskUsage(this.inputTokens, this.outputTokens, this.reasoningTokens);
  final int? inputTokens, outputTokens, reasoningTokens;
  factory TaskUsage.fromJson(Map<String, dynamic> json) {
    int? count(String key) {
      final value = json[key];
      if (value != null && (value is! int || value < 0)) {
        throw const FormatException('invalid_task_usage');
      }
      return value as int?;
    }

    if (json['scope'] != 'thread_total') {
      throw const FormatException('invalid_task_usage');
    }
    return TaskUsage(
      count('inputTokens'),
      count('outputTokens'),
      count('reasoningTokens'),
    );
  }
}

/// Immutable observations. Restoration never reclaims a backend process.
class TaskSnapshot {
  const TaskSnapshot({
    required this.taskId,
    required this.mode,
    required this.sourceId,
    required this.sourceEpoch,
    required this.generation,
    required this.workspace,
    required this.model,
    required this.sandbox,
    required this.state,
    this.threadId,
    this.turnId,
    this.output = '',
    this.outputTruncated = false,
    this.approvals = const [],
    this.inputRequests = const [],
    this.usage,
    this.cleanupPending = false,
    this.errorKind,
    this.observedIdentity,
    this.restored = false,
  });
  final String taskId, mode, sourceId, workspace, model, sandbox, state, output;
  final int sourceEpoch, generation;
  final String? threadId, turnId, errorKind;
  final bool outputTruncated, cleanupPending, restored;
  final List<TaskApproval> approvals;
  final List<TaskInputRequest> inputRequests;
  final TaskUsage? usage;
  final Map<String, String?>? observedIdentity;
  bool get terminal =>
      {'completed', 'cancelled', 'failed', 'interrupted'}.contains(state);
  bool get active => state != 'prepared' && (!terminal || cleanupPending);
  Map<String, dynamic> get identity => {
    'taskId': taskId,
    'sourceEpoch': sourceEpoch,
    'generation': generation,
  };
  bool sameIdentity(TaskSnapshot other) =>
      taskId == other.taskId &&
      sourceEpoch == other.sourceEpoch &&
      generation == other.generation;

  /// The client lost the start acknowledgement. Cleanup remains unconfirmed;
  /// this is not evidence of a backend terminal event or permission to retry.
  TaskSnapshot unconfirmedStart() => TaskSnapshot(
    taskId: taskId,
    mode: mode,
    sourceId: sourceId,
    sourceEpoch: sourceEpoch,
    generation: generation,
    workspace: workspace,
    model: model,
    sandbox: sandbox,
    state: 'interrupted',
    threadId: threadId,
    turnId: turnId,
    output: output,
    outputTruncated: outputTruncated,
    approvals: approvals,
    inputRequests: inputRequests,
    usage: usage,
    cleanupPending: true,
    errorKind: 'disconnected',
    observedIdentity: observedIdentity,
  );
  factory TaskSnapshot.fromJson(Map<String, dynamic> json) {
    if (!taskModes.contains(json['mode']) ||
        !taskSandboxes.contains(json['sandbox']) ||
        !taskStates.contains(json['state']) ||
        json['outputTruncated'] is! bool ||
        json['cleanupPending'] is! bool ||
        json['strongPrincipalVerified'] != false) {
      throw const FormatException('invalid_task');
    }
    Map<String, String?>? observed;
    if (json['observedIdentity'] != null) {
      final raw = _map(json['observedIdentity']);
      observed = Map.unmodifiable({
        for (final key in ['kind', 'email', 'plan'])
          if (raw[key] != null) key: _text(raw[key], max: 512),
      });
    }
    return TaskSnapshot(
      taskId: _text(json['taskId'], max: 512),
      mode: json['mode'] as String,
      sourceId: _text(json['sourceId'], max: 512),
      sourceEpoch: _positive(json['sourceEpoch']),
      generation: _positive(json['generation']),
      workspace: _text(json['workspace']),
      model: _text(json['model']),
      sandbox: json['sandbox'] as String,
      state: json['state'] as String,
      threadId: _nullableText(json['threadId']),
      turnId: _nullableText(json['turnId']),
      output: _text(json['output'], empty: true, max: 2097152),
      outputTruncated: json['outputTruncated'] as bool,
      approvals: _list(json['approvals'], TaskApproval.fromJson),
      inputRequests: _list(json['inputRequests'], TaskInputRequest.fromJson),
      usage: json['usage'] == null
          ? null
          : TaskUsage.fromJson(_map(json['usage'])),
      cleanupPending: json['cleanupPending'] as bool,
      errorKind: json['errorKind'] == null
          ? null
          : taskErrorKind(json['errorKind']),
      observedIdentity: observed,
    );
  }
  Map<String, dynamic> toMetadata() => {
    ...identity,
    'mode': mode,
    'sourceId': sourceId,
    'workspace': workspace,
    'model': model,
    'sandbox': sandbox,
    'state': state,
    'errorKind': errorKind,
  };
  factory TaskSnapshot.fromMetadata(Map<String, dynamic> json) {
    final state = json['state'];
    if (!taskStates.contains(state)) {
      throw const FormatException('invalid_task_metadata');
    }
    final restoredState =
        {
          'prepared',
          'completed',
          'cancelled',
          'failed',
          'interrupted',
        }.contains(state)
        ? state as String
        : 'interrupted';
    final value = TaskSnapshot.fromJson({
      ...json,
      'state': restoredState,
      'threadId': null,
      'turnId': null,
      'output': '',
      'outputTruncated': false,
      'approvals': <dynamic>[],
      'inputRequests': <dynamic>[],
      'usage': null,
      'cleanupPending': false,
      'observedIdentity': null,
      'strongPrincipalVerified': false,
    });
    return TaskSnapshot(
      taskId: value.taskId,
      mode: value.mode,
      sourceId: value.sourceId,
      sourceEpoch: value.sourceEpoch,
      generation: value.generation,
      workspace: value.workspace,
      model: value.model,
      sandbox: value.sandbox,
      state: value.state,
      errorKind: restoredState == 'interrupted'
          ? 'interrupted_previous_process'
          : value.errorKind,
      restored: true,
    );
  }
}

class TaskService {
  // Public named argument intentionally differs from the private mutable guard.
  TaskService(this.backend, {bool officialEnabled = true})
    // ignore: prefer_initializing_formals
    : _officialEnabled = officialEnabled;
  final LauncherBackend backend;
  bool _officialEnabled;
  final _owned = <String, TaskSnapshot>{};
  bool get officialEnabled => _officialEnabled;
  void restrictToPreview() {
    _officialEnabled = false;
  }

  Future<Map<String, dynamic>> _call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    try {
      return await backend.call(command, payload);
    } catch (error) {
      if (error is TaskFailure) rethrow;
      // Native outer errors are finite codes; never propagate diagnostic text.
      final token = error is StateError ? error.message.toString() : '';
      throw TaskFailure(taskErrorKind(token));
    }
  }

  Future<TaskCatalog> catalog() async =>
      TaskCatalog.fromJson(await _call('task_catalog'));
  Future<TaskSnapshot> prepare({
    required String mode,
    required String sourceId,
    required String workspace,
    required String prompt,
    required String model,
    String sandbox = 'read-only',
  }) async {
    if (!taskModes.contains(mode) ||
        !taskSandboxes.contains(sandbox) ||
        prompt.trim().isEmpty ||
        workspace.trim().isEmpty ||
        model.trim().isEmpty ||
        (mode == 'official' &&
            (!_officialEnabled ||
                !RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(sourceId))) ||
        (mode == 'offline_preview' &&
            !{'preview-a', 'preview-b'}.contains(sourceId))) {
      throw const TaskFailure('invalid_request');
    }
    final task = TaskSnapshot.fromJson(
      await _call('task_prepare', {
        'mode': mode,
        'sourceId': sourceId,
        'workspace': workspace,
        'prompt': prompt,
        'model': model,
        'sandbox': sandbox,
      }),
    );
    if (task.mode != mode ||
        task.sourceId != sourceId ||
        task.workspace != workspace ||
        task.model != model ||
        task.sandbox != sandbox ||
        task.state != 'prepared') {
      throw const TaskFailure('protocol_error');
    }
    _owned[task.taskId] = task;
    return task;
  }

  void _guard(TaskSnapshot task, {bool cleanup = false}) {
    final owned = _owned[task.taskId];
    if (task.restored ||
        owned == null ||
        !owned.sameIdentity(task) ||
        owned.mode != task.mode ||
        owned.sourceId != task.sourceId ||
        owned.workspace != task.workspace ||
        owned.model != task.model ||
        owned.sandbox != task.sandbox ||
        (!_officialEnabled && owned.mode != 'offline_preview' && !cleanup)) {
      throw const TaskFailure('invalid_request');
    }
  }

  Future<TaskSnapshot> _operation(
    String command,
    TaskSnapshot task, [
    Map<String, dynamic> extra = const {},
  ]) async {
    _guard(task, cleanup: command == 'task_status' || command == 'task_cancel');
    final result = TaskSnapshot.fromJson(
      await _call(command, {...task.identity, ...extra}),
    );
    if (!result.sameIdentity(task) ||
        result.mode != task.mode ||
        result.sourceId != task.sourceId ||
        result.workspace != task.workspace ||
        result.model != task.model ||
        result.sandbox != task.sandbox) {
      throw const TaskFailure('protocol_error');
    }
    _owned[task.taskId] = result;
    return result;
  }

  Future<TaskSnapshot> start(TaskSnapshot task) =>
      _operation('task_start', task);
  Future<TaskSnapshot> status(TaskSnapshot task) =>
      _operation('task_status', task);
  Future<TaskSnapshot> cancel(TaskSnapshot task) =>
      _operation('task_cancel', task);
  Future<void> clear(TaskSnapshot task) async {
    _guard(task, cleanup: true);
    final result = await _call('task_clear', task.identity);
    if (result['taskId'] != task.taskId || result['cleared'] != true) {
      throw const TaskFailure('protocol_error');
    }
    _owned.remove(task.taskId);
  }

  Future<TaskSnapshot> approve(
    TaskSnapshot task,
    String approvalId,
    String decision,
  ) async {
    _guard(task);
    final current = _owned[task.taskId]!;
    if (!current.approvals.any(
      (a) => a.approvalId == approvalId && a.decisions.contains(decision),
    )) {
      throw const TaskFailure('invalid_request');
    }
    return _operation('task_approval', task, {
      'approvalId': approvalId,
      'decision': decision,
    });
  }

  Future<TaskSnapshot> answer(
    TaskSnapshot task,
    String requestId,
    Map<String, List<String>> answers,
  ) {
    if (!task.inputRequests.any((r) => r.requestId == requestId)) {
      throw const TaskFailure('invalid_request');
    }
    return _operation('task_input', task, {
      'requestId': requestId,
      'answers': {
        for (final e in answers.entries) e.key: {'answers': e.value},
      },
    });
  }

  Future<bool> shutdown() async {
    if (!_officialEnabled) {
      var clean = true;
      for (final task
          in _owned.values
              .where((t) => !t.terminal || t.cleanupPending)
              .toList()) {
        final result = await cancel(task);
        if (result.cleanupPending || !result.terminal) clean = false;
      }
      return clean;
    }
    final result = await _call('task_shutdown');
    return result['accepting'] == false && result['cleanupComplete'] == true;
  }
}
