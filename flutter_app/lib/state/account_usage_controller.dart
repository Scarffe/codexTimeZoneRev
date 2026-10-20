import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/account_usage.dart';

/// One query owner for main window, tray and pet. Cache is session-only.
class AccountUsageController extends ChangeNotifier {
  AccountUsageController(this.service, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final AccountUsageService service;
  final DateTime Function() _now;
  AccountUsage? data;
  String? error;
  bool busy = false, useLocalTime = true, monitoring = false;
  bool _disposed = false;
  Timer? _timer;
  Duration interval = const Duration(minutes: 2);
  DateTime? nextRefreshAt, lastAttempt;
  int failures = 0, revision = 0, attempts = 0;
  String _source = '';
  String Function()? _path;
  int _generation = 0;

  bool get stale =>
      data != null &&
      (error != null ||
          failures > 0 ||
          _now().difference(data!.fetchedAt) > interval * 2);
  Duration? get retryIn => nextRefreshAt?.difference(_now());

  void setLocalTime(bool value) {
    if (_disposed || useLocalTime == value) return;
    useLocalTime = value;
    notifyListeners();
  }

  void setInterval(Duration value) {
    interval = value < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : value;
    if (!busy && monitoring) _schedule();
    if (!_disposed) notifyListeners();
  }

  void startMonitoring(String Function() path, {Duration? every}) {
    if (_disposed) return;
    _path = path;
    if (every != null) {
      interval = every < const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : every;
    }
    monitoring = true;
    if (!busy) {
      _timer?.cancel();
      unawaited(query(path(), details: false));
      // A cooldown can reject query; keep its pending timer intact.
      if (!busy) _schedule();
    }
    notifyListeners();
  }

  void pause() {
    monitoring = false;
    _timer?.cancel();
    _timer = null;
    if (!_disposed) notifyListeners();
  }

  void sourceChanged(String path, {bool notify = true}) {
    if (_source == path) return;
    _source = path;
    _generation++;
    data = null;
    error = null;
    failures = 0;
    nextRefreshAt = null;
    if (!_disposed && notify) notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed) return;
    final seconds = failures == 0
        ? interval.inSeconds
        : math.max(
            interval.inSeconds,
            math.min(1800, 30 * (1 << math.min(failures - 1, 6))),
          );
    nextRefreshAt = _now().add(Duration(seconds: seconds));
    if (!monitoring) return;
    _timer = Timer(Duration(seconds: seconds), () {
      if (!_disposed && monitoring) {
        unawaited(query(_path?.call() ?? _source, details: false));
      }
    });
  }

  Future<void> query(String desktopPath, {bool details = true}) async {
    if (_disposed || busy) return;
    sourceChanged(desktopPath, notify: false);
    // Manual refresh bypasses the normal interval, never failure cooldown.
    if (failures > 0 &&
        nextRefreshAt != null &&
        _now().isBefore(nextRefreshAt!)) {
      return;
    }
    final generation = _generation;
    _timer?.cancel();
    nextRefreshAt = null;
    busy = true;
    lastAttempt = _now();
    attempts++;
    error = null;
    notifyListeners();
    try {
      final result = !details && service is LimitsUsageService
          ? await (service as LimitsUsageService).queryLimits(desktopPath)
          : await service.query(desktopPath);
      if (_disposed || generation != _generation) return;
      if (_path != null && _path!() != desktopPath) {
        sourceChanged(_path!());
        return;
      }
      if (data != null && data!.identity != result.identity) data = null;
      if (result.limitsError != null && result.buckets.isEmpty) {
        if (details && data == null) data = result;
        throw StateError(result.limitsError!);
      }
      data = retainUsageDetails(result, data);
      failures = 0;
      revision++;
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = e.toString().replaceFirst(RegExp(r'^Bad state: '), '');
        failures++;
        if (RegExp('登录|账号已切换|登录方式').hasMatch(error!)) data = null;
      }
    } finally {
      if (!_disposed) {
        busy = false;
        _schedule();
        notifyListeners();
      }
    }
  }

  Map<String, Object?> get desktopSnapshot {
    final snapshot = data;
    final buckets = snapshot?.buckets ?? [];
    final preferred = buckets.where((b) => b.id == 'codex');
    final bucket = preferred.isNotEmpty
        ? preferred.first
        : (buckets.isEmpty ? null : buckets.first);
    final windows = bucket?.windows ?? [];
    final valid = windows.where((w) => w.usedPercent != null);
    final remaining = valid.isEmpty
        ? null
        : valid.map((w) => 100 - w.usedPercent!).reduce(math.min);
    final status = busy
        ? '正在刷新'
        : error != null
        ? (snapshot == null ? error! : '离线 · 上次观测')
        : snapshot == null
        ? '尚未查询'
        : stale
        ? '缓存已过期'
        : monitoring
        ? '自动监控'
        : '已暂停';
    final label = bucket?.label ?? 'Codex';
    final text = remaining == null
        ? '$label · 暂无额度 · $status'
        : '$label · 剩余 ${remaining.toStringAsFixed(0)}% · $status';
    return {
      'text': text,
      'remaining': remaining ?? -1.0,
      'stale': stale,
      'busy': busy,
      'paused': !monitoring,
      'revision': revision,
      'attempts': attempts,
      'failures': failures,
      'nextRefreshAt': nextRefreshAt?.millisecondsSinceEpoch ?? 0,
      'fetchedAt': snapshot?.fetchedAt.millisecondsSinceEpoch ?? 0,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
