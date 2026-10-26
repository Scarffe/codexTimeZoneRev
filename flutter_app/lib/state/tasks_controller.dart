import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/tasks.dart';
import '../services/task_store.dart';

/// Owns only tasks explicitly prepared in this process. No restore/start path.
class TasksController extends ChangeNotifier {
  TasksController(
    this.service, {
    this.store,
    this.pollInterval = const Duration(milliseconds: 250),
    this.enabled = true,
  });
  final TaskService service;
  final TaskStore? store;
  final Duration pollInterval;
  final bool enabled;
  TaskCatalog? catalog;
  String mode = 'offline_preview',
      sourceId = 'preview-a',
      workspace = 'synthetic-workspace-a',
      model = 'synthetic-model',
      prompt = '',
      sandbox = 'read-only';
  String? lastError;
  String filter = 'all';
  String shutdownState = 'idle';
  bool? cleanupComplete;
  bool initializing = false,
      preparing = false,
      _ready = false,
      _disposed = false,
      _closing = false,
      _polling = false;
  int _cancelEpoch = 0;
  Timer? _timer;
  final _tasks = <String, TaskSnapshot>{};
  final _owned = <String>{};
  final _startAttempted = <String>{};
  final _busy = <String>{};
  final _operations = <Future<void>>{};
  Future<void>? _initialization,
      _shutdownOperation,
      _cancelOperation,
      _restrictionOperation;
  Future<TaskSnapshot?>? _prepareOperation;
  Future<void> _saves = Future.value();
  List<TaskSnapshot> get tasks =>
      List.unmodifiable(_tasks.values.toList().reversed);
  bool get ready => _ready;
  bool get officialEnabled => service.officialEnabled;
  bool get canPrepare =>
      enabled &&
      _ready &&
      !_closing &&
      !preparing &&
      catalog?.adapterAvailable == true &&
      prompt.trim().isNotEmpty &&
      workspace.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      sourceId.isNotEmpty &&
      (mode != 'official' || officialEnabled);
  bool get keepAlive =>
      preparing ||
      _busy.isNotEmpty ||
      _tasks.values.any((t) => _owned.contains(t.taskId) && t.active);
  Future<void> get saved => _saves;
  bool owns(TaskSnapshot task) =>
      !task.restored &&
      _owned.contains(task.taskId) &&
      _tasks[task.taskId]?.sameIdentity(task) == true;
  bool isBusy(TaskSnapshot task) => _busy.contains(task.taskId);
  bool canStart(TaskSnapshot task) =>
      enabled &&
      !_disposed &&
      !_closing &&
      owns(task) &&
      _tasks[task.taskId]?.state == 'prepared' &&
      !_startAttempted.contains(task.taskId) &&
      !isBusy(task) &&
      (task.mode != 'official' || officialEnabled);
  bool canCancel(TaskSnapshot task) =>
      !_closing &&
      owns(task) &&
      (!task.terminal || task.cleanupPending) &&
      !isBusy(task);
  bool canClear(TaskSnapshot task) =>
      !isBusy(task) &&
      (!owns(task) ||
          (task.terminal && !task.cleanupPending) ||
          task.state == 'prepared');
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  String _kind(Object error) =>
      error is TaskFailure ? taskErrorKind(error.kind) : 'unknown';
  void _save() {
    final values = tasks;
    _saves = _saves.then((_) async {
      try {
        await store?.write(values);
      } catch (_) {
        lastError = 'store_failed';
        _emit();
      }
    });
  }

  void _accept(TaskSnapshot task) {
    final current = _tasks[task.taskId];
    if (current != null && !current.sameIdentity(task)) return;
    _tasks[task.taskId] = task;
    // Active observations must remain owned until cleanup; evict old terminal metadata first.
    while (_tasks.length > 32) {
      final candidate = _tasks.values
          .where((t) => !t.active && !_busy.contains(t.taskId))
          .firstOrNull;
      if (candidate == null) break;
      _tasks.remove(candidate.taskId);
      _owned.remove(candidate.taskId);
    }
    _save();
    _emit();
    _arm();
  }

