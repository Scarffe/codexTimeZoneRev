import 'dart:async';

import 'package:codex_timezone/services/tasks.dart';
import 'package:codex_timezone/services/task_store.dart';
import 'package:codex_timezone/state/tasks_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tasks_fixture.dart';

void main() {
  test('preview restriction immediately cancels owned official without losing pending cleanup', () async {
    final backend = TasksBackend();
    final c = TasksController(
      TaskService(backend),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    await c.initialize();
    c.updateDraft(
      mode: 'official',
      sourceId: 'profile-a',
      workspace: 'synthetic-a',
      model: 'synthetic-model',
      prompt: 'p',
    );
    final prepared = (await c.prepare())!;
    await c.start(prepared);
    final running = c.tasks.single;
    backend.pendingCancel = Completer<Map<String, dynamic>>();
    c.restrictToPreview();
    expect(c.officialEnabled, false);
    expect(c.mode, 'offline_preview');
    expect(backend.calls.last, 'task_cancel');
    expect(c.owns(running), true);
    expect(c.keepAlive, true);
    backend.pendingCancel!.complete({
      ...backend.tasks[running.taskId]!,
      'state': 'cancelled',
      'cleanupPending': false,
    });
    await c.cancelAll();
    expect(c.tasks.single.state, 'cancelled');
    expect(backend.calls.where((call) => call == 'task_start'), hasLength(1));
    await c.shutdown();
    expect(backend.calls, isNot(contains('task_shutdown')));
  });
  test(
    'untouched and restored-only owners exit without native shutdown',
    () async {
      final b = TasksBackend();
      final c = TasksController(TaskService(b));
      addTearDown(c.dispose);
      await c.initialize();
      await c.shutdown();
      expect(b.calls, ['task_catalog']);
      expect(c.cleanupComplete, true);
      final store = TaskStore.memory();
      await store.write([TaskSnapshot.fromJson(taskFixture(state: 'running'))]);
      final restoredBackend = TasksBackend();
      final restored = TasksController(
        TaskService(restoredBackend),
        store: store,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      await restored.shutdown();
      expect(restoredBackend.calls, ['task_catalog']);
      expect(restored.cleanupComplete, true);
    },
  );
  test(
    'stale prepared references and unknown start never resend start',
    () async {
      final b = TasksBackend();
      final c = TasksController(
        TaskService(b),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(c.dispose);
      await c.initialize();
      c.updateDraft(prompt: 'p');
      final prepared = (await c.prepare())!;
      await c.start(prepared);
      await c.start(prepared);
      expect(b.calls.where((call) => call == 'task_start'), hasLength(1));
      await c.cancelAll();
      final second = (await c.prepare())!;
      b.startError = 'disconnected';
      await c.start(second);
      expect(c.tasks.first.state, 'interrupted');
      expect(c.tasks.first.cleanupPending, true);
      expect(c.keepAlive, true);
      expect(c.canStart(second), false);
      await c.start(second);
      await c.poll();
      expect(b.calls.where((call) => call == 'task_status'), hasLength(1));
      expect(c.canStart(c.tasks.first), false);
      expect(b.calls.where((call) => call == 'task_start'), hasLength(2));
      await c.cancelAll();
    },
  );
  TasksController controller(TasksBackend backend, {TaskStore? store}) =>
      TasksController(
        TaskService(backend),
        store: store,
        pollInterval: const Duration(days: 1),
      );
  test('initialize, editing and keepalive never prepare or start', () async {
    final b = TasksBackend();
    final c = controller(b);
    addTearDown(c.dispose);
    await c.initialize();
    c.updateDraft(prompt: 'private', workspace: 'synthetic');
    c.rearmPolling();
    expect(b.calls, ['task_catalog']);
    final prepared = await c.prepare();
    expect(prepared, isNotNull);
    expect(b.calls, ['task_catalog', 'task_prepare']);
    c.updateDraft(prompt: 'different prompt');
    await c.start(prepared!);
    expect(
      b.payloads.last.keys,
      unorderedEquals(['taskId', 'sourceEpoch', 'generation']),
    );
    await c.cancelAll();
    expect(c.tasks.single.state, 'cancelled');
  });
  test(
    'restored records do not poll, start, cancel or resume old tasks',
    () async {
      final store = TaskStore.memory();
      await store.write([TaskSnapshot.fromJson(taskFixture(state: 'running'))]);
      final b = TasksBackend();
      final c = controller(b, store: store);
      addTearDown(c.dispose);
      await c.initialize();
      await c.poll();
      await c.start(c.tasks.single);
      await c.cancelAll();
      expect(b.calls, ['task_catalog']);
      expect(c.tasks.single.state, 'interrupted');
    },
  );
  test(
    'suspension cancels late starts and preserves issued task identity',
    () async {
      final b = TasksBackend();
      final c = controller(b);
      addTearDown(c.dispose);
      await c.initialize();
      c.updateDraft(prompt: 'p', workspace: 'synthetic');
      final t = (await c.prepare())!;
      b.pendingStart = Completer<Map<String, dynamic>>();
      final start = c.start(t);
      await Future<void>.value();
      final cancel = c.cancelAll();
      b.pendingStart!.complete({...b.tasks[t.taskId]!, 'state': 'running'});
      await start;
      await cancel;
      expect(b.calls.last, 'task_cancel');
      expect(c.tasks.single.state, 'cancelled');
    },
  );
  test('late status cannot overwrite a completed cancellation', () async {
    final b = TasksBackend();
    final c = controller(b);
    addTearDown(c.dispose);
    await c.initialize();
    c.updateDraft(prompt: 'p');
    final prepared = (await c.prepare())!;
    await c.start(prepared);
    final running = c.tasks.single;
    b.pendingStatus = Completer<Map<String, dynamic>>();
    final polling = c.poll();
    await Future<void>.value();
    await c.cancel(running);
    b.pendingStatus!.complete({
      ...b.tasks[running.taskId]!,
      'state': 'running',
    });
    await polling;
    expect(c.tasks.single.state, 'cancelled');
  });
}
