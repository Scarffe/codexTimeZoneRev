import 'dart:convert';
import 'dart:io';

import 'session_attention.dart';

/// Serialized local reference journal; replace only after a flushed temp write.
class SessionAttentionStore {
  SessionAttentionStore(this.file);
  factory SessionAttentionStore.portable() => SessionAttentionStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/session-attention-v1.json',
    ),
  );
  final File file;
  bool _backupBeforeWrite = false;
  Future<void> _writes = Future.value();
  Future<SessionAttentionSnapshot?> read() async {
    await _writes;
    if (!await file.exists()) return null;
    try {
      return SessionAttentionSnapshot.fromJson(
        (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      _backupBeforeWrite = true;
      rethrow;
    }
  }

  Future<void> write(SessionAttentionSnapshot snapshot) {
    final text = jsonEncode(
      SessionAttentionSnapshot.fromJson(snapshot.toJson()).toJson(),
    );
    final write = _writes.then((_) async {
      await file.parent.create(recursive: true);
      if (_backupBeforeWrite && await file.exists()) {
        await file.copy(
          '${file.path}.invalid-${DateTime.now().microsecondsSinceEpoch}.bak',
        );
        _backupBeforeWrite = false;
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> flush() => _writes;
}
