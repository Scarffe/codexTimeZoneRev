import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/account_source_store.dart';
import '../services/account_sources.dart';
import '../services/account_usage.dart';
import '../services/pet_alerts.dart';

/// Sole query arbiter, schedule and login owner for current and managed sources.
class AccountSourcesController extends ChangeNotifier {
  static const _publicErrorKinds = {
    'invalid_source',
    'protected_source',
    'unavailable',
    'unsupported',
    'isolation_failed',
    'busy',
    'auth_required',
    'auth_failed',
    'timeout',
    'rate_limited',
    'network',
    'identity_changed',
    'cancelled',
    'not_found',
    'shutdown',
  };
  AccountSourcesController(
    this.service,
    this.store, {
    DateTime Function()? now,
    this.offlineTrial = false,
  }) : _now = now ?? DateTime.now {
    _states[currentAccountSource] = AccountSourceState(
      id: currentAccountSource,
      alias: '默认来源',
    );
  }
  final AccountSourcesService service;
  final AccountSourceStore store;
  final bool offlineTrial;
  final DateTime Function() _now;
  final _states = <String, AccountSourceState>{};
  final _refreshes = <String, Future<void>>{};
  final _operations = <Future<void>>{};
  final _observed = <String>{};
  final _alerts = PetAlerts();
  Future<void> _queue = Future<void>.value(), _saved = Future<void>.value();
  Future<void>? _shutdown;
  String Function() _path = () => '';
  String _currentPath = '';
  bool _disposed = false, _stopped = false, _suspended = false;
  Timer? _timer, _loginTimer;
  int _epoch = 0;
  String? _loginSource;
  SourceCapability? capability;
  String? catalogError, operationError;
  bool monitoring = false, alertsEnabled = true;
  int alertThreshold = 20, alertSerial = 0;
  String alert = '';
  Duration interval = const Duration(seconds: 120);
  String selectedId = currentAccountSource, pinnedId = currentAccountSource;
  List<AccountSourceState> get states => List.unmodifiable(_states.values);
  AccountSourceState? get selected => _states[selectedId];
  AccountSourceState? get pinned => _states[pinnedId];
  bool get anyBusy => _refreshes.isNotEmpty || _loginSource != null;
  bool get canOperate =>
      !_stopped && !_disposed && (!offlineTrial || service.synthetic);
  bool get canMutateCatalog => canOperate && catalogError == null;
  Future<void> get saved => _saved;
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(AccountSourceState source, int generation) =>
      canOperate &&
      identical(_states[source.id], source) &&
      source.generation == generation;
  bool isStale(AccountSourceState state) =>
      state.usage != null &&
      (state.errorKind != null ||
          _now().difference(state.usage!.fetchedAt) > interval * 2);

