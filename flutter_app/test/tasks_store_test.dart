import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/tasks.dart';
import 'package:codex_timezone/services/task_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tasks_fixture.dart';

void main() {
  test(
    'metadata history is bounded and never persists session content',
    () async {
      final dir = await Directory.systemTemp.createTemp('task-store-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/tasks.json');
      final store = TaskStore(file);
      await store.write([
        for (var i = 0; i < 40; i++)
          TaskSnapshot.fromJson(taskFixture(id: 'task-$i', state: 'running')),
      ]);
      final text = await file.readAsString();
      expect(text, isNot(contains('session-only output')));
      expect(text, isNot(contains('approvals')));
      expect((jsonDecode(text) as Map)['tasks'], hasLength(32));
      final restored = await store.read();
      expect(restored, hasLength(32));
      expect(restored.first.state, 'interrupted');
      expect(restored.first.restored, true);
      expect(restored.first.output, isEmpty);
      expect(restored.first.cleanupPending, false);
    },
  );
  test(
    'prepared history requires prompt reentry and cannot regain ownership',
    () async {
      final store = TaskStore.memory();
      await store.write([TaskSnapshot.fromJson(taskFixture())]);
      final restored = (await store.read()).single;
      expect(restored.restored, true);
      expect(restored.state, 'prepared');
    },
  );
}
