import 'dart:io';
import 'dart:convert';

import 'session_rhythm.dart';

class SessionRhythmStore {
  SessionRhythmStore(this.file);
  SessionRhythmStore.memory() : file = null;
  factory SessionRhythmStore.portable() => SessionRhythmStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/session-rhythm-v1.json',
    ),
  );
  final File? file;
  Future<void> _pending = Future<void>.value();
  RhythmCache _memory = RhythmCache();
  Future<T> _enqueue<T>(Future<T> Function() work) {
    final result = _pending.then((_) => work());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<RhythmCache> read() => _enqueue(() async {
    if (file == null) return _memory;
    if (!await file!.exists()) return RhythmCache();
    // Never clear or rewrite a malformed cache as a side effect of reading it.
    final value = jsonDecode(await file!.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid rhythm cache');
    }
    return RhythmCache.fromJson(value);
  });
  Future<void> write(RhythmCache cache) => _enqueue(() async {
    // Round-trip validation applies equally to injected in-memory and disk stores.
    final validated = RhythmCache.fromJson(cache.toJson());
    if (file == null) {
      _memory = validated;
      return;
    }
    await file!.parent.create(recursive: true);
    final temporary = File('${file!.path}.tmp');
    await temporary.writeAsString(jsonEncode(validated.toJson()), flush: true);
    // Dart File.rename replaces an existing file; no delete-first gap.
    await temporary.rename(file!.path);
  });
  Future<void> flush() => _pending;
}
