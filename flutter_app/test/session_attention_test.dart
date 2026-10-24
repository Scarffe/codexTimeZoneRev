import 'dart:async';
import 'dart:io';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/session_attention.dart';
import 'package:codex_timezone/services/session_attention_store.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> observation(
  String session,
  String turn,
  String status, {
  int epoch = 1,
  bool catching = false,
  List<String> old = const [],
}) => {
  'sourceInfo': {'id': session, 'title': 'Metadata title', 'body': 'PRIVATE'},
  'logEpoch': epoch,
  'catchingUp': catching,
  'current': {'turnId': turn, 'status': status},
  'terminals': [
    if (status != 'running')
      {'turnId': turn, 'status': status, 'durationMs': 2000},
    for (final id in old) {'turnId': id, 'status': 'completed'},
  ],
  'last': {'body': 'PRIVATE'},
};

class AttentionFeed implements LauncherBackend {
  final values = <String, Map<String, dynamic>>{};
  final failures = <String>{};
  Completer<Map<String, dynamic>>? pending;
  int active = 0, maxActive = 0;
  final polledPaths = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    expect(command, 'session_metrics');
    if (payload['action'] == 'list') {
      return {
        'sessions': [
          for (final path in values.keys)
            {
              'path': path,
              'id': path,
              'title': 'Title $path',
              'prompt': 'PRIVATE',
            },
        ],
      };
    }
    final path = payload['path'] as String;
    polledPaths.add(path);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (failures.contains(path)) {
        throw const FileSystemException('missing fixture');
      }
      if (pending case final p?) {
        pending = null;
        return await p.future;
      }
      return values[path]!;
    } finally {
      active--;
    }
  }
}

class MemoryAttentionStore extends SessionAttentionStore {
  MemoryAttentionStore() : super(File('unused-attention-fixture'));
  SessionAttentionSnapshot? value;
  bool fail = false;
  Completer<SessionAttentionSnapshot?>? readGate;
  Completer<void>? writeGate;
  @override
  Future<SessionAttentionSnapshot?> read() async =>
      readGate == null ? value : readGate!.future;
  @override
  Future<void> write(SessionAttentionSnapshot snapshot) async {
    await writeGate?.future;
    if (fail) throw const FileSystemException('save fixture');
    value = SessionAttentionSnapshot.fromJson(snapshot.toJson());
  }
}

