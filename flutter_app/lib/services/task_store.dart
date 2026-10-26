import 'dart:convert';
import 'dart:io';

import 'tasks.dart';

/// Metadata only. Session prompts, output, approvals and answers never enter disk.
class TaskStore {
  TaskStore(this.file);
  TaskStore.memory() : file = null;
  factory TaskStore.portable() => TaskStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/tasks-state-v1.json',
    ),
  );
  final File? file;
  String? _memory;
  bool _backupBeforeWrite = false;
  Future<void> _writes = Future.value();
  Future<List<TaskSnapshot>> read() async {
    final source = file;
    if (source != null && !await source.exists()) return [];
    final text = source == null ? _memory : await source.readAsString();
    if (text == null) return [];
    try {
      final raw = jsonDecode(text);
      if (raw is! Map<String, dynamic> ||
          raw['version'] != 1 ||
          raw['tasks'] is! List ||
          (raw['tasks'] as List).length > 32) {
        throw const FormatException('invalid_task_history');
      }
      final result = (raw['tasks'] as List)
          .map((v) => TaskSnapshot.fromMetadata(v as Map<String, dynamic>))
          .toList();
      if (result.map((t) => t.taskId).toSet().length != result.length) {
        throw const FormatException('duplicate_task_history');
      }
      return List.unmodifiable(result);
    } catch (_) {
      _backupBeforeWrite = true;
      rethrow;
    }
  }

  Future<void> write(List<TaskSnapshot> tasks) {
    final metadata = tasks
        .take(32)
        .map((t) => TaskSnapshot.fromMetadata(t.toMetadata()).toMetadata())
        .toList();
    final text = jsonEncode({'version': 1, 'tasks': metadata});
    final operation = _writes.then((_) async {
      final target = file;
      if (target == null) {
        _memory = text;
        return;
      }
      if (_backupBeforeWrite && await target.exists()) {
        await target.copy(
          '${target.path}.invalid-${DateTime.now().microsecondsSinceEpoch}.bak',
        );
        _backupBeforeWrite = false;
      }
      final temp = File('${target.path}.tmp');
      await temp.writeAsString(text, flush: true);
      await temp.rename(target.path);
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}
