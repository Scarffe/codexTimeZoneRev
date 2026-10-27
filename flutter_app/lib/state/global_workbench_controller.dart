import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/global_workbench.dart';
import '../services/global_workbench_service.dart';
import '../services/global_workbench_store.dart';
import '../services/global_calendar.dart';
import '../services/session_rhythm_projection.dart' show RhythmCalendar;

/// One application owner for discovery and coherent, revision-bound views.
class GlobalWorkbenchController extends ChangeNotifier {
  GlobalWorkbenchController({
    required this.service,
    GlobalWorkbenchStore? store,
    this.roots,
    this.pollInterval = const Duration(seconds: 30),
    DateTime Function()? now,
    RhythmCalendar? calendar,
  }) : store = store ?? GlobalWorkbenchStore.memory(),
       _now = now ?? DateTime.now,
       _calendar = calendar ?? RhythmCalendar.system() {
    _query = _rangeQuery();
  }
  final GlobalWorkbenchService service;
  final GlobalWorkbenchStore store;
  final List<String>? roots;
  final Duration pollInterval;
  final DateTime Function() _now;
  final RhythmCalendar _calendar;
  int _allBucketDays = 1;
  late GlobalQuery _query;
  GlobalRange _range = GlobalRange.days7;
  GlobalSnapshot? _snapshot;
  String? _error, _preferenceError;
  bool _closed = false,
      _disposed = false,
      _visible = true,
      _background = false,
      _refreshing = false,
      _suspended = false;
  int _generation = 1,
      _querySerial = 0,
      _queryCount = 0,
      _preferenceRevision = 0;
  Timer? _timer;
  Future<void>? _initialization, _refreshOperation, _shutdown;
  Future<void> _saved = Future.value();
  final _pending = <Future<Object?>>{};
  GlobalQuery get query => _query;
  GlobalRange get range => _range;
  GlobalSnapshot? get snapshot => _snapshot;
  String? get error => _error;
  String? get preferenceError => _preferenceError;
  bool get busy => _refreshing || _queryCount > 0;
  bool get scanning =>
      _snapshot?.phase == 'scanning' || (_refreshing && _snapshot == null);
  bool get backgroundObservationEnabled => _background;
  bool get keepAlive => !_closed && _background;
  Future<void> get saved => _saved;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _track<T>(Future<T> future) {
    final tracked = future.then<Object?>((value) => value);
    _pending.add(tracked);
    unawaited(
      tracked.then<void>(
        (_) => _pending.remove(tracked),
        onError: (Object _, StackTrace _) {
          _pending.remove(tracked);
        },
      ),
    );
    return future;
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    final preferenceRevision = _preferenceRevision;
    try {
      final preferences = await store.read();
      if (_closed) return;
      if (preferences != null && preferenceRevision == _preferenceRevision) {
        _range = preferences.range;
        _query = _rangeQuery(
          project: preferences.project,
          model: preferences.model,
          status: preferences.status,
          search: preferences.search,
          sort: preferences.sort,
        );
      }
    } catch (error) {
      if (!_closed) _preferenceError = error.toString();
    }
    if (_closed) return;
    try {
      await _track(service.capabilities());
      if (_closed) return;
      await refresh();
    } catch (error) {
      if (!_closed) {
        _error = error.toString();
        _notify();
      }
    }
    if (!_closed) {
      _timer = Timer.periodic(pollInterval, (_) {
        if (!_suspended && (_visible || _background)) unawaited(refresh());
      });
    }
  }

  GlobalQuery _rangeQuery({
    String? project,
    String? model,
    String? status,
    String search = '',
    String sort = 'recent',
  }) {
    final now = _now(), local = _calendar.toLocal(now.toUtc());
    final dayCount = switch (_range) {
      GlobalRange.today => 1,
      GlobalRange.days7 => 7,
      GlobalRange.days30 => 30,
      GlobalRange.all => 0,
    };
    final edges = <int>[];
    if (dayCount > 0) {
      for (var i = dayCount - 1; i >= -1; i--) {
        edges.add(
          _calendar
              .localDate(local.year, local.month, local.day - i)
              .millisecondsSinceEpoch,
        );
      }
    }
    return GlobalQuery(
      fromMs: edges.isEmpty ? null : edges.first,
      toMs: dayCount == 0 ? null : now.millisecondsSinceEpoch,
      dayEdgesMs: edges,
      project: project,
      model: model,
      status: status,
      search: search,
      sort: sort,
    );
  }

  Future<void> refresh() {
    if (_closed || _suspended) return Future.value();
    return _refreshOperation ??= _refresh().whenComplete(() {
      _refreshOperation = null;
    });
  }

  Future<void> _refresh() async {
    final generation = _generation;
    _query = _rangeQuery(
      project: _query.project,
      model: _query.model,
      status: _query.status,
      search: _query.search,
      sort: _query.sort,
    ).copyWith(offset: _query.offset);
    _refreshing = true;
    _notify();
    try {
      // Each native scan is bounded. Continue the same generation until the
      // current discovery batch is indexed; a later timer advances large homes.
      for (var pass = 0; pass < 64; pass++) {
        final scanned = await _track(
          service.scan(generation: generation, roots: roots),
        );
        if (_closed || generation != _generation) return;
        await _loadQuery();
        if (_closed || generation != _generation) return;
        if (scanned.phase != 'scanning' && scanned.coverage.pending == 0) break;
      }
    } catch (error) {
      if (!_closed && generation == _generation) _error = error.toString();
    } finally {
      _refreshing = false;
      if (!_closed) _notify();
    }
  }

