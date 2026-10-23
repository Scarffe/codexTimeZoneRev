import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/benchmark.dart';
import '../services/benchmark_store.dart';

/// One app-owned native slot. Restored observations never confer ownership.
class BenchmarkController extends ChangeNotifier {
  BenchmarkController(
    this.service, {
    this.store,
    this.pollInterval = const Duration(milliseconds: 250),
    this.enabled = true,
  });
  final BenchmarkService service;
  final BenchmarkStore? store;
  final Duration pollInterval;
  final bool enabled;
  BenchmarkCatalog? catalog;
  BenchmarkSnapshot? snapshot;
  String protocol = 'chat_completions', scenarioId = 'chat_text_complete';
  String? lastError, _ownedId, _attemptId;
  bool initializing = false,
      starting = false,
      _disposed = false,
      _closing = false,
      _polling = false,
      _mutating = false;
  bool? cleanupComplete;
  int _generation = 0, _attemptSequence = 0;
  String? _pendingAction;
  Timer? _timer;
  Future<void>? _initialization, _startOperation, _shutdownOperation;
  Future<void>? _mutationOperation;
  Future<void> _saves = Future.value();
  bool get busy =>
      starting ||
      _mutating ||
      (_ownedId != null &&
          (snapshot?.terminal != true || snapshot?.cleanupPending == true));
  bool get keepAlive =>
      starting ||
      _mutating ||
      (_ownedId != null &&
          (snapshot?.terminal != true || snapshot?.cleanupPending == true));
  bool get canStart =>
      enabled && !_closing && !initializing && catalog != null && !busy;
  bool get canCancel =>
      !_closing &&
      (starting || (_ownedId != null && snapshot?.terminal != true));
  bool get canClear =>
      !starting &&
      !_mutating &&
      (_ownedId == null ||
          (snapshot?.terminal == true && snapshot?.cleanupPending == false));
  Future<void> get saved => _saves;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    if (!enabled) return;
    initializing = true;
    _emit();
    try {
      try {
        final record = await store?.read();
        if (record != null) {
          protocol = record.protocol;
          scenarioId = record.scenarioId;
          _attemptId = record.attemptId;
          snapshot = record.starting
              ? BenchmarkSnapshot.interruptedIntent(protocol, scenarioId)
              : record.snapshot?.recover();
        }
      } catch (_) {
        lastError = '历史记录读取失败；下次保存时备份原文件。';
      }
      catalog = await service.catalog();
    } catch (_) {
      lastError = '离线场景目录不可用。';
    } finally {
      initializing = false;
      _emit();
    }
  }

  Future<bool> _save({bool intent = false}) {
    final record = BenchmarkRecord(
      protocol: protocol,
      scenarioId: scenarioId,
      attemptId: _attemptId,
      starting: intent,
      snapshot: intent ? null : snapshot,
      observedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final done = Completer<bool>();
    _saves = _saves.then((_) async {
      try {
        await store?.write(record);
        done.complete(true);
      } catch (_) {
        lastError = '最后观察未保存；请检查文件夹写入权限。';
        done.complete(false);
        _emit();
      }
    });
    return done.future;
  }

  Future<void> selectProtocol(String value) async {
    if (busy || _closing || !benchmarkProtocols.contains(value)) return;
    protocol = value;
    scenarioId =
        catalog?.scenarios.where((s) => s.protocol == value).firstOrNull?.id ??
        (value == 'responses'
            ? 'responses_text_complete'
            : 'chat_text_complete');
    _emit();
    await _save();
  }

  Future<void> selectScenario(String value) async {
    if (busy ||
        _closing ||
        catalog?.scenarios.any(
              (s) => s.id == value && s.protocol == protocol,
            ) !=
            true) {
      return;
    }
    scenarioId = value;
    _emit();
    await _save();
  }

  Future<void> start() {
    if (!canStart) return Future.value();
    starting = true;
    lastError = null;
    cleanupComplete = null;
    _generation++;
    _attemptId =
        'attempt-${DateTime.now().microsecondsSinceEpoch}-${++_attemptSequence}';
    _emit();
    return _startOperation = _start();
  }

  Future<void> _start() async {
    try {
      if (!await _save(intent: true)) return;
      if (_ownedId != null) {
        await service.clear(_ownedId!);
        _ownedId = null;
      }
      snapshot = null;
      final result = await service.start(
        protocol,
        scenarioId,
        onOwned: (id) => _ownedId = id,
      );
      // Capture ownership before handling any delayed lifecycle action.
      _ownedId = result.runId;
      if (_ownedId == null) throw const FormatException('missing_run_id');
      snapshot = result;
      await _save();
    } catch (_) {
      lastError = '离线测试未能开始；没有可展示的新结果。';
    } finally {
      starting = false;
      _emit();
      final action = _pendingAction;
      _pendingAction = null;
      if (!_closing && action != null && _ownedId != null) {
        await _act(action);
      }
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_disposed &&
        !_closing &&
        _ownedId != null &&
        (snapshot?.terminal != true || snapshot?.cleanupPending == true)) {
      _timer = Timer(pollInterval, () => unawaited(poll()));
    }
  }

  Future<void> poll() async {
    if (_disposed ||
        _closing ||
        starting ||
        _polling ||
        _mutating ||
        _ownedId == null) {
      return;
    }
    final id = _ownedId!, generation = _generation;
    _polling = true;
    try {
      final result = await service.observe('benchmark_status', id);
      if (!_closing &&
          generation == _generation &&
          _ownedId == id &&
          result.runId == id &&
          !(snapshot?.terminal == true && !result.terminal)) {
        snapshot = result;
        await _save();
        _emit();
      }
    } catch (_) {
      if (generation == _generation && !_closing) {
        lastError = '状态观察失败；保留最后已观察事实。';
        _emit();
      }
    } finally {
      _polling = false;
      _schedule();
    }
  }

  Future<void> cancel() => _request('benchmark_cancel');
  Future<void> interrupt() => _request('benchmark_interrupt');
  Future<void> _request(String action) async {
    if (_closing || _disposed) return;
    _generation++;
    if (starting) {
      if (_pendingAction != 'benchmark_interrupt') _pendingAction = action;
      await _startOperation;
    } else if (_mutating) {
      await (_mutationOperation ?? _startOperation);
    } else {
      await (_mutationOperation = _act(action));
    }
  }

  Future<void> _act(String action) async {
    final id = _ownedId;
    if (id == null || snapshot?.terminal == true || _mutating) return;
    _mutating = true;
    _emit();
    try {
      final result = await service.observe(action, id);
      if (_ownedId == id && result.runId == id) {
        snapshot = result;
        await _save();
      }
    } catch (_) {
      lastError = '停止请求未确认；保留最后观察并继续检查清理。';
    } finally {
      _mutating = false;
      _emit();
      _schedule();
    }
  }

  Future<void> clear() {
    if (!canClear || _closing) return Future.value();
    return _mutationOperation = _clear();
  }

  Future<void> _clear() async {
    _generation++;
    _mutating = true;
    _emit();
    try {
      if (_ownedId != null) await service.clear(_ownedId!);
      _ownedId = null;
      snapshot = null;
      _attemptId = null;
      lastError = null;
      await _save();
    } catch (_) {
      lastError = '结果尚不能清除；等待自有任务完成清理。';
    } finally {
      _mutating = false;
      _emit();
    }
  }

  Future<void> shutdown() {
    if (_shutdownOperation != null) return _shutdownOperation!;
    _closing = true;
    _generation++;
    _timer?.cancel();
    _emit();
    return _shutdownOperation = _shutdown();
  }

  Future<void> _shutdown() async {
    await _startOperation;
    await _mutationOperation;
    if (!enabled) {
      await saved;
      return;
    }
    try {
      cleanupComplete = await service.shutdown(_ownedId);
      if (_ownedId != null) {
        try {
          final latest = await service.observe('benchmark_status', _ownedId!);
          if (latest.runId == _ownedId) snapshot = latest;
        } catch (_) {
          snapshot = snapshot?.copy(
            state: snapshot!.terminal ? null : 'cancelled',
            successfulSample: snapshot!.terminal ? null : false,
            reason: snapshot!.terminal ? null : 'shutdown',
            clearRates: !snapshot!.terminal,
          );
          lastError = '退出后的最终状态未确认；保留最后观察。';
        }
      }
      if (cleanupComplete != true) lastError = '退出清理未在原生时限内确认完成。';
    } catch (_) {
      cleanupComplete = false;
      lastError = '退出清理未确认完成。';
    }
    await _save();
    await saved;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
