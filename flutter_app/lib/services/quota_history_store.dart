import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'quota_history.dart';

final _dayFile = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:\.part-(\d{3,}))?\.jsonl$');
String _day(DateTime time) => time.toUtc().toIso8601String().substring(0, 10);

/// Only source and completion-time range are filtered here. All barriers and
/// segments survive for the pure projection to select and connect safely.
QuotaHistoryReadResult _parse(
  List<String> contents,
  QuotaHistoryFilter filter,
) {
  final rows = <QueryHistoryRecord>[], seen = <String>{};
  var gap = false, anyGap = false;
  for (final content in contents) {
    for (final line in const LineSplitter().convert(content)) {
      if (line.trim().isEmpty) continue;
      try {
        final row = QueryHistoryRecord.fromJson(
          jsonDecode(line) as Map<String, dynamic>,
          storageGapBefore: gap,
        );
        if (row.sourceId != filter.sourceId) {
          throw const FormatException('Wrong source');
        }
        if (!seen.add(row.attemptId)) continue;
        if (row.completedAtMs >=
                filter.fromUtc.toUtc().millisecondsSinceEpoch &&
            row.completedAtMs <= filter.toUtc.toUtc().millisecondsSinceEpoch) {
          rows.add(row);
          gap = false;
        }
      } catch (_) {
        gap = true;
        anyGap = true;
      }
    }
  }
  return QuotaHistoryReadResult(records: rows, hasStorageGaps: anyGap);
}

class _DayFiles {
  _DayFiles(this.source, this.day, this.files, this.count);
  final String source, day;
  final List<File> files;
  final int count;
}

/// One recoverable write queue for appends, removals and whole-day retention.
class QuotaHistoryStore implements QuotaHistorySink {
  QuotaHistoryStore(
    this.directory, {
    DateTime Function()? now,
    this.perSourceTarget = 25000,
    this.globalTarget = 100000,
  }) : _now = now ?? DateTime.now;
  QuotaHistoryStore.memory({
    DateTime Function()? now,
    this.perSourceTarget = 25000,
    this.globalTarget = 100000,
  }) : directory = null,
       _now = now ?? DateTime.now;
  factory QuotaHistoryStore.portable() => QuotaHistoryStore(
    Directory(
      '${File(Platform.resolvedExecutable).parent.path}/quota-history-v1',
    ),
  );
  final Directory? directory;
  final int perSourceTarget, globalTarget;
  final DateTime Function() _now;
  Future<void> _pending = Future<void>.value();
  final _memory = <QueryHistoryRecord>[];
  String? _retentionDay;

  Future<void> _enqueue(Future<void> Function() work) {
    final operation = _pending.then((_) => work());
    // Handle each operation immediately, while returning its own error to caller.
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _validateSource(String id) {
    if (!RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'sourceId', 'Invalid history source');
    }
  }

  Future<Directory> _sourceDirectory(String id) async {
    _validateSource(id);
    final result = Directory('${directory!.absolute.path}/$id');
    if (await FileSystemEntity.type(result.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'History source must not be a link',
        result.path,
      );
    }
    return result;
  }

  Future<List<File>> _files(Directory source) async {
    if (!await source.exists()) return [];
    final files = <File>[];
    await for (final entity in source.list(followLinks: false)) {
      if (entity is File && _dayFile.hasMatch(entity.uri.pathSegments.last)) {
        files.add(entity);
      }
    }
    files.sort((a, b) {
      final left = _dayFile.firstMatch(a.uri.pathSegments.last)!,
          right = _dayFile.firstMatch(b.uri.pathSegments.last)!;
      final day = left[1]!.compareTo(right[1]!);
      return day != 0
          ? day
          : int.parse(left[2] ?? '0').compareTo(int.parse(right[2] ?? '0'));
    });
    return files;
  }