  Future<void> _loadQuery({bool page = false}) async {
    if (_closed) return;
    final serial = ++_querySerial;
    var requested = _query;
    final all = _range == GlobalRange.all;
    var bucketDays = _allBucketDays;
    int? expectedRevision = page || (all && requested.dayEdgesMs.isNotEmpty)
        ? _snapshot?.revision
        : null;
    _queryCount++;
    _notify();
    try {
      // A changing index can invalidate either stage. Retry only a finite
      // number of times; never publish a changed empty page or the UTC probe.
      for (var attempt = 0; attempt < 3; attempt++) {
        var value = await _track(
          service.query(requested, expectedRevision: expectedRevision),
        );
        if (_closed || serial != _querySerial) return;
        if (value.changed) {
          requested = requested.copyWith(
            offset: 0,
            dayEdgesMs: all ? [] : null,
          );
          _query = requested;
          expectedRevision = null;
          continue;
        }
        if (all) {
          if (requested.dayEdgesMs.isEmpty) {
            final from = value.daily.firstOrNull?.fromMs;
            final to = value.daily.lastOrNull?.toMs;
            bucketDays = 1;
            if (from != null && to != null && from < to) {
              final civil = globalCivilBuckets(from, to, calendar: _calendar);
              bucketDays = civil.daysPerBucket;
              requested = requested.copyWith(dayEdgesMs: civil.edges);
              final revision = value.revision;
              value = await _track(
                service.query(requested, expectedRevision: revision),
              );
              if (_closed || serial != _querySerial) return;
              if (value.changed) {
                requested = requested.copyWith(offset: 0, dayEdgesMs: []);
                _query = requested;
                expectedRevision = null;
                continue;
              }
            }
          }
          value = value.withCivilBuckets(bucketDays);
        }
        _query = requested;
        _snapshot = value;
        if (all) _allBucketDays = bucketDays;
        _error = null;
        return;
      }
      throw StateError('global_index_changed_during_query');
    } catch (error) {
      if (!_closed && serial == _querySerial) _error = error.toString();
    } finally {
      _queryCount--;
      if (!_closed) _notify();
    }
  }

  void _persist() {
    _preferenceRevision++;
    final preferences = GlobalPreferences(
      range: _range,
      project: _query.project,
      model: _query.model,
      status: _query.status,
      search: _query.search,
      sort: _query.sort,
    );
    final write = store.write(preferences);
    _saved = write.catchError((Object error) {
      if (!_closed) {
        _preferenceError = error.toString();
        _notify();
      }
    });
  }

  Future<void> setProject(String? value) {
    _query = _query.copyWith(
      project: value,
      clearProject: value == null,
      offset: 0,
    );
    _persist();
    return _loadQuery();
  }

  Future<void> setModel(String? value) {
    _query = _query.copyWith(
      model: value,
      clearModel: value == null,
      offset: 0,
    );
    _persist();
    return _loadQuery();
  }

  Future<void> setStatus(String? value) {
    _query = _query.copyWith(
      status: value,
      clearStatus: value == null,
      offset: 0,
    );
    _persist();
    return _loadQuery();
  }

  Future<void> setSearch(String value) {
    _query = _query.copyWith(search: value, offset: 0);
    _persist();
    return _loadQuery();
  }

  Future<void> setSort(String value) {
    _query = _query.copyWith(
      sort: value == 'tokens' ? 'tokens' : 'recent',
      offset: 0,
    );
    _persist();
    return _loadQuery();
  }

  Future<void> setRange(GlobalRange value) {
    _range = value;
    _query = _rangeQuery(
      project: _query.project,
      model: _query.model,
      status: _query.status,
      search: _query.search,
      sort: _query.sort,
    );
    _persist();
    return _loadQuery();
  }

  Future<void> clearFilters() {
    _query = _rangeQuery();
    _persist();
    return _loadQuery();
  }

  Future<void> nextPage() {
    if (_snapshot?.hasMore != true || busy) return Future.value();
    _query = _query.copyWith(offset: _query.offset + _query.limit);
    return _loadQuery(page: true);
  }

  Future<void> previousPage() {
    if (_query.offset == 0 || busy) return Future.value();
    _query = _query.copyWith(
      offset: (_query.offset - _query.limit).clamp(0, _query.offset),
    );
    return _loadQuery(page: true);
  }

  Future<void> setBackgroundObservation(bool enabled) async {
    if (_closed) return;
    _background = enabled;
    if (!enabled && !_visible) resetObservation();
    _notify();
  }

  void setMainWindowVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (!visible && !_background) resetObservation();
  }

  void resetObservation() {
    if (_closed) return;
    final previous = _generation++;
    _querySerial++;
    unawaited(_track(service.cancel(previous)).catchError((Object _) {}));
  }

  Future<void> suspend() async {
    if (_closed || _suspended) return;
    _suspended = true;
    resetObservation();
    await _refreshOperation;
  }

  Future<void> resume() async {
    await _refreshOperation;
    if (_closed) return;
    _suspended = false;
    if (_visible || _background) await refresh();
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _querySerial++;
    final previous = _generation++;
    Object? firstError;
    StackTrace? firstStack;
    Future<void> finish(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    await finish(() => service.cancel(previous));
    await finish(() async {
      await _initialization;
    });
    await finish(() async {
      await _refreshOperation;
    });
    await finish(() async {
      await Future.wait(_pending.toList());
    });
    await finish(() => _saved);
    await finish(store.flush);
    await finish(service.shutdown);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (!_closed) unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}