void main() {
  late AttentionFeed feed;
  late MemoryAttentionStore store;
  late SessionAttentionController controller;
  Future<void> setup([List<String> paths = const ['a']]) async {
    feed = AttentionFeed();
    for (final path in paths) {
      feed.values[path] = observation(path, 'old', 'completed');
    }
    store = MemoryAttentionStore();
    controller = SessionAttentionController(feed)
      ..configureReminders(enabled: true);
    addTearDown(controller.dispose);
    await controller.initialize(store);
    await controller.refreshSessions();
    for (final path in paths) {
      await controller.watch(path);
    }
  }

  test('two explicit watches baseline silently and save before one alert per current completion', () async {
    await setup(['a', 'b']);
    await controller.poll();
    expect(controller.notices, isEmpty);
    feed.values['a'] = observation('a', 'live', 'running');
    feed.values['b'] = observation('b', 'live', 'running');
    await controller.poll();
    feed.values['a'] = observation('a', 'live', 'completed');
    feed.values['b'] = observation('b', 'live', 'completed');
    await controller.poll();
    expect(controller.alertSerial, 2);
    expect(controller.unreadCount, 2);
    expect(store.value!.notices, hasLength(2));
    expect(feed.maxActive, 1);
    expect(store.value!.toJson().toString(), isNot(contains('PRIVATE')));
    await controller.poll();
    expect(controller.alertSerial, 2);
  });
  test('late completion of older turn never produces notice', () async {
    await setup();
    await controller.poll();
    feed.values['a'] = observation('a', 'new', 'running', old: ['late']);
    await controller.poll();
    expect(controller.notices, isEmpty);
  });
  for (final cause in [
    'cancelled',
    'catchup',
    'failure',
    'identity',
    'empty-id',
    'absent-id',
    'unknown',
    'epoch',
  ]) {
    test(
      '$cause suppresses notification and recovery baselines silently',
      () async {
        await setup();
        await controller.poll();
        feed.values['a'] = observation('a', 'live', 'running');
        await controller.poll();
        if (cause == 'failure') {
          feed.failures.add('a');
        }
        feed.values['a'] = observation(
          cause == 'identity'
              ? 'other'
              : cause == 'empty-id'
              ? ''
              : 'a',
          'live',
          cause == 'cancelled'
              ? 'cancelled'
              : cause == 'unknown'
              ? 'failed'
              : 'completed',
          catching: cause == 'catchup',
          epoch: cause == 'epoch' ? 2 : 1,
        );
        if (cause == 'absent-id') feed.values['a']!.remove('sourceInfo');
        await controller.poll();
        expect(controller.alertSerial, 0);
        if ([
          'failure',
          'identity',
          'empty-id',
          'absent-id',
          'unknown',
        ].contains(cause)) {
          expect(
            controller.items.single.status,
            SessionAttentionStatus.unknown,
          );
        }
        feed.failures.clear();
        feed.values['a'] = observation(
          'a',
          'live',
          'completed',
          epoch: cause == 'epoch' ? 2 : 1,
        );
        await controller.poll();
        expect(controller.alertSerial, 0);
      },
    );
  }
  test(
    'restored unread state has stable IDs and never replays an alert',
    () async {
      await setup();
      await controller.poll();
      feed.values['a'] = observation('a', 'live', 'completed');
      await controller.poll();
      final id = controller.notices.single.id;
      await controller.shutdown();
      final restored = SessionAttentionController(feed)
        ..configureReminders(enabled: true);
      addTearDown(restored.dispose);
      await restored.initialize(store);
      await restored.poll();
      expect(restored.unreadCount, 1);
      expect(restored.alertSerial, 0);
      expect(restored.notices.single.id, id);
      await restored.markRead(id);
      expect(store.value!.notices.single.read, true);
      feed.values['a'] = observation('a', 'live', 'completed', epoch: 100);
      await restored.poll();
      await restored.poll();
      expect(restored.notices, hasLength(1));
      expect(restored.alertSerial, 0);
    },
  );
  for (final action in ['pause', 'remove']) {
    test(
      '$action invalidates late read and same-path rewatch generation',
      () async {
        await setup();
        await controller.poll();
        final pending = Completer<Map<String, dynamic>>();
        feed.pending = pending;
        final poll = controller.poll();
        final key = controller.watches.single.key;
        if (action == 'pause') {
          await controller.setEnabled(key, false);
        } else {
          await controller.unwatch(key);
          await controller.watch('a');
        }
        pending.complete(observation('a', 'live', 'completed'));
        await poll;
        expect(controller.notices, isEmpty);
        expect(controller.alertSerial, 0);
        expect(controller.items.singleOrNull?.observedAt, isNull);
      },
    );
  }
  test(
    'save failure produces no OS alert; shutdown waits for poll and saves',
    () async {
      await setup();
      await controller.poll();
      store.fail = true;
      feed.values['a'] = observation('a', 'live', 'completed');
      await controller.poll();
      expect(controller.alertSerial, 0);
      expect(controller.error, isNotNull);
      store.fail = false;
      await controller.shutdown();
      expect(store.value!.notices, hasLength(1));
    },
  );
  test('failed final save rejects shutdown and explicit second exit retries while closed', () async {
    await setup();
    await controller.poll();
    feed.values['a'] = observation('a', 'live', 'completed');
    await controller.poll();
    final notice = controller.notices.single;
    store.fail = true;
    await controller.markRead(notice.id);
    expect(store.value!.notices.single.read, false);
    await expectLater(controller.shutdown(), throwsStateError);
    expect(controller.error, isNotNull);
    store.fail = false;
    final retry = controller.shutdown();
    await retry;
    expect(store.value!.notices.single.read, true);
    expect(controller.error, isNull);
    expect(identical(controller.shutdown(), retry), true);
    final reads = feed.polledPaths.length;
    feed.values['a'] = observation('a', 'later', 'completed');
    await controller.poll();
    expect(feed.polledPaths, hasLength(reads));
    expect(controller.notices, hasLength(1));
  });
  test(
    'max8, canonical same path reuse, immutable views and pause ownership',
    () async {
      await setup([]);
      for (var i = 0; i < 8; i++) {
        await controller.watch('C:/s/$i', expectedId: '$i');
      }
      await controller.watch(r'\\?\C:\s\0', expectedId: '0', alias: 'Alias');
      expect(controller.watches, hasLength(8));
      expect(() => controller.watches.clear(), throwsUnsupportedError);
      await expectLater(
        controller.watch('ninth', expectedId: '9'),
        throwsStateError,
      );
      await expectLater(
        controller.watch('empty', expectedId: ''),
        throwsArgumentError,
      );
      expect(controller.hasWatchedPath(r'C:\s\0'), true);
      await controller.setEnabled(controller.watches.first.key, false);
      expect(controller.hasWatchedPath('C:/s/0'), false);
    },
  );
  test('muted reminders keep inbox and do not emit after unmute', () async {
    await setup();
    await controller.poll();
    controller.configureReminders(
      enabled: true,
      muteUntil: DateTime.now().add(const Duration(hours: 1)),
    );
    await controller.poll();
    feed.values['a'] = observation('a', 'live', 'completed');
    await controller.poll();
    expect(controller.notices, hasLength(1));
    expect(controller.alertSerial, 0);
    controller.configureReminders(enabled: true);
    await controller.poll();
    expect(controller.alertSerial, 0);
    await controller.markAllRead();
    expect(controller.unreadCount, 0);
  });
  test(
    'explicit suspend reset invalidates inflight read and rebaselines silently',
    () async {
      await setup();
      await controller.poll();
      final pending = Completer<Map<String, dynamic>>();
      feed.pending = pending;
      final poll = controller.poll();
      await Future<void>.delayed(Duration.zero);
      controller.resetObservation();
      pending.complete(observation('a', 'live', 'completed'));
      await poll;
      expect(controller.notices, isEmpty);
      feed.values['a'] = observation('a', 'live', 'completed');
      await controller.poll();
      expect(controller.notices, isEmpty);
      expect(controller.watches, hasLength(1));
    },
  );
  test(
    'quit during restoration waits without overwriting saved references',
    () async {
      await setup();
      final saved = store.value!;
      await controller.shutdown();
      final gated = MemoryAttentionStore()
        ..readGate = Completer<SessionAttentionSnapshot?>();
      final restoring = SessionAttentionController(feed);
      addTearDown(restoring.dispose);
      final init = restoring.initialize(gated);
      var closed = false;
      final shutdown = restoring.shutdown().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      gated.readGate!.complete(saved);
      await init;
      await shutdown;
      expect(gated.value!.watches.single.path, 'a');
    },
  );
  test('startup watch waits for restored eight-watch cap without replacing saved state', () async {
    await setup([]);
    final saved = SessionAttentionSnapshot(
      watches: [
        for (var i = 0; i < 8; i++)
          SessionAttentionWatch(
            key: 'saved-$i',
            path: 'saved-$i',
            expectedSessionId: 'saved-$i',
          ),
      ],
      notices: [],
    );
    final gated = MemoryAttentionStore()
      ..value = saved
      ..readGate = Completer<SessionAttentionSnapshot?>();
    final restoring = SessionAttentionController(feed);
    addTearDown(restoring.dispose);
    final init = restoring.initialize(gated);
    var finished = false;
    final watch = restoring
        .watch('new', expectedId: 'new')
        .then<Object?>(
          (_) {
            finished = true;
            return null;
          },
          onError: (Object error) {
            finished = true;
            return error;
          },
        );
    await Future<void>.delayed(Duration.zero);
    final finishedBeforeRestore = finished;
    final beforeRestore = gated.value!.toJson();
    gated.readGate!.complete(saved);
    await init;
    final failure = await watch;
    expect(finishedBeforeRestore, false);
    expect(beforeRestore, saved.toJson());
    expect(failure, isStateError);
    expect(restoring.watches, hasLength(8));
    expect(gated.value!.toJson(), saved.toJson());
  });
  test('startup mutations apply after restoration in order and poll restored surviving watches', () async {
    await setup([]);
    final notice = SessionAttentionNotice(
      watchKey: 'keep',
      path: 'keep',
      sessionId: 'keep',
      turnId: 'old',
      title: 'Saved',
      createdAt: DateTime.utc(2026),
    );
    final saved = SessionAttentionSnapshot(
      watches: [
        const SessionAttentionWatch(
          key: 'keep',
          path: 'keep',
          expectedSessionId: 'keep',
        ),
        const SessionAttentionWatch(
          key: 'remove',
          path: 'remove',
          expectedSessionId: 'remove',
        ),
      ],
      notices: [notice],
    );
    final gated = MemoryAttentionStore()
      ..value = saved
      ..readGate = Completer<SessionAttentionSnapshot?>();
    final restoring = SessionAttentionController(feed);
    addTearDown(restoring.dispose);
    feed.values['new'] = observation('new', 'old', 'completed');
    feed.values['keep'] = observation('keep', 'old', 'completed');
    final init = restoring.initialize(gated);
    final watch = restoring.watch('new', expectedId: 'new');
    final remove = restoring.unwatch('remove');
    final pause = restoring.setEnabled('keep', false);
    final read = restoring.markRead(notice.id);
    var polled = false;
    final poll = restoring.poll().then((_) {
      polled = true;
    });
    await Future<void>.delayed(Duration.zero);
    final beforeRestore = gated.value!.toJson();
    final polledBeforeRestore = polled;
    gated.readGate!.complete(saved);
    await init;
    await Future.wait([watch, remove, pause, read, poll]);
    expect(beforeRestore, saved.toJson());
    expect(polledBeforeRestore, false);
    expect(restoring.watches.map((w) => w.path), ['keep', 'new']);
    expect(restoring.watches.first.enabled, false);
    expect(restoring.notices.single.read, true);
    expect(gated.value!.watches.map((w) => w.path), ['keep', 'new']);
    expect(gated.value!.notices.single.read, true);
    expect(feed.polledPaths, ['new']);
    expect(restoring.alertSerial, 0);
  });
  test(
    'startup markAllRead preserves restored notices and their references',
    () async {
      await setup([]);
      final saved = SessionAttentionSnapshot(
        watches: [],
        notices: [
          for (var i = 0; i < 2; i++)
            SessionAttentionNotice(
              watchKey: 'saved',
              path: 'saved',
              sessionId: 'saved',
              turnId: '$i',
              title: 'Saved',
              createdAt: DateTime.utc(2026),
            ),
        ],
      );
      final gated = MemoryAttentionStore()
        ..value = saved
        ..readGate = Completer<SessionAttentionSnapshot?>();
      final restoring = SessionAttentionController(feed);
      addTearDown(restoring.dispose);
      final init = restoring.initialize(gated), read = restoring.markAllRead();
      await Future<void>.delayed(Duration.zero);
      final beforeRestore = gated.value!.toJson();
      gated.readGate!.complete(saved);
      await init;
      await read;
      expect(beforeRestore, saved.toJson());
      expect(restoring.unreadCount, 0);
      expect(gated.value!.notices, hasLength(2));
      expect(
        gated.value!.notices.every((n) => n.read && n.path == 'saved'),
        true,
      );
    },
  );
  test('public watch mutations and poll reject use before initialization explicitly', () async {
    feed = AttentionFeed();
    final uninitialized = SessionAttentionController(feed);
    addTearDown(uninitialized.dispose);
    for (final operation in <Future<void> Function()>[
      () => uninitialized.watch('new', expectedId: 'new'),
      () => uninitialized.unwatch('new'),
      () => uninitialized.setEnabled('new', false),
      () => uninitialized.markRead('notice'),
      () => uninitialized.markAllRead(),
      () => uninitialized.poll(),
    ]) {
      await expectLater(operation(), throwsStateError);
    }
  });
  test('post-start pause and remove still invalidate synchronously', () async {
    await setup(['a', 'b']);
    final pause = controller.setEnabled(controller.watches.first.key, false);
    expect(controller.hasWatchedPath('a'), false);
    final remove = controller.unwatch(controller.watches.last.key);
    expect(controller.watches.map((w) => w.path), ['a']);
    await pause;
    await remove;
  });
  test(
    'terminal arriving late for an already completed baseline stays silent',
    () async {
      await setup();
      feed.values['a']!['terminals'] = [];
      await controller.poll();
      feed.values['a'] = observation('a', 'old', 'completed');
      await controller.poll();
      expect(controller.notices, isEmpty);
    },
  );
  test('new alert waits for durable save and remove while saving suppresses OS event', () async {
    await setup();
    await controller.poll();
    store.writeGate = Completer<void>();
    feed.values['a'] = observation('a', 'live', 'completed');
    final poll = controller.poll();
    await Future<void>.delayed(Duration.zero);
    expect(controller.alertSerial, 0);
    expect(store.value!.notices, isEmpty);
    final remove = controller.unwatch(controller.watches.single.key);
    store.writeGate!.complete();
    await poll;
    await remove;
    expect(controller.alertSerial, 0);
    expect(store.value!.watches, isEmpty);
    expect(store.value!.notices, hasLength(1));
  });
  test('concurrent polls coalesce and quit waits for an inflight read without alerting', () async {
    await setup();
    await controller.poll();
    final pending = Completer<Map<String, dynamic>>();
    feed.pending = pending;
    final first = controller.poll(), second = controller.poll();
    expect(identical(first, second), true);
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final shutdown = controller.shutdown().then((_) {
      closed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(closed, false);
    pending.complete(observation('a', 'live', 'completed'));
    await first;
    await shutdown;
    expect(controller.alertSerial, 0);
    expect(controller.notices, isEmpty);
  });
  test(
    'unwatch retains exact original notice reference and opaque bounded ID',
    () async {
      await setup();
      await controller.poll();
      feed.values['a'] = observation('a', 'live', 'completed');
      await controller.poll();
      await controller.unwatch(controller.watches.single.key);
      final notice = store.value!.notices.single;
      expect(notice.path, 'a');
      expect(notice.sessionId, 'a');
      expect(notice.turnId, 'live');
      expect(notice.id, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(controller.watches, isEmpty);
    },
  );
}
