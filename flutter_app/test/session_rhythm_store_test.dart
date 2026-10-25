import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:codex_timezone/services/session_rhythm.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';

import 'session_rhythm_model_test.dart' show sourceA, sourceB, row;

void main() {
  test(
    'rename failure preserves destination and queue permits later rebuild',
    () async {
      final dir = await Directory.systemTemp.createTemp('rhythm-synthetic-');
      addTearDown(() => dir.delete(recursive: true));
      final destination = Directory('${dir.path}/cache.json');
      await destination.create();
      final sentinel = File('${destination.path}/preserved');
      await sentinel.writeAsString('original');
      final store = SessionRhythmStore(File(destination.path));
      await expectLater(
        store.write(RhythmCache()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await sentinel.readAsString(), 'original');
      await sentinel.delete();
      await destination.delete();
      await store.write(RhythmCache());
      expect((await store.read()).turns, isEmpty);
    },
  );
  test(
    'memory writes whole replacement snapshots without duplicate rows',
    () async {
      final store = SessionRhythmStore.memory();
      await store.write(
        RhythmCache(
          sources: [sourceA, sourceB],
          turns: [
            row(1),
            row(1, source: sourceB),
          ],
        ),
      );
      await store.write(RhythmCache(sources: [sourceA], turns: [row(2)]));
      final saved = await store.read();
      expect(saved.turns.map((t) => t.turnId), ['turn2']);
      expect(saved.sources.length, 1);
    },
  );
  test(
    'portable atomic replacement restores and corrupt read preserves bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp('rhythm-synthetic-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/cache.json');
      final store = SessionRhythmStore(file);
      await store.write(RhythmCache(sources: [sourceA], turns: [row(1)]));
      await store.write(RhythmCache(sources: [sourceA], turns: [row(2)]));
      expect(
        (await SessionRhythmStore(file).read()).turns.single.turnId,
        'turn2',
      );
      expect(await File('${file.path}.tmp').exists(), false);
      await file.writeAsString('{bad');
      await expectLater(store.read(), throwsFormatException);
      expect(await file.readAsString(), '{bad');
    },
  );
  test('write failure keeps original bytes and queue recovers', () async {
    final dir = await Directory.systemTemp.createTemp('rhythm-synthetic-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    await file.writeAsString('original');
    final blocker = Directory('${file.path}.tmp');
    await blocker.create();
    final store = SessionRhythmStore(file);
    await expectLater(
      store.write(RhythmCache()),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsString(), 'original');
    await blocker.delete();
    await store.write(RhythmCache());
    await store.flush();
    expect((await store.read()).sources, isEmpty);
  });
}
