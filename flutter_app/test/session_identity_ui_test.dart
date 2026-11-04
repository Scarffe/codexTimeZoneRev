import 'package:codex_timezone/app/global_session_list.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_live.dart';
import 'package:codex_timezone/services/session_identity.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_account_ui_test.dart' show runtimeHost;
import 'support/global_workbench_fixture.dart';

void main() {
  test('live names are optional and never replace the routing ID', () {
    Map<String, dynamic> snapshot(Object? title) => {
      'liveVersion': 1,
      'coverage': 'partial',
      'connected': true,
      'items': [
        {
          'threadId': 'stable-id',
          'title': title,
          'state': 'running',
          'attention': 'none',
          'observedAtMs': 1,
          'sequence': 1,
        },
      ],
    };
    final named = GlobalLiveSnapshot.fromJson(snapshot('修复页面'));
    expect(named.items.single.title, '修复页面');
    expect(named.items.single.threadId, 'stable-id');
    final legacy = GlobalLiveSnapshot.fromJson(snapshot(null));
    expect(
      readableSessionName(title: legacy.items.single.title, english: true),
      'Untitled conversation',
    );
    expect(readableSessionName(project: r'C:\work\我的项目'), '未命名会话 · 我的项目');
  });
  testWidgets(
    'actual names distinguish sessions while actions retain identity',
    (tester) async {
      final a = globalSessionFixture(id: '11111111-aaaa-bbbb-cccc-000000000001')
        ..['title'] = '修复登录布局';
      final b = globalSessionFixture(id: '11111111-aaaa-bbbb-cccc-000000000002')
        ..['title'] = '修复登录布局';
      String? opened;
      await tester.pumpWidget(
        runtimeHost(
          GlobalSessionList(
            snapshot: GlobalSnapshot.fromJson(
              globalSnapshotFixture(sessions: [a, b]),
            ),
            busy: false,
            sort: 'recent',
            onSort: (_) {},
            onPrevious: null,
            onNext: null,
            onOpen: (row) => opened = row.threadId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('修复登录布局'), findsNWidgets(2));
      await tester.tap(find.byKey(ValueKey('global-open-${b['threadId']}')));
      await tester.pumpAndSettle();
      expect(opened, b['threadId']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing title uses readable fallback and keeps id in details', (
    tester,
  ) async {
    final row = globalSessionFixture(
      id: '11111111-aaaa-bbbb-cccc-000000000001',
      canOpenDetail: false,
    )..remove('title');
    await tester.pumpWidget(
      runtimeHost(
        GlobalSessionList(
          snapshot: GlobalSnapshot.fromJson(
            globalSnapshotFixture(sessions: [row]),
          ),
          busy: false,
          sort: 'recent',
          onSort: (_) {},
          onPrevious: null,
          onNext: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未命名会话'), findsWidgets);
    await tester.tap(find.byKey(ValueKey('global-open-${row['threadId']}')));
    await tester.pumpAndSettle();
    expect(find.textContaining(row['threadId'] as String), findsOneWidget);
  });

  testWidgets('long names and fifty rows keep the list bounded and navigable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final rows = List.generate(
      50,
      (index) =>
          globalSessionFixture(id: 'stable-session-$index')
            ..['title'] = '会话 $index：${'很长的可读名称' * 20}',
    );
    String? opened;
    var sort = 'recent';
    var offset = 0;
    late StateSetter refresh;
    await tester.pumpWidget(
      runtimeHost(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return SingleChildScrollView(
              key: const PageStorageKey('overview-scroll'),
              child: GlobalSessionList(
                snapshot: GlobalSnapshot.fromJson(
                  globalSnapshotFixture(sessions: rows, offset: offset),
                ),
                busy: false,
                sort: sort,
                onSort: (value) => setState(() => sort = value),
                onPrevious: null,
                onNext: () => setState(() => offset += 50),
                onOpen: (row) => opened = row.threadId,
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('global-session-rows-viewport')))
          .height,
      lessThanOrEqualTo(440),
    );
    final last = find.byKey(const ValueKey('global-open-stable-session-49'));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(opened, 'stable-session-49');
    final first = find.byKey(const ValueKey('global-open-stable-session-0'));
    expect(first.hitTestable(), findsNothing);
    refresh(() => rows.last['title'] = '改名后仍留在阅读位置');
    await tester.pumpAndSettle();
    expect(last.hitTestable(), findsOneWidget);
    expect(first.hitTestable(), findsNothing);
    await tester.tap(find.byKey(const ValueKey('global-sort')));
    await tester.pumpAndSettle();
    expect(first.hitTestable(), findsOneWidget);
    expect(last.hitTestable(), findsNothing);
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('global-next')));
    await tester.pumpAndSettle();
    expect(first.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
