import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/backend.dart';
import '../services/session_selection.dart';

/// Independent of quota polling: local files only, including while the main UI is hidden.
class SessionMetricsController extends ChangeNotifier {
  SessionMetricsController(this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final LauncherBackend backend;
  List<Map<String, dynamic>> sessions = [];
  String? selected;
  Map<String, dynamic>? data;
  String? error;
  SessionSelectionStore? _selectionStore;
  Future<void> _saved = Future<void>.value();
  Future<void> get selectionSaved => _saved;
  String? selectionError, listError;
  String? _expectedId;
  DateTime? lastRead;
  Map<String, dynamic>? get sourceInfo =>
      data?['sourceInfo'] as Map<String, dynamic>?;
  String sessionName(Map<String, dynamic> s) {
    final title = s['title'];
    if (title is String && title.trim().isNotEmpty) return title.trim();
    return '会话 ${s['id'] ?? (s['path'] as String).split(RegExp(r'[\\/]')).last}';
  }

  String activityLabel(Map<String, dynamic> s) {
    final ms = s['modifiedMs'];
    return ms is num
        ? DateTime.fromMillisecondsSinceEpoch(ms.toInt())
              .toLocal()
              .toString()
              .split('.')
              .first
        : '活动时间未知';
  }

  Future<void> initialize(
    SessionSelectionStore store, {
    String? initialPath,
  }) async {
    _selectionStore = store;
    String? path, id;
    try {
      final value = await store.read();
      path = value['path'] is String ? value['path'] as String : null;
      id = value['id'] is String ? value['id'] as String : null;
    } catch (_) {
      selectionError = '无法恢复上次选择，请重新选择会话。';
    }
    await list();
    if (_closed) return;
    select(initialPath ?? path, expectedId: initialPath == null ? id : null);
  }

  void _saveSelection() {
    final store = _selectionStore;
    if (store == null) return;
    final value = <String, Object?>{'path': selected, 'id': _expectedId};
    _saved = _saved.then((_) => store.write(value)).catchError((Object e) {
      selectionError = '会话选择保存失败；本次采集继续。';
      if (!_closed) notifyListeners();
    });
  }

  bool busy = false;
  bool listing = false;
  bool _closed = false;
  int _generation = 0;
  Timer? _timer;

  bool remindersEnabled = false;
  DateTime? mutedUntil;
  bool _armed = false;
  Object? _epoch;
  final _seenEnds = <String>{};
  int alertSerial = 0;
  String _alert = '';
  DateTime? _alertUntil;
  String get alert => _alertUntil?.isAfter(_now()) == true ? _alert : '';

  void resetObservation() {
    _armed = false;
    _epoch = null;
    _seenEnds.clear();
    _alert = '';
    _alertUntil = null;
  }

  // Called by the shared settings owner, without recursively publishing.
  void configureReminders({required bool enabled, DateTime? muteUntil}) {
    if (enabled == remindersEnabled && muteUntil == mutedUntil) return;
    remindersEnabled = enabled;
    mutedUntil = muteUntil;
    resetObservation();
  }

  void _observe(Map<String, dynamic> value) {
    final epoch = value['logEpoch'];
    final current = value['current'];
    if (epoch is! int ||
        current is! Map ||
        current['turnId'] is! String ||
        !const [
          'running',
          'completed',
          'cancelled',
        ].contains(current['status'])) {
      resetObservation();
      return;
    }
    if (_epoch != epoch || value['catchingUp'] == true) {
      resetObservation();
      _epoch = epoch;
    }
    if (value['catchingUp'] == true) return;
    if (current['status'] != 'completed') {
      _alert = '';
      _alertUntil = null;
    }
    final ends = (value['terminals'] as List?) ?? const [];
    String? message;
    for (final terminal in ends) {
      if (terminal is! Map || terminal['turnId'] is! String) continue;
      final id = terminal['turnId'] as String;
      if (!_seenEnds.add(id)) continue;
      if (_armed &&
          remindersEnabled &&
          mutedUntil?.isAfter(_now()) != true &&
          terminal['status'] == 'completed' &&
          terminal['turnId'] == current['turnId'] &&
          current['status'] == 'completed' &&
          message == null) {
        final ms = terminal['durationMs'];
        message =
            '所选会话的回合已结束${ms is num ? '\n完整回合 ${(ms / 1000).toStringAsFixed(1)} 秒' : ''}';
      }
    }
    // The backend returns the latest 64 terminal turns. Keep more than that so
    // duplicate records cannot produce a reminder after trimming local history.
    while (_seenEnds.length > 1024) {
      _seenEnds.remove(_seenEnds.first);
    }
    _armed = true;
    if (message != null) {
      _alert = message;
      _alertUntil = _now().add(const Duration(seconds: 10));
      alertSerial++;
    }
  }

  String get stateLabel {
    if (selected == null) return '未选择会话';
    if (error != null) return '状态未知 · 读取失败';
    if (data?['catchingUp'] == true) return '状态未知 · 正在读取历史';
    return switch (data?['current']?['status']) {
      'running' => '回合进行中',
      'completed' => '回合已结束',
      'cancelled' => '已取消',
      _ => '状态未知',
    };
  }

  // Windows canonical paths returned by Rust use the extended-length prefix.
  // Startup selection may name the same file using a regular Windows path.
  String? get selectorValue {
    final path = selected;
    if (path == null) return null;
    String identity(String value) {
      if (value.startsWith(r'\\?\UNC\')) {
        value = r'\\' + value.substring(8);
      } else if (value.startsWith(r'\\?\')) {
        value = value.substring(4);
      }
      if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value) ||
          value.startsWith(r'\\')) {
        return value.replaceAll('/', r'\').toLowerCase();
      }
      return value;
    }

    for (final session in sessions) {
      final candidate = session['path'] as String;
      if (identity(candidate) == identity(path)) return candidate;
    }
    return null;
  }

  Future<void> list() async {
    if (listing || _closed) return;
    listing = true;
    notifyListeners();
    try {
      final value = await backend.call('session_metrics', {'action': 'list'});
      if (_closed) return;
      sessions = (value['sessions'] as List).cast<Map<String, dynamic>>();
      listError = null;
    } catch (e) {
      if (!_closed) {
        listError = e.toString();
      }
    } finally {
      listing = false;
      if (!_closed) notifyListeners();
    }
  }

  void select(String? path, {String? expectedId}) {
    _generation++;
    resetObservation();
    selected = path;
    lastRead = null;
    _expectedId = expectedId;
    for (final s in sessions) {
      if (s['path'] == path) _expectedId ??= s['id'] as String?;
    }
    _saveSelection();
    data = null;
    error = null;
    _timer?.cancel();
    _timer = path == null
        ? null
        : Timer.periodic(const Duration(seconds: 2), (_) => poll());
    notifyListeners();
    unawaited(poll());
  }

  Future<void> poll() async {
    if (_closed || selected == null || busy) return;
    final generation = _generation;
    busy = true;
    try {
      final value = await backend.call('session_metrics', {'path': selected});
      if (!_closed && generation == _generation) {
        final info = value['sourceInfo'];
        if (_expectedId != null && info is Map && info['id'] != _expectedId) {
          throw StateError('所选路径的会话标识已变化，请重新选择');
        }
        if (_expectedId == null && info is Map && info['id'] is String) {
          _expectedId = info['id'] as String;
          _saveSelection();
        }
        data = value;
        lastRead = _now();
        error = null;
        _observe(value);
      }
    } catch (e) {
      if (!_closed && generation == _generation) {
        error = e.toString();
        data = null;
        resetObservation();
      }
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  Map<String, dynamic>? get last => data?['last'] as Map<String, dynamic>?;
  String get summary {
    if (selected == null) return '';
    if (error != null) return '会话统计不可用';
    if (data?['catchingUp'] == true) return '正在读取会话历史';
    final rate = last?['tokensPerSecond'] as num?;
    final prefix = data?['active'] == true ? '本轮进行中 · 上轮' : '上轮';
    return rate == null
        ? '$prefix回合平均吞吐：暂无完整统计'
        : '$prefix回合平均吞吐 ${rate.toStringAsFixed(2)} tokens/s';
  }

  String get petSummary {
    if (selected == null) return '';
    if (error != null) return '状态未知 · 读取失败';
    if (data?['catchingUp'] == true) return '状态未知 · 读取历史';
    final rate = last?['tokensPerSecond'] as num?;
    return '$stateLabel · 上轮\n回合平均吞吐 ${rate == null ? '暂无统计' : '${rate.toStringAsFixed(2)} tokens/s'}';
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
