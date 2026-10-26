import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/account_source_store.dart';
import '../services/account_sources.dart';
import '../services/account_usage.dart';
import '../services/pet_alerts.dart';
import '../services/quota_history.dart';

/// Sole query arbiter, schedule and login owner for managed sources.
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
    this.historySink,
  }) : _now = now ?? DateTime.now;
  final AccountSourcesService service;
  final AccountSourceStore store;
  final bool offlineTrial;

  /// Application may bind its shared store before initialization/queries.
  QuotaHistorySink? historySink;
  String? historyError;
  static final String _historyRunId = _randomHistoryId();
  static int _historySequence = 0;
  final DateTime Function() _now;
  final _states = <String, AccountSourceState>{};
  final _refreshes = <String, Future<void>>{};
  final _operations = <Future<void>>{};
  final _observed = <String>{};
  final _startingNative = <String>{};
  final _cancelRequests = <String, Future<void>>{};
  final _removeRequests = <String, Future<void>>{};
  final _alerts = PetAlerts();
  Future<void> _queue = Future<void>.value(), _saved = Future<void>.value();
  Future<void>? _shutdown;
  Future<void>? _initialization;
  bool _ready = false;
  String shutdownState = 'idle';
  bool _disposed = false, _stopped = false, _suspended = false;
  Timer? _timer, _loginTimer;
  int _epoch = 0;
  String? _loginSource;
  SourceCapability? capability;
  String? catalogError, operationError;
  bool monitoring = false, alertsEnabled = true;
  int alertThreshold = 20, alertSerial = 0;
  String alert = '';
  String? alertSourceId;
  Duration interval = const Duration(seconds: 120);
  String selectedId = '', pinnedId = '';
  List<AccountSourceState> get states => List.unmodifiable(_states.values);
  AccountSourceState? get selected => _states[selectedId];
  AccountSourceState? get pinned => _states[pinnedId];
  bool get anyBusy =>
      _refreshes.isNotEmpty ||
      _loginSource != null ||
      _removeRequests.isNotEmpty;
  bool get canOperate =>
      _ready && !_stopped && !_disposed && (!offlineTrial || service.synthetic);
  bool get canMutateCatalog => canOperate && catalogError == null;
  Future<void> get saved => _saved;
  DateTime get currentTime => _now();
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(AccountSourceState source, int generation) =>
      canOperate &&
      identical(_states[source.id], source) &&
      !source.pendingRemoval &&
      source.generation == generation;
  bool isStale(AccountSourceState state) =>
      state.usage != null &&
      (state.errorKind != null ||
          _now().difference(state.usage!.fetchedAt) > interval * 2);

  Future<void> initialize(String Function() path) {
    return _initialization ??= _restore();
  }

  void _normalizeSelections() {
    final fallback =
        _states.values
            .where((source) => !source.pendingRemoval)
            .firstOrNull
            ?.id ??
        '';
    if (_states[selectedId]?.pendingRemoval != false) selectedId = fallback;
    if (_states[pinnedId]?.pendingRemoval != false) pinnedId = fallback;
  }

  Future<void> _restore() async {
    final epoch = _epoch;
    final sink = historySink;
    if (sink != null) _historyOperation(sink.flush);
    try {
      final value = await store.read();
      if (_disposed || _stopped || epoch != _epoch) return;
      final restored = <String, AccountSourceState>{};
      for (final item in (value['sources'] as List? ?? const [])) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid source');
        }
        final id = item['id'] as String;
        // Legacy catalogs may still describe the active Codex account. It is
        // outside the independent monitor catalog and never becomes queryable.
        if (id == currentAccountSource) continue;
        if (!RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(id)) {
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
        final pendingRemoval = item['pendingRemoval'] ?? false;
        if (pendingRemoval is! bool || (state.isCurrent && pendingRemoval)) {
          throw const FormatException('Invalid pending source cleanup');
        }
        state.pendingRemoval = pendingRemoval;
        _restoreStatus(state, item);
        final segment = item['historySegmentId'];
        if (segment is String &&
            RegExp(r'^segment-[a-f0-9]{32}$').hasMatch(segment)) {
          state.historySegmentId = segment;
          state.historyNeedsNewSegment = state.usage == null;
        }
        if (pendingRemoval) {
          state.usage = null;
          state.loginState = 'removing';
        }
        restored[id] = state;
      }
      _states.addAll(restored);
      selectedId = _states.containsKey(value['selectedId'])
          ? value['selectedId'] as String
          : '';
      pinnedId = _states.containsKey(value['pinnedId'])
          ? value['pinnedId'] as String
          : '';
      _normalizeSelections();
      _alerts.restore(value['cycles'], _now());
    } catch (_) {
      store.protectCorruptCatalog();
      catalogError = '来源目录读取失败，原文件保持不变。';
    }
    if (_disposed || _stopped || epoch != _epoch) return;
    _ready = true;
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
    if (!_ready || _disposed || catalogError != null) return;
    final snapshot = <String, Object?>{
      'selectedId': selectedId,
      'pinnedId': pinnedId,
      'sources': [
        for (final state in _states.values)
          {
            'id': state.id,
            'alias': state.alias,
            'generation': state.generation,
            'historySegmentId': state.historySegmentId,
            'pendingRemoval': state.pendingRemoval,
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
    if (!canMutateCatalog ||
        !_states.containsKey(id) ||
        _states[id]!.pendingRemoval) {
      return;
    }
    selectedId = id;
    _save();
    _publish();
  }

  void pin(String id) {
    if (!canMutateCatalog ||
        !_states.containsKey(id) ||
        _states[id]!.pendingRemoval) {
      return;
    }
    pinnedId = id;
    _save();
    _publish();
  }

  void rename(String id, String alias) {
    if (!canMutateCatalog ||
        !_states.containsKey(id) ||
        _states[id]!.pendingRemoval) {
      return;
    }
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
      _newHistorySegment(_states[id]!);
      _normalizeSelections();
      _save();
      _publish();
      _arm();
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

  static String _randomHistoryId() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _newHistorySegment(AccountSourceState state) {
    state.historySegmentId = 'segment-${_randomHistoryId()}';
    state.historyNeedsNewSegment = false;
  }

  void _historyOperation(
    Future<void> Function() operation, {
    bool removing = false,
  }) {
    // Future.sync also contains a synchronous sink exception, outside query
    // failure/backoff and alert handling. The queue remains owned by the sink.
    unawaited(
      Future<void>.sync(operation).catchError((Object _, StackTrace _) {
        historyError = removing ? '历史本地清理失败。' : '历史保存失败。';
        _publish();
      }),
    );
  }

  void _recordHistory(
    AccountSourceState state,
    String attemptId,
    DateTime started,
    int expectedIntervalSec, {
    AccountUsage? usage,
    String? errorKind,
  }) {
    final sink = historySink;
    if (sink == null) return;
    final windows = <QuotaHistoryWindow>[
      if (usage != null && errorKind == null)
        for (final bucket in usage.buckets)
          for (final window in bucket.windows)
            QuotaHistoryWindow(
              bucketId: bucket.id,
              role: window.role,
              durationMinutes:
                  window.durationMinutes != null && window.durationMinutes! > 0
                  ? window.durationMinutes
                  : null,
              usedPercent:
                  window.usedPercent != null &&
                      window.usedPercent!.isFinite &&
                      window.usedPercent! >= 0 &&
                      window.usedPercent! <= 100
                  ? window.usedPercent
                  : null,
              resetsAtMs: window.resetsAt?.millisecondsSinceEpoch,
              quality:
                  window.usedPercent != null &&
                      window.usedPercent!.isFinite &&
                      window.usedPercent! >= 0 &&
                      window.usedPercent! <= 100 &&
                      window.role != UsageWindowRole.unknown
                  ? QuotaHistoryWindowQuality.valid
                  : QuotaHistoryWindowQuality.unknown,
            ),
    ];
    final record = QueryHistoryRecord(
      attemptId: attemptId,
      sourceId: state.id,
      segmentId: state.historySegmentId!,
      startedAtMs: started.toUtc().millisecondsSinceEpoch,
      completedAtMs: (usage?.fetchedAt ?? _now())
          .toUtc()
          .millisecondsSinceEpoch,
      timeQuality:
          usage?.timeQuality ??
          UsageObservationTimeQuality.localReceiptFallback,
      expectedIntervalSec: expectedIntervalSec,
      outcome: errorKind != null
          ? QueryHistoryOutcome.failure
          : windows.any((w) => w.quality == QuotaHistoryWindowQuality.valid)
          ? QueryHistoryOutcome.success
          : QueryHistoryOutcome.noLimits,
      errorKind: errorKind,
      windows: windows,
    );
    _historyOperation(() => sink.append(record));
  }

  /// Same-source callers receive the identical future; global reads run FIFO.
  Future<void> refresh(String id, {bool details = false}) {
    final existing = _refreshes[id];
    if (existing != null) return existing;
    final state = _states[id];
    if (!canOperate ||
        _suspended ||
        state == null ||
        state.loggingIn ||
        state.pendingRemoval ||
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
          final started = state.lastAttempt!;
          final expectedIntervalSec = interval.inSeconds;
          final attemptId = '$_historyRunId:${++_historySequence}';
          if (state.historyNeedsNewSegment || state.historySegmentId == null) {
            _newHistorySegment(state);
          }
          _publish();
          AccountUsage? completedObservation;
          try {
            final result = await service.query(id);
            if (!_valid(state, generation)) return;
            completedObservation = result;
            if (result.limitsErrorKind != null ||
                (result.limitsError != null && result.buckets.isEmpty)) {
              throw SourceFailure(result.limitsErrorKind ?? 'unavailable');
            }
            if (state.usage != null &&
                state.usage!.identity != result.identity) {
              _newHistorySegment(state);
            }
            _recordHistory(
              state,
              attemptId,
              started,
              expectedIntervalSec,
              usage: result,
            );
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
              alertSourceId = state.id;
              alertSerial++;
            }
            _observed.add('$id:$generation');
          } catch (error) {
            if (_valid(state, generation)) {
              state.errorKind = _kind(error);
              _recordHistory(
                state,
                attemptId,
                started,
                expectedIntervalSec,
                usage: completedObservation,
                errorKind: state.errorKind,
              );
              state.failures = math.min(64, state.failures + 1);
              if ([
                'auth_required',
                'auth_failed',
                'identity_changed',
              ].contains(state.errorKind)) {
                state.usage = null;
                state.historyNeedsNewSegment = true;
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
      timeQuality: value.timeQuality,
    );
  }

  bool get cycleMuted => selected == null || _alertUsage(selected!) == null
      ? false
      : _alerts.isMuted(_alertUsage(selected!)!, _now());
  void muteCurrentCycle() {
    if (!canMutateCatalog) return;
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

  List<AccountSourceState> _eligible() =>
      _states.values
          .where(
            (source) =>
                !source.loggingIn &&
                !source.pendingRemoval &&
                !_refreshes.containsKey(source.id),
          )
          .toList()
        ..sort(
          (a, b) =>
              (a.nextRefreshAt ?? _now()).compareTo(b.nextRefreshAt ?? _now()),
        );

  void _arm() {
    _timer?.cancel();
    if (!canOperate || !monitoring || _suspended || _refreshes.isNotEmpty) {
      return;
    }
    final candidates = _eligible();
    if (candidates.isEmpty) return;
    final due = candidates.first.nextRefreshAt ?? _now();
    _timer = Timer(
      due.isAfter(_now()) ? due.difference(_now()) : Duration.zero,
      _dispatchDue,
    );
  }

  void _dispatchDue() {
    if (!canOperate || !monitoring || _suspended || _refreshes.isNotEmpty) {
      return;
    }
    // Eligibility can change after arming, especially while login starts/cancels.
    final candidates = _eligible();
    if (candidates.isEmpty) return;
    final source = candidates.first;
    if (source.nextRefreshAt?.isAfter(_now()) == true) {
      _arm();
      return;
    }
    unawaited(refresh(source.id));
    if (!_refreshes.containsKey(source.id)) _arm();
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

  /// Launcher changes do not change independently logged-in monitor accounts.
  void sourceChanged(String path) {}

  Future<void> login(String id) => _track(() => _login(id));
  Future<void> _login(String id) async {
    final state = _states[id];
    if (!canMutateCatalog ||
        state == null ||
        state.isCurrent ||
        state.pendingRemoval ||
        _loginSource != null) {
      return;
    }
    final generation = ++state.generation;
    _newHistorySegment(state);
    state.usage = null;
    state.errorKind = null;
    state.loginState = 'starting';
    _loginSource = id;
    _save();
    _publish();
    _arm();
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
      late String job;
      _startingNative.add(id);
      try {
        job = await service.loginStart(id);
      } finally {
        _startingNative.remove(id);
      }
      if (!_valid(state, generation)) {
        if (identical(_states[id], state)) {
          state.jobId = job;
          _loginSource = id;
          await _cancelOwnedJob(state, job);
        } else {
          // Native removal acknowledgement already proves source cleanup.
          try {
            await service.loginCancel(id, job);
          } catch (error) {
            operationError = sourceErrorMessage(_kind(error));
            _publish();
          }
        }
        return;
      }
      state.jobId = job;
      state.loginState = 'waiting';
      _pollLater(id, generation);
      _publish();
      _arm();
    } catch (error) {
      if (_valid(state, generation)) {
        state.loginState = 'failed';
        state.errorKind = _kind(error);
        _loginSource = null;
        _save();
        _publish();
        _arm();
      } else if (identical(_states[id], state) &&
          state.loginState == 'cancelling' &&
          state.jobId == null) {
        state.loginState = 'cancelled';
        if (_loginSource == id) _loginSource = null;
        _save();
        _publish();
        _arm();
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
        !['starting', 'waiting'].contains(state.loginState) ||
        state.pendingRemoval ||
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
    final pending = _cancelRequests[id];
    if (pending != null) return pending;
    final state = _states[id];
    if (!canOperate ||
        state == null ||
        state.isCurrent ||
        state.pendingRemoval) {
      return;
    }
    ++state.generation;
    state.usage = null;
    if (_loginSource == id) _loginTimer?.cancel();
    final job = state.jobId;
    if (job != null) {
      await _cancelOwnedJob(state, job);
    } else if (_startingNative.contains(id)) {
      // The native job handle is not known yet; retain exclusive cleanup ownership.
      state.loginState = 'cancelling';
      _loginSource = id;
      _save();
      _publish();
      _arm();
    } else {
      state.loginState = 'cancelled';
      state.errorKind = null;
      if (_loginSource == id) _loginSource = null;
      _save();
      _publish();
      _arm();
    }
    await saved;
  }

  Future<void> _cancelOwnedJob(AccountSourceState state, String job) {
    final pending = _cancelRequests[state.id];
    if (pending != null) return pending;
    late Future<void> operation;
    operation = _doCancelOwnedJob(state, job).whenComplete(() {
      _cancelRequests.remove(state.id);
    });
    _cancelRequests[state.id] = operation;
    return operation;
  }

  Future<void> _doCancelOwnedJob(AccountSourceState state, String job) async {
    final generation = state.generation;
    if (!state.pendingRemoval) state.loginState = 'cancelling';
    state.jobId = job;
    _loginSource = state.id;
    _publish();
    _arm();
    try {
      final status = await service.loginCancel(state.id, job);
      if (identical(_states[state.id], state) && state.jobId == job) {
        state.jobId = null;
        if (_loginSource == state.id) _loginSource = null;
        if (_valid(state, generation)) {
          state.loginState = status.state;
          state.errorKind = status.errorKind == null
              ? null
              : (_publicErrorKinds.contains(status.errorKind)
                    ? status.errorKind
                    : 'unavailable');
        }
        operationError = null;
      }
    } catch (error) {
      if (identical(_states[state.id], state) && state.jobId == job) {
        if (!state.pendingRemoval) state.loginState = 'cancel_failed';
        state.errorKind = _kind(error);
        operationError = sourceErrorMessage(state.errorKind);
      }
    } finally {
      _save();
      _publish();
      _arm();
    }
  }

  Future<void> remove(String id) {
    final pending = _removeRequests[id];
    if (pending != null) return pending;
    late Future<void> operation;
    operation = _track(() => _remove(id)).whenComplete(() {
      _removeRequests.remove(id);
      _publish();
    });
    _removeRequests[id] = operation;
    return operation;
  }

  Future<void> _remove(String id) async {
    final state = _states[id];
    if (!canMutateCatalog || state == null || state.isCurrent) return;
    ++state.generation;
    state.pendingRemoval = true;
    state.usage = null;
    state.loginState = 'removing';
    state.errorKind = null;
    state.failures = 0;
    state.nextRefreshAt = null;
    _normalizeSelections();
    if (_loginSource == id) _loginTimer?.cancel();
    _save();
    _publish();
    _arm();
    await saved;
    if (catalogError != null) return;
    var acknowledged = false;
    try {
      await service.remove(id);
      acknowledged = true;
    } catch (error) {
      if (error is SourceFailure && error.kind == 'not_found') {
        acknowledged = true;
      } else if (identical(_states[id], state)) {
        state.errorKind = _kind(error);
        operationError = sourceErrorMessage(state.errorKind);
      }
    }
    if (acknowledged && identical(_states[id], state)) {
      operationError = null;
      _states.remove(id);
      final sink = historySink;
      if (sink != null) {
        _historyOperation(() => sink.removeSource(id), removing: true);
      }
      if (_loginSource == id) _loginSource = null;
      _normalizeSelections();
    }
    _save();
    _publish();
    _arm();
    await saved;
  }

  Future<void> shutdown() =>
      _shutdown ??= _shutdownAll().catchError((Object error) {
        _shutdown = null;
        throw error;
      });
  Future<void> _shutdownAll() async {
    if (!_stopped) {
      _stopped = true;
      ++_epoch;
      for (final state in _states.values) {
        state.generation++;
      }
    }
    shutdownState = 'pending';
    monitoring = false;
    _timer?.cancel();
    _loginTimer?.cancel();
    _publish();
    try {
      try {
        if (!offlineTrial || service.synthetic) await service.shutdown();
      } finally {
        await _initialization;
        await _queue;
        while (_operations.isNotEmpty) {
          await Future.wait(_operations.toList());
        }
        await saved;
        try {
          await historySink?.flush();
        } catch (_) {
          historyError = '历史保存失败。';
          _publish();
        }
      }
      shutdownState = 'succeeded';
    } catch (error) {
      shutdownState = 'failed';
      throw SourceFailure(_kind(error));
    } finally {
      _publish();
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