  Future<void> initialize(String Function() path) async {
    _path = path;
    _currentPath = path();
    final epoch = _epoch;
    try {
      final value = await store.read();
      if (_disposed || _stopped || epoch != _epoch) return;
      final restored = <String, AccountSourceState>{};
      for (final item in (value['sources'] as List? ?? const [])) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid source');
        }
        final id = item['id'] as String;
        if (id != currentAccountSource &&
            !RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(id)) {
          throw const FormatException('Invalid source id');
        }
        if (restored.containsKey(id)) {
          throw const FormatException('Duplicate source');
        }
        final state = AccountSourceState(
          id: id,
          alias: _alias(item['alias'] as String),
          generation: item['generation'] as int? ?? 0,
        );
        if (item['usage'] != null) {
          state.usage = AccountUsage.fromCacheJson(
            item['usage'] as Map<String, dynamic>,
          );
        }
        _restoreStatus(state, item);
        restored[id] = state;
      }
      _states.addAll(restored);
      selectedId = _states.containsKey(value['selectedId'])
          ? value['selectedId'] as String
          : currentAccountSource;
      pinnedId = _states.containsKey(value['pinnedId'])
          ? value['pinnedId'] as String
          : currentAccountSource;
      _alerts.restore(value['cycles'], _now());
    } catch (_) {
      store.protectCorruptCatalog();
      catalogError = '来源目录读取失败，原文件保持不变。';
    }
    _publish();
  }

  String _alias(String value) {
    final clean = value.trim().replaceAll(RegExp(r'[^\s@]+@[^\s@]+'), '来源');
    return clean.isEmpty
        ? '监控来源'
        : clean.substring(0, math.min(64, clean.length));
  }

  void _restoreStatus(AccountSourceState state, Map<String, dynamic> item) {
    final kind = item['errorKind'], failures = item['failures'] ?? 0;
    if ((kind != null &&
            (kind is! String || !_publicErrorKinds.contains(kind))) ||
        failures is! int ||
        failures < 0 ||
        failures > 64) {
      throw const FormatException('Invalid source availability');
    }
    DateTime? date(Object? value) {
      if (value == null) return null;
      if (value is! int || value < 0 || value > 8640000000000000) {
        throw const FormatException('Invalid source timestamp');
      }
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }

    final attempted = date(item['lastAttempt']);
    final next = date(item['nextRefreshAt']);
    final bound = interval > const Duration(minutes: 30)
        ? interval
        : const Duration(minutes: 30);
    if ((attempted != null &&
            attempted.isAfter(_now().add(const Duration(minutes: 5)))) ||
        (next != null &&
            next.isAfter(_now().add(bound + const Duration(minutes: 5)))) ||
        (failures > 0 &&
            (kind == null ||
                attempted == null ||
                next == null ||
                next.difference(attempted) >
                    bound + const Duration(minutes: 5)))) {
      throw const FormatException('Invalid source cooldown');
    }
    state.errorKind = kind as String?;
    state.failures = failures;
    state.lastAttempt = attempted;
    state.nextRefreshAt = next;
    if (['auth_required', 'auth_failed', 'identity_changed'].contains(kind)) {
      state.usage = null;
    }
  }

  void _save() {
    if (_disposed || catalogError != null) return;
    final snapshot = <String, Object?>{
      'selectedId': selectedId,
      'pinnedId': pinnedId,
      'sources': [
        for (final state in _states.values)
          {
            'id': state.id,
            'alias': state.alias,
            'generation': state.generation,
            'errorKind':
                state.errorKind ?? (state.failures > 0 ? 'unavailable' : null),
            'failures': state.failures,
            'lastAttempt': state.lastAttempt?.millisecondsSinceEpoch,
            'nextRefreshAt': state.nextRefreshAt?.millisecondsSinceEpoch,
            if (state.usage != null) 'usage': state.usage!.toCacheJson(),
          },
      ],
      'cycles': _alerts.records(_now()),
    };
    _saved = _saved.then((_) async {
      try {
        await store.write(snapshot);
      } catch (_) {
        catalogError = '来源状态保存失败，请检查文件夹权限。';
        _publish();
      }
    });
  }

  void select(String id) {
    if (!canMutateCatalog || !_states.containsKey(id)) return;
    selectedId = id;
    _save();
    _publish();
  }

  void pin(String id) {
    if (!canMutateCatalog || !_states.containsKey(id)) return;
    pinnedId = id;
    _save();
    _publish();
  }

  void rename(String id, String alias) {
    if (!canMutateCatalog || !_states.containsKey(id)) return;
    _states[id]!.alias = _alias(alias);
    _save();
    _publish();
  }

  Future<SourceCapability?> probe() => _track(_probe);
  Future<SourceCapability?> _probe() async {
    if (!canOperate) return null;
    final epoch = _epoch;
    try {
      final result = await service.probe();
      if (canOperate && epoch == _epoch) {
        capability = result;
        _publish();
        return result;
      }
    } catch (error) {
      if (canOperate && epoch == _epoch) {
        operationError = sourceErrorMessage(_kind(error));
        _publish();
      }
    }
    return null;
  }

  Future<String?> create(String alias) => _track(() => _create(alias));
  Future<String?> _create(String alias) async {
    if (!canMutateCatalog) return null;
    final epoch = _epoch;
    final supported = capability ?? await probe();
    if (!canMutateCatalog ||
        epoch != _epoch ||
        supported?.supported != true ||
        supported?.managedLogin != true) {
      return null;
    }
    try {
      final id = await service.create();
      if (!canOperate || epoch != _epoch) {
        await service.remove(id);
        return null;
      }
      if (id == currentAccountSource ||
          _states.containsKey(id) ||
          !RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(id)) {
        throw const SourceFailure('invalid_source');
      }
      _states[id] = AccountSourceState(id: id, alias: _alias(alias));
      _save();
      _publish();
      return id;
    } catch (error) {
      if (canOperate && epoch == _epoch) {
        operationError = sourceErrorMessage(_kind(error));
        _publish();
      }
    }
    return null;
  }

  Future<T> _track<T>(Future<T> Function() operation) {
    final result = operation();
    late Future<void> joined;
    joined = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _operations.remove(joined);
        });
    _operations.add(joined);
    return result;
  }

  String _kind(Object error) =>
      error is SourceFailure && _publicErrorKinds.contains(error.kind)
      ? error.kind
      : 'unavailable';

  /// Same-source callers receive the identical future; global reads run FIFO.
  Future<void> refresh(String id, {bool details = false}) {
    final existing = _refreshes[id];
    if (existing != null) return existing;
    final state = _states[id];
    if (!canOperate ||
        _suspended ||
        state == null ||
        state.loggingIn ||
        (state.failures > 0 && state.nextRefreshAt?.isAfter(_now()) == true)) {
      return Future<void>.value();
    }
    final generation = state.generation;
    final done = Completer<void>();
    _refreshes[id] = done.future;
    _queue = _queue
        .then((_) async {
          if (!_valid(state, generation) || _suspended || state.loggingIn) {
            return;
          }
          state.busy = true;
          state.attempts++;
          state.lastAttempt = _now();
          _publish();
          try {
            final result = await service.query(
              id,
              desktopPath: id == currentAccountSource ? _path() : '',
              details: id == currentAccountSource && details,
            );
            if (!_valid(state, generation)) return;
            if (id == currentAccountSource && _path() != _currentPath) {
              sourceChanged(_path());
              return;
            }
            if (result.limitsError != null && result.buckets.isEmpty) {
              throw const SourceFailure('unavailable');
            }
            state.usage = retainUsageDetails(result, state.usage);
            state.errorKind = null;
            state.failures = 0;
            state.revision++;
            final namespaced = _alertUsage(state);
            final message = _alerts.observe(
              namespaced!,
              _now(),
              threshold: alertThreshold,
            );
            if (_observed.contains('$id:$generation') &&
                message != null &&
                alertsEnabled) {
              alert = '${state.alias} · 额度偏低，请查看剩余额度。';
              alertSerial++;
            }
            _observed.add('$id:$generation');
          } catch (error) {
            if (_valid(state, generation)) {
              state.errorKind = _kind(error);
              state.failures = math.min(64, state.failures + 1);
              if ([
                'auth_required',
                'auth_failed',
                'identity_changed',
              ].contains(state.errorKind)) {
                state.usage = null;
              }
            }
          } finally {
            state.busy = false;
            if (_valid(state, generation)) {
              final seconds = state.failures == 0
                  ? interval.inSeconds
                  : math.max(
                      interval.inSeconds,
                      math.min(
                        1800,
                        30 * (1 << math.min(state.failures - 1, 6)),
                      ),
                    );
              state.nextRefreshAt = _now().add(Duration(seconds: seconds));
              _save();
            }
            _publish();
          }
        })
        .whenComplete(() {
          _refreshes.remove(id);
          done.complete();
          _arm();
        });
    return done.future;
  }

  AccountUsage? _alertUsage(AccountSourceState source) {
    final value = source.usage;
    if (value == null) return null;
    return AccountUsage(
      email: null,
      plan: null,
      identityKey: '${source.id}:${source.generation}',
      buckets: value.buckets,
      fetchedAt: value.fetchedAt,
    );
  }

  bool get cycleMuted => selected == null || _alertUsage(selected!) == null
      ? false
      : _alerts.isMuted(_alertUsage(selected!)!, _now());
  void muteCurrentCycle() {
    final value = selected == null ? null : _alertUsage(selected!);
    if (value == null) return;
    _alerts.mute(value, _now());
    alert = '';
    _save();
    _publish();
  }

  void configureAlerts({required bool enabled, required int threshold}) {
    alertsEnabled = enabled;
    alertThreshold = threshold;
    alert = '';
    _publish();
  }

  void start(String Function() path, {Duration? every}) {
    if (!canOperate) return;
    _path = path;
    sourceChanged(path());
    if (every != null) {
      interval = every < const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : every;
    }
    monitoring = true;
    var index = 0;
    for (final state in _states.values) {
      state.nextRefreshAt ??= _now().add(Duration(milliseconds: index++ * 250));
    }
    _arm();
    _publish();
  }

  void pause() {
    monitoring = false;
    _timer?.cancel();
    _timer = null;
    _publish();
  }

  void _arm() {
    _timer?.cancel();
    if (!canOperate || !monitoring || _suspended) return;
    final candidates =
        _states.values
            .where((s) => !s.loggingIn && !_refreshes.containsKey(s.id))
            .toList()
          ..sort(
            (a, b) => (a.nextRefreshAt ?? _now()).compareTo(
              b.nextRefreshAt ?? _now(),
            ),
          );
    if (candidates.isEmpty) return;
    final due = candidates.first.nextRefreshAt ?? _now();
    _timer = Timer(
      due.isAfter(_now()) ? due.difference(_now()) : Duration.zero,
      () {
        if (!canOperate || !monitoring || _suspended) return;
        // At most one due read is admitted per tick; no periodic queue buildup.
        if (_refreshes.isEmpty) unawaited(refresh(candidates.first.id));
      },
    );
  }

  void systemSuspending() {
    _suspended = true;
    _timer?.cancel();
  }

  void systemResumed() {
    if (!_suspended || !canOperate) return;
    _suspended = false;
    if (monitoring) {
      var index = 0;
      for (final state in _states.values.where(
        (state) => state.failures == 0,
      )) {
        state.nextRefreshAt = _now().add(Duration(milliseconds: index++ * 250));
      }
    }
    _arm();
  }

  void sourceChanged(String path) {
    if (_currentPath == path) return;
    _currentPath = path;
    final state = _states[currentAccountSource]!;
    state.generation++;
    state.usage = null;
    state.errorKind = null;
    state.failures = 0;
    state.nextRefreshAt = null;
    _save();
    _publish();
  }

  Future<void> login(String id) => _track(() => _login(id));
  Future<void> _login(String id) async {
    final state = _states[id];
    if (!canMutateCatalog ||
        state == null ||
        state.isCurrent ||
        _loginSource != null) {
      return;
    }
    final generation = ++state.generation;
    state.usage = null;
    state.errorKind = null;
    state.loginState = 'starting';
    _loginSource = id;
    _save();
    _publish();
    try {
      await saved;
      if (!_valid(state, generation)) return;
      if (!canMutateCatalog) throw const SourceFailure('unavailable');
      await _refreshes[id];
      if (!_valid(state, generation)) return;
      if (!canMutateCatalog) throw const SourceFailure('unavailable');
      final supported = capability ?? await probe();
      if (!_valid(state, generation)) return;
      if (!canMutateCatalog) throw const SourceFailure('unavailable');
      if (supported?.supported != true || supported?.managedLogin != true) {
        throw const SourceFailure('unsupported');
      }
      final job = await service.loginStart(id);
      if (!_valid(state, generation)) {
        await service.loginCancel(id, job);
        return;
      }
      state.jobId = job;
      state.loginState = 'waiting';
      _pollLater(id, generation);
      _publish();
    } catch (error) {
      if (_valid(state, generation)) {
        state.loginState = 'failed';
        state.errorKind = _kind(error);
        _loginSource = null;
        _save();
        _publish();
      }
    }
  }

  void _pollLater(String id, int generation) {
    _loginTimer?.cancel();
    _loginTimer = Timer(const Duration(seconds: 1), () {
      if (_states[id]?.generation == generation) unawaited(pollLogin(id));
    });
  }

  Future<void> pollLogin(String id) => _track(() => _pollLogin(id));
  Future<void> _pollLogin(String id) async {
    final state = _states[id];
    if (!canOperate ||
        state == null ||
        !state.loggingIn ||
        state.jobId == null) {
      return;
    }
    final generation = state.generation;
    try {
      final status = await service.loginStatus(id, state.jobId!);
      if (!_valid(state, generation)) return;
      state.loginState = status.state;
      state.errorKind = status.errorKind == null
          ? null
          : (_publicErrorKinds.contains(status.errorKind)
                ? status.errorKind
                : 'unavailable');
      if (status.terminal) {
        state.jobId = null;
        _loginSource = null;
        _save();
        _arm();
      } else {
        _pollLater(id, generation);
      }
      _publish();
    } catch (error) {
      if (_valid(state, generation)) {
        state.errorKind = _kind(error);
        _pollLater(id, generation);
        _publish();
      }
    }
  }

  Future<void> cancelLogin(String id) => _track(() => _cancelLogin(id));
  Future<void> _cancelLogin(String id) async {
    final state = _states[id];
    if (!canOperate || state == null || state.isCurrent) return;
    final job = state.jobId;
    ++state.generation;
    state.jobId = null;
    state.loginState = 'cancelled';
    state.usage = null;
    if (_loginSource == id) {
      _loginSource = null;
      _loginTimer?.cancel();
    }
    _save();
    _publish();
    if (job != null) {
      try {
        await service.loginCancel(id, job);
      } catch (_) {}
    }
  }

  Future<void> remove(String id) => _track(() => _remove(id));
  Future<void> _remove(String id) async {
    final state = _states[id];
    if (!canMutateCatalog || state == null || state.isCurrent) return;
    ++state.generation;
    _states.remove(id);
    if (_loginSource == id) {
      _loginSource = null;
      _loginTimer?.cancel();
    }
    if (selectedId == id) selectedId = currentAccountSource;
    if (pinnedId == id) pinnedId = currentAccountSource;
    _save();
    _publish();
    try {
      await service.remove(id);
    } catch (error) {
      operationError = sourceErrorMessage(_kind(error));
      _publish();
    }
    await saved;
    _arm();
  }

  Future<void> shutdown() => _shutdown ??= _shutdownAll();
  Future<void> _shutdownAll() async {
    _stopped = true;
    ++_epoch;
    monitoring = false;
    _timer?.cancel();
    _loginTimer?.cancel();
    for (final state in _states.values) {
      state.generation++;
    }
    _publish();
    try {
      if (!offlineTrial || service.synthetic) await service.shutdown();
    } finally {
      await _queue;
      while (_operations.isNotEmpty) {
        await Future.wait(_operations.toList());
      }
      await saved;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    _loginTimer?.cancel();
    super.dispose();
  }
}
