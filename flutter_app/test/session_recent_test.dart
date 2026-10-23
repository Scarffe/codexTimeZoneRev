import 'package:flutter/widgets.dart';

import 'session_metrics_test.dart' show panelApp;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/session_selection.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';

class RecentFeed implements LauncherBackend {
  String id = 'a';
  bool missing = false, listFails = false;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (payload['action'] == 'list') {
      if (listFails) throw StateError('list unavailable');
      return {
        'sessions': [
          for (final name in ['a', 'b'])
            {
              'path': name,
              'id': name,
              'cwd': 'project-$name',
              'modifiedMs': 1000,
            },
        ],
      };
    }
    if (missing) throw const FileSystemException('missing');
    final path = payload['path'];
    return {
      'logEpoch': path == 'a' ? 1 : 2,
      'current': {'turnId': '$path-old', 'status': 'completed'},
      'terminals': [
        {'turnId': '$path-old', 'status': 'completed'},
      ],
      'sourceInfo': {
        'id': id == 'replacement' ? id : path,
        'cwd': 'project-$path',
        'path': path,
      },
    };
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);
void main() {
  testWidgets(
    'source panel names selected project and clears it on read failure',
    (tester) async {
      final feed = RecentFeed();
      final c = SessionMetricsController(feed)..select('a');
      await tester.pumpWidget(panelApp(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-source-details')));
      await tester.pumpAndSettle();
      expect(find.text('来源项目：project-a'), findsOneWidget);
      expect(find.textContaining('最近成功读取：'), findsOneWidget);
      feed.missing = true;
      await c.poll();
      await tester.pump();
      expect(find.textContaining('会话状态：状态未知'), findsOneWidget);
      expect(find.text('来源项目：project-a'), findsNothing);
      expect(find.text('来源项目：未知（尚未成功读取）'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  test(
    'restart restores selection silently and switching history stays silent',
    () async {
      final dir = await Directory.systemTemp.createTemp('i31');
      final store = SessionSelectionStore(File('${dir.path}/selection.json'));
      final feed = RecentFeed();
      final first = SessionMetricsController(feed)
        ..configureReminders(enabled: true);
      await first.initialize(store);
      first.select('a');
      await settle();
      await first.selectionSaved;
      expect(first.sourceInfo?['cwd'], 'project-a');
      expect(first.lastRead, isNotNull);
      expect(first.alertSerial, 0);
      first.dispose();
      final second = SessionMetricsController(feed)
        ..configureReminders(enabled: true);
      await second.initialize(store);
      await settle();
      expect(second.selected, 'a');
      expect(second.alertSerial, 0);
      second.select('b');
      await settle();
      expect(second.alertSerial, 0);
      await second.selectionSaved;
      second.select(null);
      await second.selectionSaved;
      second.dispose();
      final third = SessionMetricsController(feed);
      await third.initialize(store);
      expect(third.selected, isNull);
      await third.selectionSaved;
      third.dispose();
      await dir.delete(recursive: true);
    },
  );
  test('missing selected file remains unknown and list success cannot hide read failure', () async {
    final dir = await Directory.systemTemp.createTemp('i31');
    final store = SessionSelectionStore(File('${dir.path}/selection.json'));
    await store.write({'path': 'a', 'id': 'a'});
    final feed = RecentFeed()..missing = true;
    final c = SessionMetricsController(feed)..configureReminders(enabled: true);
    await c.initialize(store);
    await settle();
    expect(c.selected, 'a');
    expect(c.stateLabel, contains('未知'));
    expect(c.last, isNull);
    expect(c.alert, isEmpty);
    await c.list();
    expect(c.error, isNotNull);
    feed.missing = false;
    await c.poll();
    expect(c.alertSerial, 0);
    feed.id = 'replacement';
    await c.poll();
    expect(c.stateLabel, contains('未知'));
    expect(c.sourceInfo, isNull);
    expect(c.alertSerial, 0);
    await c.selectionSaved;
    c.dispose();
    await dir.delete(recursive: true);
  });
  test(
    'list error does not turn a selected running/failed state into completion',
    () async {
      final c = SessionMetricsController(RecentFeed()..listFails = true);
      await c.list();
      expect(c.listError, isNotNull);
      expect(c.selected, isNull);
      expect(c.sessionName({'id': 'fallback', 'path': 'x'}), '会话 fallback');
      c.dispose();
    },
  );
}