  void updateDraft({
    String? mode,
    String? sourceId,
    String? workspace,
    String? model,
    String? prompt,
    String? sandbox,
  }) {
    if (_closing) return;
    if (mode != null &&
        taskModes.contains(mode) &&
        (mode != 'official' || officialEnabled)) {
      if (this.mode != mode) {
        this.mode = mode;
        this.sourceId = mode == 'offline_preview' ? 'preview-a' : '';
        this.workspace = mode == 'offline_preview'
            ? 'synthetic-workspace-a'
            : '';
        this.model = mode == 'offline_preview' ? 'synthetic-model' : '';
      }
    }
    if (sourceId != null) this.sourceId = sourceId;
    if (workspace != null) this.workspace = workspace;
    if (model != null) this.model = model;
    if (prompt != null) this.prompt = prompt;
    if (sandbox != null && taskSandboxes.contains(sandbox)) {
      this.sandbox = sandbox;
    }
    _emit();
  }

  void setFilter(String value) {
    if ({'all', 'active', 'terminal'}.contains(value)) {
      filter = value;
      _emit();
    }
  }

  void restrictToPreview() {
    service.restrictToPreview();
    if (mode == 'official') {
      mode = 'offline_preview';
      sourceId = 'preview-a';
      workspace = 'synthetic-workspace-a';
      model = 'synthetic-model';
    }
    _emit();
    unawaited(
      _restrictionOperation ??= _cancelRestrictedOfficial().whenComplete(
        () => _restrictionOperation = null,
      ),
    );
  }

  Future<void> _cancelRestrictedOfficial() async {
    // Admission is already closed. Wait for any prior prepare/start to yield its
    // issued identity; never drop an owned child while changing UI policy.
    if (_prepareOperation != null) await _prepareOperation;
    while (_operations.isNotEmpty) {
      await Future.wait(_operations.toList());
    }
    for (final task in tasks.where(
      (t) =>
          owns(t) && t.mode == 'official' && (!t.terminal || t.cleanupPending),
    )) {
      await _mutate(task, () => service.cancel(task), allowClosing: true);
    }
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    if (!enabled || _disposed || _closing) return;
    initializing = true;
    _emit();
    try {
      try {
        final records = await store?.read();
        if (!_disposed && !_closing && records != null) {
          for (final task in records) {
            _tasks[task.taskId] = task;
          }
        }
      } catch (_) {
        lastError = 'store_failed';
      }
      if (_disposed || _closing) return;
      final value = await service.catalog();
      if (!_disposed && !_closing) catalog = value;
    } catch (error) {
      lastError = _kind(error);
    } finally {
      initializing = false;
      _ready = true;
      _emit();
    }
  }

  Future<TaskSnapshot?> prepare() {
    if (!canPrepare) return Future.value(null);
    return _prepareOperation ??= _prepare().whenComplete(
      () => _prepareOperation = null,
    );
  }

  Future<TaskSnapshot?> _prepare() async {
    preparing = true;
    lastError = null;
    _emit();
    final cancellation = _cancelEpoch;
    try {
      final task = await service.prepare(
        mode: mode,
        sourceId: sourceId,
        workspace: workspace,
        prompt: prompt,
        model: model,
        sandbox: sandbox,
      );
      _owned.add(task.taskId);
      _accept(task);
      if (_closing ||
          _disposed ||
          cancellation != _cancelEpoch ||
          (task.mode == 'official' && !officialEnabled)) {
        final result = await service.cancel(task);
        _accept(result);
        return null;
      }
      return task;
    } catch (error) {
      lastError = _kind(error);
      _emit();
      return null;
    } finally {
      preparing = false;
      _emit();
    }
  }

  Future<void> _track(Future<void> Function() action) {
    late Future<void> operation;
    operation = action().whenComplete(() => _operations.remove(operation));
    _operations.add(operation);
    return operation;
  }

