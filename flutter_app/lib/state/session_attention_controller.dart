import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../services/backend.dart';
import '../services/session_attention.dart';
import '../services/session_attention_store.dart';

class _Observer {
  _Observer(this.watch);
  final SessionAttentionWatch watch;
  SessionAttentionItem? item;
  int? epoch;
  bool armed = false;
  final seen = <String>{};
  void reset() {
    epoch = null;
    armed = false;
    seen.clear();
  }
}

/// Explicit local watches only. Never derives completion from recency or `last`.
class SessionAttentionController extends ChangeNotifier {
  SessionAttentionController(this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final LauncherBackend backend;
  final DateTime Function() _now;
  final _observers = <String, _Observer>{};
  final _notices = <SessionAttentionNotice>[];
  List<AttentionSession> _available = const [];
  SessionAttentionStore? _store;
  Future<void> _saved = Future.value(), _reads = Future.value();
  Future<void>? _polling, _shutdown, _initialization;
  Timer? _timer;
  bool _closed = false, _disposed = false, _initialized = false;
  String? _error;
  int _alertSerial = 0;
  String _alert = '';
  DateTime? _alertUntil;
  bool _remindersEnabled = false;
  DateTime? _mutedUntil;

  List<SessionAttentionWatch> get watches =>
      List.unmodifiable(_observers.values.map((o) => o.watch));
  List<SessionAttentionItem> get items => List.unmodifiable(
    _observers.values.map(
      (o) => o.item ?? SessionAttentionItem(watch: o.watch),
    ),
  );
  List<AttentionSession> get availableSessions => _available;
  List<SessionAttentionNotice> get notices => List.unmodifiable(_notices);
  int get unreadCount => _notices.where((n) => !n.read).length;
  int get alertSerial => _alertSerial;
  String get alert => _alertUntil?.isAfter(_now()) == true ? _alert : '';
  String? get error => _error;
  bool get busy => _polling != null;
  bool get remindersEnabled => _remindersEnabled;
  DateTime? get mutedUntil => _mutedUntil;
  bool hasWatchedPath(String path) => _observers.values.any(
    (o) =>
        o.watch.enabled &&
        attentionPathIdentity(o.watch.path) == attentionPathIdentity(path),
  );
  void _notify() {
    if (!_disposed && !_closed) notifyListeners();
  }

  bool _valid(_Observer observer) =>
      !_closed &&
      observer.watch.enabled &&
      identical(_observers[observer.watch.key], observer);

  Future<Map<String, dynamic>> _read(Map<String, dynamic> payload) {
    final read = _reads.then((_) => backend.call('session_metrics', payload));
    _reads = read.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return read;
  }

  Future<void> initialize(SessionAttentionStore store) {
    if (_closed) return Future.value();
    return _initialization ??= _initialize(store);
  }

  Future<void> _initialize(SessionAttentionStore store) async {
    _initialized = true;
    _store = store;
    try {
      final snapshot = await store.read();
      if (snapshot != null) {
        for (final watch in snapshot.watches) {
          _observers[watch.key] = _Observer(watch);
        }
        _notices.addAll(snapshot.notices);
      }
    } catch (_) {
      _error = '关注记录无法恢复；原始文件将在下次保存前备份。';
    }
    if (_closed) return;
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(poll()),
    );
    _notify();
  }

  Future<void> refreshSessions() async {
    if (_closed) return;
    try {
      final value = await _read({'action': 'list'});
      if (_closed) return;
      if (value['sessions'] is! List) {
        throw const FormatException('invalid_session_list');
      }
      _available = List.unmodifiable(
        (value['sessions'] as List)
            .map(AttentionSession.fromMetadata)
            .whereType<AttentionSession>(),
      );
    } catch (_) {
      if (!_closed) _error = '会话列表读取失败。';
    }
    _notify();
  }

  Future<void> watch(String path, {String? expectedId, String? alias}) async {
    if (_closed) return;
    if (path.trim().isEmpty || path.length > 32768) {
      throw ArgumentError('invalid_attention_path');
    }
    AttentionSession? source;
    for (final session in _available) {
      if (attentionPathIdentity(session.path) == attentionPathIdentity(path)) {
        source = session;
        break;
      }
    }
    final id = expectedId ?? source?.id;
    if (id == null || id.trim().isEmpty || id.length > 32768) {
      throw ArgumentError('expectedSessionId must be nonempty');
    }
    _Observer? existing;
    for (final observer in _observers.values) {
      if (attentionPathIdentity(observer.watch.path) ==
          attentionPathIdentity(path)) {
        existing = observer;
        break;
      }
    }
    if (existing == null && _observers.length >= 8) {
      throw StateError('最多关注 8 个会话');
    }
    // Persisted key is deterministic across native process epoch resets.
    final key = sha256
        .convert(utf8.encode(jsonEncode([attentionPathIdentity(path), id])))
        .toString();
    if (existing != null && existing.watch.expectedSessionId != id) {
      throw StateError('该路径的会话标识已变化；请先移除旧关注');
    }
    final title = attentionTitle(
      alias ?? existing?.watch.alias ?? source?.title ?? '会话 $id',
    );
    final watch = SessionAttentionWatch(
      key: key,
      path: existing?.watch.path ?? path,
      expectedSessionId: id,
      alias: title,
    );
    if (existing == null) {
      _observers[key] = _Observer(watch);
    } else if (existing.watch.alias != title || !existing.watch.enabled) {
      _observers[key] = _Observer(watch);
    }
    _notify();
    await _persist();
  }