  Future<bool> _cleanTail(File file) async {
    if (!await file.exists()) return true;
    final input = await file.open();
    try {
      final length = await input.length();
      if (length == 0) return true;
      await input.setPosition(length > 65536 ? length - 65536 : 0);
      final bytes = await input.read(65536);
      if (bytes.last != 10) return false;
      final lines = const LineSplitter().convert(
        utf8.decode(bytes, allowMalformed: true),
      );
      final last = lines.where((s) => s.trim().isNotEmpty).lastOrNull;
      if (last != null) {
        QueryHistoryRecord.fromJson(jsonDecode(last) as Map<String, dynamic>);
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      await input.close();
    }
  }

  @override
  Future<void> append(QueryHistoryRecord record) => _enqueue(() async {
    _validateSource(record.sourceId);
    await _maintain();
    if (directory == null) {
      _memory.add(record);
      return;
    }
    final source = await _sourceDirectory(record.sourceId);
    await source.create(recursive: true);
    final day = _day(
      DateTime.fromMillisecondsSinceEpoch(record.completedAtMs, isUtc: true),
    );
    final files = (await _files(source))
        .where((f) => _dayFile.firstMatch(f.uri.pathSegments.last)![1] == day)
        .toList();
    var file = files.isEmpty ? File('${source.path}/$day.jsonl') : files.last;
    if (!await _cleanTail(file)) {
      final part =
          int.parse(
            _dayFile.firstMatch(file.uri.pathSegments.last)![2] ?? '0',
          ) +
          1;
      file = File(
        '${source.path}/$day.part-${part.toString().padLeft(3, '0')}.jsonl',
      );
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('History file must not be a link', file.path);
    }
    await file.writeAsString(
      '${jsonEncode(record.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  });
  @override
  Future<void> removeSource(String sourceId) => _enqueue(() async {
    _validateSource(sourceId);
    if (directory == null) {
      _memory.removeWhere((r) => r.sourceId == sourceId);
      return;
    }
    final source = await _sourceDirectory(sourceId);
    // The validated single path is generated under this store's absolute root.
    if (await source.exists()) await source.delete(recursive: true);
  });
  @override
  Future<void> flush() => _enqueue(_maintain);

  Future<QuotaHistoryReadResult> read(QuotaHistoryFilter filter) async {
    _validateSource(filter.sourceId);
    await _enqueue(_maintain);
    if (directory == null) {
      return _parse(
        _memory
            .where((r) => r.sourceId == filter.sourceId)
            .map((r) => jsonEncode(r.toJson()))
            .toList(),
        filter,
      );
    }
    final files = await _files(await _sourceDirectory(filter.sourceId));
    final from = _day(filter.fromUtc), to = _day(filter.toUtc);
    final contents = <String>[];
    for (final file in files) {
      final day = _dayFile.firstMatch(file.uri.pathSegments.last)![1]!;
      if (day.compareTo(from) >= 0 && day.compareTo(to) <= 0) {
        contents.add(
          await file.readAsString(
            encoding: const Utf8Codec(allowMalformed: true),
          ),
        );
      }
    }
    return Isolate.run(() => _parse(contents, filter));
  }

  Future<void> _maintain() async {
    final today = _day(_now());
    if (_retentionDay == today) return;
    final oldest = _day(
      DateTime.parse('${today}T00:00:00Z').subtract(const Duration(days: 29)),
    );
    if (directory == null) {
      _memory.removeWhere(
        (r) =>
            _day(
              DateTime.fromMillisecondsSinceEpoch(r.completedAtMs, isUtc: true),
            ).compareTo(oldest) <
            0,
      );
      final groups = <String, List<QueryHistoryRecord>>{};
      for (final row in _memory) {
        groups
            .putIfAbsent(
              '${_day(DateTime.fromMillisecondsSinceEpoch(row.completedAtMs, isUtc: true))}/${row.sourceId}',
              () => [],
            )
            .add(row);
      }
      final keys = groups.keys.toList()..sort();
      final counts = <String, int>{};
      for (final row in _memory) {
        counts.update(row.sourceId, (n) => n + 1, ifAbsent: () => 1);
      }
      var total = _memory.length;
      for (final key in keys) {
        final rows = groups[key]!, source = rows.first.sourceId;
        if (counts[source]! > perSourceTarget || total > globalTarget) {
          _memory.removeWhere(rows.contains);
          counts[source] = counts[source]! - rows.length;
          total -= rows.length;
        }
      }
    } else if (await directory!.exists()) {
      final groups = <_DayFiles>[];
      await for (final entity in directory!.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final id = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(id)) continue;
        final byDay = <String, List<File>>{};
        for (final file in await _files(entity)) {
          final day = _dayFile.firstMatch(file.uri.pathSegments.last)![1]!;
          byDay.putIfAbsent(day, () => []).add(file);
        }
        for (final entry in byDay.entries) {
          if (entry.key.compareTo(oldest) < 0) {
            for (final file in entry.value) {
              await file.delete();
            }
            continue;
          }
          final ids = <String>{};
          for (final file in entry.value) {
            for (final line in const LineSplitter().convert(
              await file.readAsString(
                encoding: const Utf8Codec(allowMalformed: true),
              ),
            )) {
              try {
                ids.add(
                  QueryHistoryRecord.fromJson(
                    jsonDecode(line) as Map<String, dynamic>,
                  ).attemptId,
                );
              } catch (_) {
                /* Preserve corrupt facts and files. */
              }
            }
          }
          groups.add(_DayFiles(id, entry.key, entry.value, ids.length));
        }
      }
      groups.sort((a, b) {
        final day = a.day.compareTo(b.day);
        return day != 0 ? day : a.source.compareTo(b.source);
      });
      final counts = <String, int>{};
      var total = 0;
      for (final g in groups) {
        counts.update(g.source, (n) => n + g.count, ifAbsent: () => g.count);
        total += g.count;
      }
      // Per-source target first, so global pressure cannot discard newer days
      // while an over-target source still retains its oldest day.
      final removed = <_DayFiles>{};
      for (final g in groups) {
        if (counts[g.source]! > perSourceTarget) {
          for (final file in g.files) {
            await file.delete();
          }
          removed.add(g);
          counts[g.source] = counts[g.source]! - g.count;
          total -= g.count;
        }
      }
      for (final g in groups) {
        if (total <= globalTarget) break;
        if (removed.contains(g)) continue;
        for (final file in g.files) {
          await file.delete();
        }
        total -= g.count;
      }
    }
    _retentionDay = today;
  }
}
