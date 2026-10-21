import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/backend.dart';

/// Independent of quota polling: local files only, including while the main UI is hidden.
class SessionMetricsController extends ChangeNotifier {
  SessionMetricsController(this.backend);
  final LauncherBackend backend;
  List<Map<String, dynamic>> sessions = [];
  String? selected;
  Map<String, dynamic>? data;
  String? error;
  bool busy = false;
  bool listing = false;
  bool _closed = false;
  int _generation = 0;
  Timer? _timer;
  Future<void> list() async {
    if (listing || _closed) return;
    listing = true;
    notifyListeners();
    try {
      final value = await backend.call('session_metrics', {'action': 'list'});
      if (_closed) return;
      sessions = (value['sessions'] as List).cast<Map<String, dynamic>>();
      error = null;
    } catch (e) {
      if (!_closed) error = e.toString();
    } finally {
      listing = false;
      if (!_closed) notifyListeners();
    }
  }

  void select(String? path) {
    _generation++;
    selected = path;
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
        data = value;
        error = null;
      }
    } catch (e) {
      if (!_closed && generation == _generation) {
        error = e.toString();
        data = null;
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
    if (error != null) return '会话统计不可用';
    if (data?['catchingUp'] == true) return '会话历史读取中';
    final rate = last?['tokensPerSecond'] as num?;
    return '回合平均吞吐 · 上轮\n${rate == null ? '暂无完整统计' : '${rate.toStringAsFixed(2)} tokens/s'}';
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
