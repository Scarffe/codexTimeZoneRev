import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/account_usage.dart';
import '../services/pet_alerts.dart';
import '../services/monitor_preferences.dart';

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
  final _petAlerts = PetAlerts();
  String _alert = '';
  int _alertSerial = 0;
  MonitorPreferencesStore? _preferencesStore;
  Future<void> _pendingSave = Future<void>.value();
  String? preferencesError;
  bool preferencesReady = true;
  bool alertsEnabled = true, petVisible = true, savedMonitoring = true;
  bool reducedMotion = false;
  bool mainWindowVisible = true;
  void setMainWindowVisible(bool value) {
    if (_disposed || mainWindowVisible == value) return;
    mainWindowVisible = value;
    notifyListeners();
  }

  int alertThreshold = 20, petMode = 1, preferencesSerial = 1;

  Future<void> loadPreferences(MonitorPreferencesStore store) async {
    _preferencesStore = store;
    preferencesReady = false;
    try {
      final value = await store.read();
      if (_disposed) return;
      final saved = MonitorPreferences.fromJson(value);
      interval = Duration(seconds: saved.seconds);
      alertThreshold = saved.threshold;
      alertsEnabled = saved.alerts;
      petMode = saved.mode;
      petVisible = saved.visible;
      savedMonitoring = saved.enabled;
      useLocalTime = saved.localTime;
      reducedMotion = saved.reducedMotion;
      _petAlerts.restore(value['cycles'], _now());
    } catch (_) {
      preferencesError = '监控设置读取失败，已使用默认值；原文件未改动。';
    }
    preferencesReady = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> get settingsSaved => _pendingSave;
  void _savePreferences() {
    final store = _preferencesStore;
    if (store == null || _disposed) return;
    final snapshot = <String, Object?>{
      ...MonitorPreferences(
        seconds: interval.inSeconds,
        threshold: alertThreshold,
        alerts: alertsEnabled,
        mode: petMode,
        visible: petVisible,
        enabled: savedMonitoring,
        localTime: useLocalTime,
        reducedMotion: reducedMotion,
      ).toJson(),
      'cycles': _petAlerts.records(_now()),
    };
    _pendingSave = _pendingSave.then((_) async {
      try {
        await store.write(snapshot);
        preferencesError = null;
      } catch (_) {
        preferencesError = '监控偏好已生效，但保存失败；请检查文件夹写入权限。';
      }
      if (!_disposed) notifyListeners();
    });
  }

  void configurePet({int? mode, bool? visible}) {
    if (mode != null && mode >= 0 && mode <= 2) petMode = mode;
    if (visible != null) petVisible = visible;
    preferencesSerial++;
    _savePreferences();
    if (!_disposed) notifyListeners();
  }

  void setReducedMotion(bool value) {
    if (_disposed || reducedMotion == value) return;
    reducedMotion = value;
    _savePreferences();
    notifyListeners();
  }

  void configureAlerts({bool? enabled, int? threshold}) {
    if (enabled != null) alertsEnabled = enabled;
    if ([10, 20, 30].contains(threshold)) alertThreshold = threshold!;
    _alert = '';
    _savePreferences();
    if (!_disposed) notifyListeners();
  }

  bool get canMuteCurrentCycle =>
      data != null &&
      !stale &&
      error == null &&
      !busy &&
      data!.buckets.any(
        (b) => b.windows.any((w) => w.resetsAt?.isAfter(_now()) == true),
      );
  bool get cycleMuted => data != null && _petAlerts.isMuted(data!, _now());
  void muteCurrentCycle() {
    if (!canMuteCurrentCycle) return;
    _petAlerts.mute(data!, _now());
    _alert = '';
    _savePreferences();
    notifyListeners();
  }

  bool _systemSuspended = false,
      _refreshAfterResume = false,
      _resumeHandled = false;

  void systemSuspending() {
    if (_disposed) return;
    _systemSuspended = true;
    _resumeHandled = false;
    _timer?.cancel();
  }

  void systemResumed() {
    if (_disposed || _resumeHandled) return;
    _resumeHandled = true;
    _systemSuspended = false;
    if (!monitoring) return;
    if (busy) {
      _refreshAfterResume = true;
    } else {
      _refreshOnWake();
    }
  }

  void _refreshOnWake() {
    _timer?.cancel();
    // A wake event does not grant permission to bypass failure cooldown.
    final pending = nextRefreshAt?.difference(_now());
    if (failures > 0 && pending != null && pending > Duration.zero) {
      _timer = Timer(pending, () {
        if (!_disposed && monitoring && !_systemSuspended) {
          unawaited(query(_path?.call() ?? _source, details: false));
        }
      });
    } else {
      unawaited(query(_path?.call() ?? _source, details: false));
    }
  }

  bool get stale =>
      data != null &&
      (error != null ||
          failures > 0 ||
          _now().difference(data!.fetchedAt) > interval * 2);
  Duration? get retryIn => nextRefreshAt?.difference(_now());

  void setLocalTime(bool value) {
    if (_disposed || useLocalTime == value) return;
    useLocalTime = value;
    _savePreferences();
    notifyListeners();
  }

  void setInterval(Duration value) {
    interval = value < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : value;
    if (!busy && monitoring && failures == 0) _schedule();
    _savePreferences();
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
    savedMonitoring = true;
    _savePreferences();
    if (!busy) {
      _timer?.cancel();
      unawaited(query(path(), details: false));
      // A cooldown can reject query; keep its pending timer intact.
      if (!busy) _schedule();
    }
    notifyListeners();
  }

  void pause({bool persist = true}) {
    monitoring = false;
    if (persist) {
      savedMonitoring = false;
      _savePreferences();
    }
    _refreshAfterResume = false;
    _timer?.cancel();
    _timer = null;
    if (!_disposed) notifyListeners();
  }

  void sourceChanged(String path, {bool notify = true}) {
    if (_source == path) return;
    _source = path;
    _generation++;
    data = null;
    _alert = '';
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
    if (!monitoring || _systemSuspended) return;
    _timer = Timer(Duration(seconds: seconds), () {
      if (!_disposed && monitoring) {
        unawaited(query(_path?.call() ?? _source, details: false));
      }
    });
  }

  Future<void> query(String desktopPath, {bool details = true}) async {
    if (_disposed || busy || _systemSuspended) return;
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
      final alert = stale || !alertsEnabled
          ? null
          : _petAlerts.observe(result, _now(), threshold: alertThreshold);
      _alert = alert ?? '';
      if (alert != null) {
        _alertSerial++;
        _savePreferences();
      }
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
        if (_refreshAfterResume && monitoring && !_systemSuspended) {
          _refreshAfterResume = false;
          _refreshOnWake();
        }
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
      'reducedMotion': reducedMotion,
      'animationState': busy
          ? 1
          : (stale || error != null || remaining == null
                ? 3
                : (remaining <= alertThreshold ? 2 : 0)),
      'preferencesSerial': preferencesSerial,
      'petMode': petMode,
      'petVisible': petVisible,
      'alertsEnabled': alertsEnabled,
      'alertThreshold': alertThreshold,
      'intervalSeconds': interval.inSeconds,
      'detail': windows
          .map((w) {
            final left = w.usedPercent == null
                ? '未知'
                : '${(100 - w.usedPercent!).round()}%';
            final countdown = resetCountdown(
              w.resetsAt,
              _now(),
            ).replaceFirst('已到重置时间，点击重新查询', '已到重置时间 · 等待查询确认');
            return '${w.label} · 剩余 $left\n$countdown';
          })
          .join('\n\n'),
      'alert': !busy && !stale && error == null ? _alert : '',
      'alertSerial': _alertSerial,
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
