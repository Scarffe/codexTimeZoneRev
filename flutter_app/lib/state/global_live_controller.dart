import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/global_live.dart';

class GlobalLiveController extends ChangeNotifier {
  GlobalLiveController(
    this.service, {
    this.pollInterval = const Duration(seconds: 2),
  });
  final GlobalLiveService service;
  final Duration pollInterval;
  GlobalLiveSnapshot snapshot = const GlobalLiveSnapshot();
  bool busy = false, stale = false;
  bool _visible = true, _background = false, _closed = false, _disposed = false;
  Timer? _timer;
  Future<void>? _initialization, _refresh;
  int _epoch = 0;

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    await refresh();
    if (!_closed && service is! SyntheticGlobalLiveService) {
      _timer = Timer.periodic(pollInterval, (_) {
        if (_visible || _background) unawaited(refresh());
      });
    }
  }

  Future<void> refresh() {
    if (_closed) return Future<void>.value();
    return _refresh ??= _read().whenComplete(() => _refresh = null);
  }

  Future<void> _read() async {
    final epoch = _epoch;
    busy = true;
    _notify();
    try {
      final value = await service.status();
      if (_closed || epoch != _epoch) return;
      snapshot = value;
      stale = false;
    } catch (_) {
      if (!_closed && epoch == _epoch) stale = true;
    } finally {
      if (!_closed && epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setMainWindowVisible(bool visible) => _visible = visible;
  void setBackgroundObservation(bool enabled) => _background = enabled;
  Future<void> shutdown() async {
    _closed = true;
    _epoch++;
    _timer?.cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    _closed = true;
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }
}