  Future<void> _mutate(
    TaskSnapshot task,
    Future<TaskSnapshot> Function() action, {
    bool allowClosing = false,
  }) => _track(() async {
    if ((_closing && !allowClosing) ||
        !owns(task) ||
        _busy.contains(task.taskId) ||
        _disposed) {
      return;
    }
    _busy.add(task.taskId);
    lastError = null;
    _emit();
    try {
      final result = await action();
      if (owns(task)) _accept(result);
    } catch (error) {
      lastError = _kind(error);
    } finally {
      _busy.remove(task.taskId);
      _emit();
      _arm();
    }
  });
  Future<void> start(TaskSnapshot task) {
    if (!canStart(task)) return Future.value();
    _startAttempted.add(task.taskId);
    final cancellation = _cancelEpoch;
    return _mutate(task, () async {
      late TaskSnapshot result;
      try {
        result = await service.start(task);
      } catch (_) {
        if (owns(task)) _accept(task.unconfirmedStart());
        rethrow;
      }
      if (_closing ||
          _disposed ||
          cancellation != _cancelEpoch ||
          (task.mode == 'official' && !officialEnabled)) {
        return service.cancel(result);
      }
      return result;
    });
  }

  Future<void> cancel(TaskSnapshot task) => canCancel(task)
      ? _mutate(task, () => service.cancel(task))
      : Future.value();
  Future<void> approve(TaskSnapshot task, String approvalId, String decision) =>
      _mutate(task, () => service.approve(task, approvalId, decision));
  Future<void> answer(
    TaskSnapshot task,
    String requestId,
    Map<String, List<String>> answers,
  ) => _mutate(task, () => service.answer(task, requestId, answers));
  Future<void> clear(TaskSnapshot task) => _track(() async {
    if (!canClear(task) || _closing) return;
    _busy.add(task.taskId);
    _emit();
    try {
      if (owns(task)) await service.clear(task);
      _tasks.remove(task.taskId);
      _owned.remove(task.taskId);
      lastError = null;
      _save();
    } catch (error) {
      lastError = _kind(error);
    } finally {
      _busy.remove(task.taskId);
      _emit();
    }
  });
  Future<void> poll() async {
    if (_polling || _closing || _disposed) return;
    _polling = true;
    try {
      for (final task in tasks.where(
        (t) => owns(t) && t.active && !isBusy(t),
      )) {
        if (_closing || _disposed) break;
        try {
          final result = await service.status(task);
          if (owns(task) &&
              identical(_tasks[task.taskId], task) &&
              !isBusy(task)) {
            _accept(result);
          }
        } catch (error) {
          lastError = _kind(error);
          _emit();
        }
      }
    } finally {
      _polling = false;
      _arm();
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_disposed ||
        _closing ||
        _polling ||
        !tasks.any((t) => owns(t) && t.active)) {
      return;
    }
    _timer = Timer(pollInterval, () => unawaited(poll()));
  }

  void rearmPolling() => _arm();
  Future<void> cancelAll() => _cancelOperation ??= _cancelAll().whenComplete(
    () => _cancelOperation = null,
  );
  Future<void> _cancelAll() async {
    ++_cancelEpoch;
    _timer?.cancel();
    await _restrictionOperation;
    await _prepareOperation;
    // In-flight start/approval may yield an owned process; wait before cancellation.
    while (_operations.isNotEmpty) {
      await Future.wait(_operations.toList());
    }
    for (final task in tasks.where(
      (t) => owns(t) && (!t.terminal || t.cleanupPending),
    )) {
      await _mutate(task, () => service.cancel(task), allowClosing: true);
    }
    await saved;
  }

  Future<void> shutdown() =>
      _shutdownOperation ??= _shutdown().catchError((Object error) {
        _shutdownOperation = null;
        throw error;
      });
  Future<void> _shutdown() async {
    _closing = true;
    shutdownState = 'pending';
    _timer?.cancel();
    _emit();
    try {
      await _initialization;
      await cancelAll();
      // A catalog read or restored metadata never owns the native manager.
      // Do not shut down any previous/injected owner's tasks on that basis.
      cleanupComplete = enabled && _owned.isNotEmpty
          ? await service.shutdown()
          : true;
      if (cleanupComplete != true) throw const TaskFailure('cleanup_failed');
      shutdownState = 'succeeded';
      await saved;
    } catch (error) {
      shutdownState = 'failed';
      lastError = _kind(error);
      rethrow;
    } finally {
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_cancelEpoch;
    _timer?.cancel();
    super.dispose();
  }
}
