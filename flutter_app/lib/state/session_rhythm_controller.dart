import 'package:flutter/foundation.dart';

import '../services/backend.dart';
import '../services/session_rhythm.dart';
import '../services/session_rhythm_projection.dart';
import '../services/session_rhythm_store.dart';

class SessionRhythmController extends ChangeNotifier {
  SessionRhythmController({
    required this.backend,
    required this.store,
    DateTime Function()? now,
    this.calendar,
  }) : now = now ?? DateTime.now {
    _reproject();
  }
  final LauncherBackend backend;
  final SessionRhythmStore store;
  final DateTime Function() now;
  final RhythmCalendar? calendar;
  RhythmCache _cache = RhythmCache();
  late RhythmProjection _projection;
  bool _busy = false, _disposed = false, _readBlocked = false;
  bool _initialized = false;
  Future<void>? _initialization;
  int _generation = 0, _cancelSerial = 0;
  RhythmRange _range = RhythmRange.days7;
  RhythmHour? _selectedHour;
  String? _storageError;
  final _stale = <String>{}, _sourceErrors = <String, String>{};
  Future<void> _reads = Future<void>.value();
  Future<void>? _active;
  List<RhythmSource> get sources => _cache.sources;
  List<RhythmTurn> get turns => _cache.turns;
  bool get busy => _busy;
  String? get error =>
      _sourceErrors.isEmpty ? null : _sourceErrors.values.join('\n');
  Map<String, String> get sourceErrors => Map.unmodifiable(_sourceErrors);
  String? get storageError => _storageError;
  Map<String, int> get lastReadMsBySource => _cache.lastReadMs;
  DateTime? get lastRead => _cache.lastReadMs.isEmpty
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          _cache.lastReadMs.values.reduce((a, b) => a > b ? a : b),
          isUtc: true,
        );
  bool get cacheStale => _stale.isNotEmpty;
  RhythmRange get range => _range;
  RhythmHour? get selectedHour => _selectedHour;
  RhythmProjection get projection => _projection;
  void _reproject() {
    _projection = projectSessionRhythm(
      _cache,
      now: now(),
      range: _range,
      calendar: calendar,
      selectedHour: _selectedHour,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(int generation, String key) =>
      !_disposed &&
      generation == _generation &&
      sources.any((s) => s.key == key);

  Future<void> initialize() {
    if (_disposed) return _initialization ?? Future<void>.value();
    return _initialization ??= _restore();
  }

  Future<void> _restore() async {
    try {
      final cached = await store.read();
      if (_disposed) return;
      _cache = cached;
      _stale.addAll(cached.sources.map((s) => s.key));
    } catch (_) {
      if (_disposed) return;
      _readBlocked = true;
      _storageError = '活动缓存读取失败，可重读本地日志重建';
    } finally {
      _initialized = true;
    }
    _reproject();
    _notify();
  }

  Future<void> _persist({bool rebuild = false}) async {
    if (_readBlocked && !rebuild) return;
    try {
      await store.write(_cache);
      _storageError = null;
      _readBlocked = false;
    } catch (_) {
      _storageError = '活动缓存保存失败';
    }
  }

  Future<void> addSource(RhythmSource source, {bool refresh = true}) async {
    if (_disposed) return;
    var cancellation = _cancelSerial;
    if (source.path.isEmpty || source.sessionId.isEmpty) {
      throw ArgumentError('来源路径和会话身份不能为空');
    }
    // Source mutations must derive from restored selection, including fixture
    // use before initialize(). Cancellation invalidates deferred user intent,
    // but must not discard the persisted cache that restoration is loading.
    if (!_initialized) await initialize();
    if (_disposed || cancellation != _cancelSerial) return;
    if (!sources.any((s) => s.key == source.key)) {
      // The same normalized path may only carry one expected identity at once.
      final pathKey = source.key.split('\u0000').first;
      final displaced = sources
          .where((s) => s.key.split('\u0000').first == pathKey)
          .map((s) => s.key)
          .toList();
      if (sources.length - displaced.length >= 8) {
        throw StateError('最多选择8个会话来源');
      }
      // Identity replacement and capacity enforcement are one synchronous
      // mutation. Persist only after publishing the complete replacement:
      // another selection may enter while disk I/O is pending.
      if (displaced.isNotEmpty) {
        _invalidateReads();
        for (final key in displaced) {
          _stale.remove(key);
          _sourceErrors.remove(key);
        }
      }
      cancellation = _cancelSerial;
      _cache = RhythmCache(
        sources: [...sources.where((s) => !displaced.contains(s.key)), source],
        turns: turns.where((t) => !displaced.contains(t.sourceKey)).toList(),
        lastReadMs: {
          for (final entry in _cache.lastReadMs.entries)
            if (!displaced.contains(entry.key)) entry.key: entry.value,
        },
        truncatedSources: _cache.truncatedSources.difference(displaced.toSet()),
      );
      _stale.add(source.key);
      _reproject();
      _notify();
      await _persist();
    }
    if (refresh && !_disposed && cancellation == _cancelSerial) {
      // A source selected during an existing serial read gets its own refresh,
      // while cancellation invalidates this queued intent as well as the read.
      while (_busy && !_disposed && cancellation == _cancelSerial) {
        await _active;
      }
      if (!_disposed &&
          cancellation == _cancelSerial &&
          sources.any((s) => s.key == source.key)) {
        await this.refresh(sourceKey: source.key);
      }
    }
  }

  Future<void> removeSource(String key) async {
    if (_disposed) return;
    if (!_initialized) await initialize();
    if (_disposed) return;
    // Cancel the entire active refresh: its next async boundary cannot revive
    // removed data, and subsequent sources remain explicitly stale.
    cancel();
    final lastRead = {..._cache.lastReadMs}..remove(key);
    _cache = RhythmCache(
      sources: sources.where((s) => s.key != key).toList(),
      turns: turns.where((t) => t.sourceKey != key).toList(),
      lastReadMs: lastRead,
      truncatedSources: {..._cache.truncatedSources}..remove(key),
    );
    _stale.remove(key);
    _sourceErrors.remove(key);
    _reproject();
    _notify();
    await _persist();
    _notify();
  }

  Future<Map<String, dynamic>> _call(
    Map<String, dynamic> payload,
    int generation,
    String key,
  ) {
    final read = _reads.then((_) {
      if (!_valid(generation, key)) throw const _Cancelled();
      return backend.call('session_metrics', payload);
    });
    _reads = read.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return read;
  }

  Future<List<RhythmTurn>> _snapshot(
    RhythmSource source,
    int generation,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      int? epoch, revision;
      var after = 0, chasing = 0;
      final result = <String, RhythmTurn>{};
      var changed = false;
      while (true) {
        final page = await _call(
          {
            'action': 'history',
            'path': source.path,
            'afterOrder': after,
            'limit': 256,
            'expectedEpoch': ?epoch,
            'expectedRevision': ?revision,
          },
          generation,
          source.key,
        );
        if (!_valid(generation, source.key)) throw const _Cancelled();
        if (page['historyVersion'] != 1) {
          throw const FormatException('不支持的会话历史版本');
        }
        if (page['logEpoch'] is! int ||
            page['revision'] is! int ||
            page['catchingUp'] is! bool ||
            page['changed'] is! bool) {
          throw const FormatException('无效会话历史响应');
        }
        final nextEpoch = page['logEpoch'] as int,
            nextRevision = page['revision'] as int;
        if (page['changed'] == true ||
            (epoch != null &&
                (nextEpoch != epoch || nextRevision != revision))) {
          changed = true;
          break;
        }
        if (page['catchingUp'] == true) {
          // An initial bounded poll is not a complete snapshot. Discard its
          // records and continue from zero without pinning its moving revision.
          if (epoch != null) {
            changed = true;
            break;
          }
          if (++chasing > 4096) throw StateError('日志仍在追赶，请重读');
          continue;
        }
        final info = page['sourceInfo'];
        if (info is! Map || info['id'] != source.sessionId) {
          throw StateError('会话来源身份不匹配，请重新选择');
        }
        epoch ??= nextEpoch;
        revision ??= nextRevision;
        if (page['records'] is! List) throw const FormatException('无效会话历史事实');
        var previous = after;
        for (final json in page['records'] as List) {
          final turn = RhythmTurn.fromJson(
            Map<String, dynamic>.from(json as Map),
            sourceKey: source.key,
          );
          if (turn.order <= previous) throw const FormatException('会话历史顺序无效');
          previous = turn.order;
          result[turn.turnId] = turn;
        }
        final next = page['nextOrder'];
        if (next == null) return result.values.toList();
        if (next is! int || next <= after || next != previous) {
          throw const FormatException('无效会话历史游标');
        }
        after = next;
      }
      if (!changed) break;
    }
    throw StateError('日志更新中，请重读');
  }

  Future<void> refresh({String? sourceKey}) {
    if (_disposed) return Future<void>.value();
    if (!_initialized) {
      final cancellation = _cancelSerial;
      return initialize().then<void>((_) {
        if (_disposed || cancellation != _cancelSerial) {
          return Future<void>.value();
        }
        return refresh(sourceKey: sourceKey);
      });
    }
    if (_busy) return _active ?? Future<void>.value();
    final selection = sources
        .where((s) => sourceKey == null || s.key == sourceKey)
        .toList();
    final generation = ++_generation;
    _busy = selection.isNotEmpty;
    _notify();
    final work = _refreshSources(selection, generation);
    _active = work;
    return work;
  }

  Future<void> _refreshSources(
    List<RhythmSource> selection,
    int generation,
  ) async {
    for (final source in selection) {
      if (!_valid(generation, source.key)) break;
      try {
        final facts = await _snapshot(source, generation);
        if (!_valid(generation, source.key)) break;
        final readAt = now().toUtc();
        final civilCutoff = rhythmRangeStartUtc(
          readAt,
          RhythmRange.days30,
          calendar: calendar,
        );
        final elapsedCutoff = readAt.subtract(const Duration(days: 30));
        // Keep a superset of both retention promises. A fall-back transition
        // can put the civil 30-day midnight before the elapsed-time cutoff.
        final cutoff =
            (civilCutoff.isBefore(elapsedCutoff) ? civilCutoff : elapsedCutoff)
                .millisecondsSinceEpoch;
        final retained = facts
            .where(
              (t) =>
                  (t.startedAtMs == null && t.completedAtMs == null) ||
                  (t.startedAtMs != null &&
                      t.startedAtMs! >= cutoff &&
                      t.startedAtMs! <= readAt.millisecondsSinceEpoch) ||
                  (t.completedAtMs != null &&
                      t.completedAtMs! >= cutoff &&
                      t.completedAtMs! <= readAt.millisecondsSinceEpoch) ||
                  t.activityIntervals.any(
                    (i) =>
                        i.endMs >= cutoff &&
                        i.startMs <= readAt.millisecondsSinceEpoch,
                  ),
            )
            .toList();
        // Unknown-time quality facts sort last so newest missing-time evidence
        // survives bounded retention along with the latest dated facts.
        retained.sort(
          (a, b) => (a.completedAtMs ?? a.startedAtMs ?? 8640000000000000)
              .compareTo(b.completedAtMs ?? b.startedAtMs ?? 8640000000000000),
        );
        final truncated = {..._cache.truncatedSources}..remove(source.key);
        if (retained.length > 25000) {
          retained.removeRange(0, retained.length - 25000);
          truncated.add(source.key);
        }
        _cache = RhythmCache(
          sources: sources,
          turns: [
            ...turns.where((t) => t.sourceKey != source.key),
            ...retained,
          ],
          lastReadMs: {
            ..._cache.lastReadMs,
            source.key: readAt.millisecondsSinceEpoch,
          },
          truncatedSources: truncated,
        );
        _stale.remove(source.key);
        _sourceErrors.remove(source.key);
        _reproject();
        _notify();
        await _persist(rebuild: true);
        if (!_valid(generation, source.key)) break;
        _notify();
      } on _Cancelled {
        break;
      } catch (failure) {
        if (!_valid(generation, source.key)) break;
        _stale.add(source.key);
        _sourceErrors[source.key] = failure is StateError
            ? failure.message.toString()
            : '会话历史读取失败';
        _notify();
      }
    }
    if (!_disposed && generation == _generation) {
      _busy = false;
      _notify();
    }
  }

  void _invalidateReads() {
    if (_busy) _stale.addAll(sources.map((s) => s.key));
    _generation++;
    _cancelSerial++;
    _busy = false;
  }

  void cancel() {
    if (_disposed) return;
    _invalidateReads();
    _notify();
  }

  void setRange(RhythmRange range) {
    if (_disposed) return;
    _range = range;
    _selectedHour = null;
    _reproject();
    _notify();
  }

  void selectHour(RhythmHour hour) {
    if (_disposed) return;
    _selectedHour = hour;
    _reproject();
    _notify();
  }

  void clearHour() {
    if (_disposed) return;
    _selectedHour = null;
    _reproject();
    _notify();
  }

  Future<void> shutdown() async {
    if (!_disposed) {
      cancel();
      _disposed = true;
    }
    await _initialization;
    await _reads;
    await store.flush();
  }

  @override
  void dispose() {
    if (!_disposed) {
      cancel();
      _disposed = true;
    }
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