  Future<void> unwatch(String key) async {
    if (_closed) return;
    _observers.remove(key);
    _notify();
    await _persist();
  }

  Future<void> setEnabled(String key, bool enabled) async {
    if (_closed) return;
    final observer = _observers[key];
    if (observer == null || observer.watch.enabled == enabled) return;
    _observers[key] = _Observer(observer.watch.copyWith(enabled: enabled));
    _notify();
    await _persist();
  }

  void configureReminders({required bool enabled, DateTime? muteUntil}) {
    if (_closed || (enabled == _remindersEnabled && muteUntil == _mutedUntil)) {
      return;
    }
    _remindersEnabled = enabled;
    _mutedUntil = muteUntil;
    resetObservation();
  }

  /// Suspend/resume must invalidate pending reads as well as baseline history.
  void resetObservation() {
    if (_closed) return;
    for (final entry in _observers.entries.toList()) {
      _observers[entry.key] = _Observer(entry.value.watch)
        ..item = entry.value.item;
    }
    _alert = '';
    _alertUntil = null;
    _notify();
  }

  Future<void> poll() {
    if (_closed) return Future.value();
    return _polling ??= _pollAll().whenComplete(() {
      _polling = null;
      _notify();
    });
  }

  Future<void> _pollAll() async {
    for (final observer in _observers.values.toList()) {
      if (!_valid(observer)) continue;
      try {
        final value = await _read({'path': observer.watch.path});
        if (!_valid(observer)) continue;
        final observation = AttentionObservation.fromSummary(
          value,
          observer.watch.expectedSessionId,
        );
        observer.item = SessionAttentionItem(
          watch: observer.watch,
          status: observation.catchingUp
              ? SessionAttentionStatus.unknown
              : observation.status,
          observedAt: _now(),
          catchingUp: observation.catchingUp,
        );
        if (observation.catchingUp ||
            observation.status == SessionAttentionStatus.unknown) {
          observer.reset();
          continue;
        }
        if (observer.epoch != observation.epoch) {
          observer.reset();
          observer.epoch = observation.epoch;
        }
        // A completed baseline already owns its current turn, even when the
        // matching terminal is absent from a partial/malformed summary.
        if (!observer.armed &&
            observation.status != SessionAttentionStatus.running &&
            observation.turnId != null) {
          observer.seen.add(observation.turnId!);
        }
        AttentionTerminal? completion;
        for (final terminal in observation.terminals) {
          if (!observer.seen.add(terminal.turnId)) continue;
          if (observer.armed &&
              terminal.status == SessionAttentionStatus.completed &&
              observation.status == SessionAttentionStatus.completed &&
              observation.turnId == terminal.turnId) {
            completion = terminal;
          }
        }
        while (observer.seen.length > 1024) {
          observer.seen.remove(observer.seen.first);
        }
        observer.armed = true;
        if (completion != null) {
          final notice = SessionAttentionNotice(
            watchKey: observer.watch.key,
            path: observer.watch.path,
            sessionId: observation.sessionId,
            turnId: completion.turnId,
            title: observer.watch.title,
            createdAt: _now(),
            durationMs: completion.durationMs,
          );
          if (_notices.any((n) => n.id == notice.id)) continue;
          _notices.add(notice);
          if (_notices.length > 200) {
            _notices.removeRange(0, _notices.length - 200);
          }
          final saved = await _persist();
          if (saved &&
              _valid(observer) &&
              _remindersEnabled &&
              _mutedUntil?.isAfter(_now()) != true) {
            _alert = '${notice.title} · 回合已结束';
            _alertUntil = _now().add(const Duration(seconds: 10));
            _alertSerial++;
            _notify();
          }
        }
      } catch (_) {
        if (_valid(observer)) {
          observer.item = SessionAttentionItem(
            watch: observer.watch,
            observedAt: observer.item?.observedAt,
            readError: '状态未知 · 会话读取失败或标识不匹配',
          );
          observer.reset();
        }
      }
      _notify();
    }
  }

  Future<bool> _persist() {
    final store = _store;
    if (store == null) {
      _error = '关注记录尚未初始化，无法保存。';
      _notify();
      return Future.value(false);
    }
    final snapshot = SessionAttentionSnapshot(
      watches: watches,
      notices: notices,
    );
    final completer = Completer<bool>();
    _saved = _saved.then((_) async {
      try {
        await store.write(snapshot);
        _error = null;
        completer.complete(true);
      } catch (_) {
        _error = '关注记录保存失败；本次提醒未发送。';
        completer.complete(false);
      }
      _notify();
    });
    return completer.future;
  }

  Future<void> markRead(String noticeId) async {
    if (_closed) return;
    for (var i = 0; i < _notices.length; i++) {
      if (_notices[i].id == noticeId) _notices[i] = _notices[i].asRead();
    }
    _notify();
    await _persist();
  }

  Future<void> markAllRead() async {
    if (_closed) return;
    for (var i = 0; i < _notices.length; i++) {
      _notices[i] = _notices[i].asRead();
    }
    _notify();
    await _persist();
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    await _initialization;
    await _polling;
    await _reads;
    await _saved;
    if (_initialized) await _persist();
    await _store?.flush();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _closed = true;
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
