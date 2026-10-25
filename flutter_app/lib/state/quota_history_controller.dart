import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../services/quota_history.dart';
import '../services/quota_history_projection.dart';
import '../services/quota_history_store.dart';

typedef QuotaHistoryReader = Future<QuotaHistoryReadResult> Function(
  QuotaHistoryFilter filter,
);
typedef QuotaHistoryProjector = FutureOr<QuotaHistoryProjection> Function(
  QuotaHistoryReadResult result,
  QuotaHistoryFilter filter,
);

DateTime _toLocal(DateTime utc) => utc.toLocal();

// Only immutable data and a top-level callback cross the isolate boundary.
// Keeping this outside the notifier prevents an implicit `this` capture from
// dragging listeners, UI state, or a store's queue into the worker.
Future<QuotaHistoryProjection> _projectInBackground(
  QuotaHistoryReadResult result,
  QuotaHistoryFilter filter,
) => Isolate.run(
  () => projectQuotaHistory(result.records, filter, toDisplayTime: _toLocal),
);

/// On-demand local reads only. No account service, query timer or network owner.
class QuotaHistoryController extends ChangeNotifier {
  QuotaHistoryController(
    this.store, {
    QuotaHistoryReader? read,
    QuotaHistoryProjector? projector,
  }) : _read = read ?? store.read,
       _project = projector ?? _projectInBackground;
  final QuotaHistoryStore store;
  final QuotaHistoryReader _read;
  final QuotaHistoryProjector _project;
  QuotaHistoryProjection? _projection;
  QuotaHistoryFilter? _filter;
  String? _error;
  bool _loading = false, _storageGaps = false, _disposed = false;
  int _serial = 0;
  QuotaHistoryProjection? get projection => _projection;
  QuotaHistoryFilter? get filter => _filter;
  String? get error => _error;
  bool get isLoading => _loading;
  bool get hasStorageGaps => _storageGaps;

  Future<void> load(QuotaHistoryFilter selection) async {
    if (_disposed) return;
    final serial = ++_serial;
    _filter = selection;
    _projection = null;
    _error = null;
    _storageGaps = false;
    _loading = true;
    notifyListeners();
    try {
      final result = await _read(selection);
      if (_disposed || serial != _serial) return;
      final projected = await _project(result, selection);
      if (_disposed || serial != _serial) return;
      _projection = projected;
      _storageGaps = result.hasStorageGaps;
    } catch (_) {
      if (_disposed || serial != _serial) return;
      _error = '历史读取失败';
    }
    if (_disposed || serial != _serial) return;
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _serial++;
    super.dispose();
  }
}
