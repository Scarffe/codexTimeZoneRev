import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/runtime_account.dart';

class RuntimeAccountController extends ChangeNotifier {
  RuntimeAccountController(
    this.service, {
    this.pollInterval = const Duration(milliseconds: 750),
    this.maxPolls = 12,
  });
  final RuntimeAccountService service;
  final Duration pollInterval;
  final int maxPolls;
  RuntimeAccountStatus status = const RuntimeAccountStatus();
  bool busy = false;
  bool checking = false;
  String? requestedSourceId;
  bool _disposed = false, _closing = false, _statusKnown = false;
  int _epoch = 0, _pollsLeft = 0;
  Timer? _poll;
  Future<void>? _initialization, _reading, _shutdown;

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    await refresh();
    if (_disposed || _closing) return;
    _pollsLeft = maxPolls;
    _schedulePoll();
  }

  Future<void> connect() => _act('connect');
  Future<void> useSource(String id) => _act('switch', sourceId: id);
  Future<void> cancel() => _act('cancel', allowBusy: true);
  Future<void> reconcile() => _act('reconcile');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _apply(RuntimeAccountStatus value) {
    status = value;
    _statusKnown = true;
    if (!value.preparing &&
        !value.pendingSourceRetained &&
        ![
          'connecting',
          'awaiting_confirmation',
          'unresolved',
        ].contains(value.phase)) {
      requestedSourceId = null;
    }
  }

  void _failed(Object error) {
    _statusKnown = false;
    status = status.withError(
      error is RuntimeAccountFailure ? error.kind : 'unavailable',
    );
  }

  Future<void> _act(
    String action, {
    String? sourceId,
    bool allowBusy = false,
  }) async {
    if (_disposed || _closing || (busy && !allowBusy)) return;
    _poll?.cancel();
    final epoch = ++_epoch;
    if (action == 'switch') requestedSourceId = sourceId;
    busy = true;
    _notify();
    try {
      final result = await service.request(action, sourceId: sourceId);
      if (_disposed || _closing || epoch != _epoch) return;
      _apply(result);
      if (action == 'switch' &&
          const {
            'busy',
            'owner_busy',
            'source_busy',
            'auth_required',
            'invalid_request',
            'not_written',
          }.contains(result.errorKind)) {
        // Another interface may own the pending operation. This rejected
        // request did not establish ownership of its locally requested target.
        requestedSourceId = null;
      }
    } catch (error) {
      if (_disposed || _closing || epoch != _epoch) return;
      _failed(error);
    } finally {
      if (!_disposed && !_closing && epoch == _epoch) {
        busy = false;
        _notify();
        _pollsLeft = maxPolls;
        _schedulePoll();
      }
    }
  }

  Future<void> refresh() {
    if (_disposed || _closing || busy) return Future<void>.value();
    return _reading ??= _read().whenComplete(() => _reading = null);
  }

  Future<void> _read() async {
    final epoch = _epoch;
    checking = true;
    _notify();
    try {
      final result = await service.request('status');
      if (_disposed || _closing || epoch != _epoch) return;
      _apply(result);
    } catch (error) {
      if (_disposed || _closing || epoch != _epoch) return;
      _failed(error);
    } finally {
      if (!_disposed) {
        checking = false;
        _notify();
      }
    }
  }

  bool get _needsPoll =>
      status.preparing ||
      const {
        'connecting',
        'awaiting_confirmation',
        'unresolved',
      }.contains(status.phase);

  void _schedulePoll() {
    if (_disposed || _closing || !_needsPoll || _pollsLeft <= 0) return;
    final epoch = _epoch;
    _poll = Timer(pollInterval, () async {
      if (_disposed || _closing || epoch != _epoch) return;
      _pollsLeft--;
      await refresh();
      if (epoch == _epoch) _schedulePoll();
    });
  }

  Future<void> shutdown() => _shutdown ??= _shutdownUnowned();
  Future<void> _shutdownUnowned() async {
    _closing = true;
    _epoch++;
    _poll?.cancel();
    if (!_statusKnown ||
        busy ||
        !status.connected ||
        status.activeSourceRetained ||
        status.pendingSourceRetained ||
        status.preparing) {
      return;
    }
    try {
      // An owner may have appeared since the snapshot. The helper arbitrates it.
      await service.request('stop_unowned');
    } catch (_) {
      // Interface shutdown never tears down a retained credential provider.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _poll?.cancel();
    super.dispose();
  }
}
