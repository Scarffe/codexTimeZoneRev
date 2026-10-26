import 'package:codex_timezone/services/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tasks_fixture.dart';

void main() {
  test(
    'approval advertised decision subset rejects an unavailable accept',
    () async {
      final backend = TasksBackend();
      final service = TaskService(backend);
      final prepared = await service.prepare(
        mode: 'offline_preview',
        sourceId: 'preview-a',
        workspace: 'synthetic-workspace-a',
        prompt: 'p',
        model: 'synthetic-model',
      );
      backend.tasks[prepared.taskId]!['approvals'] = [
        {
          'approvalId': 'decline-only',
          'kind': 'command',
          'summary': 'review restricted decisions',
          'command': null,
          'cwd': null,
          'files': <String>[],
          'decisions': ['decline', 'cancel'],
        },
      ];
      final snapshot = await service.status(prepared);
      final calls = backend.calls.length;
      await expectLater(
        service.approve(snapshot, 'decline-only', 'accept'),
        throwsA(isA<TaskFailure>()),
      );
      expect(backend.calls.length, calls);
      await service.approve(snapshot, 'decline-only', 'decline');
      expect(backend.payloads.last['decision'], 'decline');
    },
  );
  test(
    'approval decision subset is nonempty valid and unique when present',
    () {
      final approval = {
        'approvalId': 'subset',
        'kind': 'command',
        'summary': 'review',
        'command': null,
        'cwd': null,
        'files': <String>[],
      };
      for (final decisions in [
        <String>[],
        ['accept', 'accept'],
        ['acceptForSession'],
      ]) {
        expect(
          () => TaskApproval.fromJson({...approval, 'decisions': decisions}),
          throwsFormatException,
        );
      }
      expect(TaskApproval.fromJson(approval).decisions, [
        'accept',
        'decline',
        'cancel',
      ]);
      expect(
        TaskApproval.fromJson({
          ...approval,
          'decisions': ['cancel', 'decline'],
        }).decisions,
        ['cancel', 'decline'],
      );
    },
  );
  test(
    'preview restriction preserves strictly owned official cleanup only',
    () async {
      final backend = TasksBackend();
      final service = TaskService(backend);
      Future<TaskSnapshot> official(String source) => service.prepare(
        mode: 'official',
        sourceId: source,
        workspace: 'synthetic-$source',
        prompt: 'p',
        model: 'synthetic-model',
      );
      final first = await service.start(await official('profile-a'));
      final second = await service.start(await official('profile-b'));
      backend.tasks['not-owned'] = taskFixture(
        id: 'not-owned',
        mode: 'official',
        source: 'profile-other',
        state: 'running',
      );
      service.restrictToPreview();
      final observed = await service.status(first);
      expect(observed.state, 'running');
      final beforeDenied = backend.calls.length;
      await expectLater(official('profile-new'), throwsA(isA<TaskFailure>()));
      await expectLater(service.start(first), throwsA(isA<TaskFailure>()));
      final wrongEpoch = TaskSnapshot.fromJson({
        ...backend.tasks[first.taskId]!,
        'sourceEpoch': first.sourceEpoch + 1,
      });
      await expectLater(
        service.status(wrongEpoch),
        throwsA(isA<TaskFailure>()),
      );
      expect(backend.calls.length, beforeDenied);
      expect((await service.cancel(first)).state, 'cancelled');
      await service.clear(first);
      expect(await service.shutdown(), true);
      final cancellations = [
        for (var i = 0; i < backend.calls.length; i++)
          if (backend.calls[i] == 'task_cancel') backend.payloads[i]['taskId'],
      ];
      expect(cancellations, containsAll([first.taskId, second.taskId]));
      expect(cancellations, isNot(contains('not-owned')));
      expect(backend.tasks['not-owned']!['state'], 'running');
      expect(backend.calls, isNot(contains('task_shutdown')));
    },
  );
  test(
    'approval and structured answers retain opaque request routing',
    () async {
      final b = TasksBackend();
      final service = TaskService(b);
      final prepared = await service.prepare(
        mode: 'offline_preview',
        sourceId: 'preview-a',
        workspace: 'synthetic-workspace-a',
        prompt: 'p',
        model: 'synthetic-model',
      );
      b.tasks[prepared.taskId]!['approvals'] = [
        {
          'approvalId': 'opaque-int64',
          'kind': 'command',
          'summary': 'review',
          'command': null,
          'cwd': null,
          'files': <String>[],
        },
      ];
      var snapshot = await service.status(prepared);
      await service.approve(snapshot, 'opaque-int64', 'decline');
      expect(b.payloads.last, {
        ...prepared.identity,
        'approvalId': 'opaque-int64',
        'decision': 'decline',
      });
      b.tasks[prepared.taskId]!['inputRequests'] = [
        {
          'requestId': 'opaque-input',
          'questions': [
            {
              'id': 'q',
              'header': 'h',
              'question': 'q',
              'isOther': true,
              'isSecret': true,
              'options': <dynamic>[],
            },
          ],
        },
      ];
      snapshot = await service.status(prepared);
      await service.answer(snapshot, 'opaque-input', {
        'q': ['private answer'],
      });
      expect(b.payloads.last, {
        ...prepared.identity,
        'requestId': 'opaque-input',
        'answers': {
          'q': {
            'answers': ['private answer'],
          },
        },
      });
      await expectLater(
        service.start(TaskSnapshot.fromMetadata(prepared.toMetadata())),
        throwsA(isA<TaskFailure>()),
      );
    },
  );
  test(
    'prepare does not start; start uses backend identity and immutable content',
    () async {
      final backend = TasksBackend();
      final service = TaskService(backend);
      final snapshot = await service.prepare(
        mode: 'offline_preview',
        sourceId: 'preview-a',
        workspace: 'synthetic',
        prompt: 'private prompt',
        model: 'raw-model',
        sandbox: 'read-only',
      );
      expect(backend.calls, ['task_prepare']);
      expect(snapshot.sourceEpoch, 41);
      await service.start(snapshot);
      expect(backend.payloads.last, {
        'taskId': snapshot.taskId,
        'sourceEpoch': 41,
        'generation': 1,
      });
    },
  );
  test(
    'preview restriction blocks official calls before touching backend',
    () async {
      final backend = TasksBackend();
      final service = TaskService(backend, officialEnabled: false);
      await expectLater(
        service.prepare(
          mode: 'official',
          sourceId: 'profile-a',
          workspace: 'x',
          prompt: 'x',
          model: 'x',
          sandbox: 'read-only',
        ),
        throwsA(isA<TaskFailure>()),
      );
      expect(backend.calls, isEmpty);
    },
  );
  test(
    'nested approval/input/usage and finite errors parse without raw fallback',
    () {
      final raw = taskFixture();
      raw['errorKind'] = 'secret arbitrary upstream';
      raw['approvals'] = [
        {
          'approvalId': 'opaque-1',
          'kind': 'command',
          'summary': 'Review command',
          'command': 'echo x',
          'cwd': null,
          'files': <String>[],
        },
      ];
      raw['inputRequests'] = [
        {
          'requestId': 'opaque-2',
          'questions': [
            {
              'id': 'q',
              'header': 'Header',
              'question': 'Question',
              'isOther': true,
              'isSecret': true,
              'options': [
                {'label': 'a', 'description': 'A'},
              ],
            },
          ],
        },
      ];
      raw['usage'] = {
        'scope': 'thread_total',
        'inputTokens': 10,
        'outputTokens': 20,
        'reasoningTokens': null,
      };
      final snapshot = TaskSnapshot.fromJson(raw);
      expect(snapshot.errorKind, 'unknown');
      expect(snapshot.approvals.single.approvalId, 'opaque-1');
      expect(snapshot.inputRequests.single.questions.single.isSecret, true);
      expect(snapshot.usage?.outputTokens, 20);
      expect(
        () => TaskSnapshot.fromJson({...raw, 'sourceEpoch': 0}),
        throwsFormatException,
      );
    },
  );
}
