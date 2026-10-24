import 'dart:io';

import 'package:codex_timezone/services/session_attention.dart';
import 'package:codex_timezone/services/session_attention_store.dart';
import 'package:flutter_test/flutter_test.dart';

SessionAttentionSnapshot snapshot(int n) => SessionAttentionSnapshot(
  watches: [
    const SessionAttentionWatch(
      key: 'watch',
      path: 'fixture',
      expectedSessionId: 'session',
      alias: 'Alias',
    ),
  ],
  notices: [
    for (var i = 0; i < n; i++)
      SessionAttentionNotice(
        watchKey: 'watch',
        path: 'fixture',
        sessionId: 'session',
        turnId: '$i',
        title: 'Alias',
        createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
        read: i.isEven,
      ),
  ],
);
void main() {
  late Directory dir;
  late File file;
  late SessionAttentionStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('attention-store-');
    file = File('${dir.path}/state.json');
    store = SessionAttentionStore(file);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test('atomic serialized writes preserve latest watches read state and prune max200', () async {
    final writes = [
      store.write(snapshot(1)),
      store.write(snapshot(230)),
      store.write(snapshot(240)),
    ];
    await Future.wait(writes);
    await store.flush();
    final value = (await store.read())!;
    expect(value.watches.single.alias, 'Alias');
    expect(value.notices, hasLength(200));
    expect(value.notices.first.turnId, '1');
    expect(value.notices.last.turnId, '239');
    expect(value.notices.first.read, false);
    expect(value.notices.first.id, snapshot(2).notices.last.id);
    expect(value.notices.map((notice) => notice.turnId), [
      for (var i = 0; i < 240; i++)
        if (i.isOdd || i >= 80) '$i',
    ]);
    expect(await File('${file.path}.tmp').exists(), false);
  });
  test('snapshot and persisted mixed notices remove oldest read and retain metadata', () async {
    final original = [
      for (var i = 0; i < 201; i++)
        SessionAttentionNotice(
          watchKey: 'watch-$i',
          path: 'fixture-$i',
          sessionId: 'session-$i',
          turnId: 'turn-$i',
          title: 'Title $i',
          createdAt: DateTime.utc(2026).add(Duration(seconds: i)),
          durationMs: i,
          read: i > 0 && i < 200,
        ),
    ];
    final expected = [original.first, ...original.skip(2)];
    final value = SessionAttentionSnapshot(watches: [], notices: original);
    expect(
      value.notices.map((n) => n.toJson()),
      expected.map((n) => n.toJson()),
    );
    final decoded = SessionAttentionSnapshot.fromJson({
      'version': 1,
      'watches': [],
      'notices': original.map((n) => n.toJson()).toList(),
    });
    expect(
      decoded.notices.map((n) => n.toJson()),
      expected.map((n) => n.toJson()),
    );
    await store.write(decoded);
    await store.flush();
    expect((await store.read())!.toJson(), value.toJson());
  });
  test('all unread overflow retains the latest 200 in original order', () {
    final notices = [
      for (var i = 0; i < 205; i++)
        SessionAttentionNotice(
          watchKey: 'w',
          path: 'p',
          sessionId: 's',
          turnId: '$i',
          title: 'Title',
          createdAt: DateTime.utc(2026),
        ),
    ];
    final value = SessionAttentionSnapshot(watches: [], notices: notices);
    expect(value.notices.map((n) => n.id), notices.skip(5).map((n) => n.id));
    expect(value.notices.every((n) => !n.read), true);
  });
  test('corrupt bytes are preserved before replacement and failure remains visible', () async {
    final bytes = [0, 255, 12, 30];
    await file.writeAsBytes(bytes);
    await expectLater(store.read(), throwsA(anything));
    await store.write(snapshot(1));
    final backups = await dir
        .list()
        .where((f) => f.path.contains('.invalid-'))
        .toList();
    expect(backups, hasLength(1));
    expect(await File(backups.single.path).readAsBytes(), bytes);
    expect((await store.read())!.notices, hasLength(1));
  });
  test('DTO rejects invalid notice identity and ignores payload bodies', () {
    final json = snapshot(1).toJson();
    (json['watches'] as List).first['prompt'] = 'PRIVATE';
    expect(
      SessionAttentionSnapshot.fromJson(json).toJson().toString(),
      isNot(contains('PRIVATE')),
    );
    (json['notices'] as List).first['id'] = 'forged';
    expect(
      () => SessionAttentionSnapshot.fromJson(json),
      throwsFormatException,
    );
  });
}
