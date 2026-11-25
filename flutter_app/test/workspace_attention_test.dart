import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/session_attention_page.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/monitoring_page.dart';
import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:forui/forui.dart';
import 'package:codex_timezone/services/memory_attention_store.dart';

import 'support/workspace_attention_fixture.dart';
import 'monitor_lifecycle_test.dart' show nativeAction;

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

class IdentityFeed implements LauncherBackend {
  Object? identity;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async => {
    'sourceInfo': identity,
    'current': {'status': 'running', 'turnId': 't'},
  };
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  testWidgets(
    'six mounted destinations default to launcher without eager reads',
    (tester) async {
      await tester.pumpWidget(const LauncherApplication(preview: true));
      await tester.pumpAndSettle();
      expect(find.text('保存并启动 Codex'), findsOneWidget);
      for (final name in [
        'launcher',
        'overview',
        'accounts',
        'sessions',
        'analysis',
        'benchmark',
      ]) {
        expect(find.byKey(ValueKey('workspace-$name')), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('workspace-$name')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'watch picker is explicit, adds original identity and disables a ninth watch',
    (tester) async {
      final backend = WorkspaceAttentionBackend();
      final attention = SessionAttentionController(backend);
      await attention.initialize(MemoryAttentionStore());
      await tester.pumpWidget(
        LauncherApplication(
          preview: true,
          backend: backend,
          attentionController: attention,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
      await tester.pumpAndSettle();
      expect(
        backend.calls.where((call) => call.startsWith('session_metrics')),
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('attention-refresh')));
      await tester.pumpAndSettle();
      expect(attention.watches, isEmpty);
      await tester.tap(find.byKey(const ValueKey('attention-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('合成 A · 图像处理 · synthetic-A').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('attention-alias')),
          matching: find.byType(EditableText),
        ),
        '明确别名',
      );
      await tester.tap(find.byKey(const ValueKey('attention-add')));
      await tester.pumpAndSettle();
      expect(attention.watches.single.path, workspacePathA);
      expect(attention.watches.single.expectedSessionId, 'synthetic-A');
      expect(attention.watches.single.alias, '明确别名');
      expect(attention.notices, isEmpty);
      for (var i = 1; i < 8; i++) {
        await attention.watch('synthetic-$i', expectedId: 'id-$i');
      }
      await tester.pump();
      expect(
        tester
            .widget<FButton>(find.byKey(const ValueKey('attention-add')))
            .onPress,
        isNull,
      );
      expect(attention.watches.length, 8);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'inbox opens immutable source after unwatch; five charts and other sources stay independent',
    (tester) async {
      final f = await WorkspaceAttentionFixture.create();
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: f.backend,
          sourceController: f.sources,
          sessionMetricsController: f.metrics,
          attentionController: f.attention,
          benchmarkController: f.benchmark,
        ),
      );
      await tester.pumpAndSettle();
      expect(f.attention.notices, isEmpty);
      f.sources.select('profile-unknown');
      final originalAccount = f.sources.selectedId;
      final launcher = tester
          .widget<LauncherPage>(find.byType(LauncherPage))
          .launcher;
      launcher.update(
        launcher.settings.copyWith(executable: 'synthetic draft'),
      );
      await tester.pump();
      final reads = f.backend.calls.length;
      final quotaReads = f.sourceService.queries.length;
      for (var i = 0; i < 2; i++) {
        for (final page in [
          'overview',
          'accounts',
          'sessions',
          'analysis',
          'benchmark',
          'launcher',
        ]) {
          await tester.tap(find.byKey(ValueKey('workspace-$page')));
          await tester.pump();
        }
      }
      expect(f.backend.calls.length, reads);
      expect(f.sourceService.queries.length, quotaReads);
      expect(launcher.settings.executable, 'synthetic draft');
      expect(
        TickerMode.valuesOf(
          tester.element(find.byType(SessionMetricsPanel, skipOffstage: false)),
        ).enabled,
        isFalse,
      );
      await f.completeA();
      await tester.pump();
      expect(find.text('保存并启动 Codex'), findsOneWidget);
      final notice = f.attention.notices.single;
      await f.attention.unwatch(notice.watchKey);
      await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('notice-open-${notice.id}')),
      );
      await tester.tap(find.byKey(ValueKey('notice-open-${notice.id}')));
      await tester.pumpAndSettle();
      expect(f.metrics.selected, workspacePathA);
      expect(f.metrics.sourceInfo?['id'], 'synthetic-A');
      expect(find.textContaining('原回合 a-current'), findsOneWidget);
      expect(find.textContaining('原提醒回合的完整样本不可用或已更新'), findsOneWidget);
      for (final key in [
        'account-quota-chart',
        'session-recent-chart',
        'session-configuration-chart',
        'session-activity-chart',
        'session-response-chart',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(f.sources.selectedId, originalAccount);
      expect(f.sourceService.queries.length, quotaReads);
      expect(f.benchmark.snapshot, isNull);
      f.backend.values[workspacePathA]!['sourceInfo'] = {'id': 'replacement'};
      await f.metrics.poll();
      await tester.pump();
      expect(f.metrics.data, isNull);
      expect(f.metrics.error, isNotNull);
      expect(find.textContaining('不会替换为其他会话'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'global overview stays separate from account selection and manual watch status',
    (tester) async {
      final f = await WorkspaceAttentionFixture.create();
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: f.backend,
          sourceController: f.sources,
          sessionMetricsController: f.metrics,
          attentionController: f.attention,
          benchmarkController: f.benchmark,
        ),
      );
      await tester.pumpAndSettle();
      final queries = f.sourceService.queries.length;
      await tester.tap(find.byKey(const ValueKey('workspace-overview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('global-workbench')), findsOneWidget);
      final selectedLog = f.metrics.selected;
      expect(find.textContaining('72.00%'), findsNothing);
      f.sources.select('profile-unknown');
      await tester.pump();
      expect(find.byKey(const ValueKey('global-stat-active')), findsOneWidget);
      f.sources.select('profile-stale');
      await tester.pump();
      await f.unreadableB();
      await tester.pump();
      expect(find.byKey(const ValueKey('global-session-list')), findsOneWidget);
      expect(f.metrics.selected, selectedLog);
      expect(f.sourceService.queries.length, queries);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'offline mode rejects native controller injections and defaults to denied memory owners',
    (tester) async {
      final nativeMetrics = SessionMetricsController(const NativeBackend());
      final nativeAttention = SessionAttentionController(const NativeBackend());
      await tester.pumpWidget(
        LauncherApplication(
          preview: true,
          offlineTrial: true,
          sessionMetricsController: nativeMetrics,
          attentionController: nativeAttention,
        ),
      );
      await tester.pumpAndSettle();
      final actualMetrics = tester
          .widget<SessionMetricsPanel>(
            find.byType(SessionMetricsPanel, skipOffstage: false),
          )
          .controller;
      final actualAttention = tester
          .widget<SessionAttentionPage>(
            find.byType(SessionAttentionPage, skipOffstage: false),
          )
          .controller;
      expect(actualMetrics, isNot(same(nativeMetrics)));
      expect(actualAttention, isNot(same(nativeAttention)));
      expect(actualMetrics.backend, isA<OfflineTrialBackend>());
      expect(actualAttention.backend, isA<OfflineTrialBackend>());
      await actualMetrics.list();
      await actualAttention.refreshSessions();
      expect(actualMetrics.sessions, isEmpty);
      expect(actualAttention.availableSessions, isEmpty);
      expect(
        actualMetrics.listError,
        contains('offline_trial_operation_disabled'),
      );
      await tester.pumpWidget(const SizedBox());
      nativeMetrics.dispose();
      nativeAttention.dispose();
    },
  );
  testWidgets(
    'inbox filters preserve notices on pause/remove and explicit mark read',
    (tester) async {
      final f = await WorkspaceAttentionFixture.create();
      await tester.pumpWidget(
        LauncherApplication(
          preview: true,
          backend: f.backend,
          attentionController: f.attention,
          sessionMetricsController: f.metrics,
          sourceController: f.sources,
          benchmarkController: f.benchmark,
        ),
      );
      await tester.pumpAndSettle();
      await f.completeA();
      await f.unreadableB();
      await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
      await tester.pumpAndSettle();
      final notice = f.attention.notices.single;
      await tester.ensureVisible(
        find.byKey(ValueKey('notice-read-${notice.id}')),
      );
      await tester.tap(find.byKey(ValueKey('notice-read-${notice.id}')));
      await tester.pumpAndSettle();
      expect(f.attention.unreadCount, 0);
      expect(find.text('暂无未读提醒。'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('attention-filter-active')),
      );
      await tester.tap(find.byKey(const ValueKey('attention-filter-active')));
      await tester.pumpAndSettle();
      expect(find.textContaining('读取失败 · 当前状态未知'), findsOneWidget);
      final a = f.attention.watches.first;
      await tester.ensureVisible(find.byKey(ValueKey('watch-toggle-${a.key}')));
      await tester.tap(find.byKey(ValueKey('watch-toggle-${a.key}')));
      await tester.pumpAndSettle();
      expect(f.attention.hasWatchedPath(workspacePathA), false);
      await tester.ensureVisible(
        find.byKey(const ValueKey('attention-filter-all')),
      );
      await tester.tap(find.byKey(const ValueKey('attention-filter-all')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ValueKey('watch-remove-${a.key}')));
      await tester.tap(find.byKey(ValueKey('watch-remove-${a.key}')));
      await tester.pumpAndSettle();
      expect(f.attention.watches.length, 1);
      expect(f.attention.notices.single.id, notice.id);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'new OS click opens inbox and old session click keeps current analysis fallback',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DesktopMonitor.channel,
        (call) async => call.method == 'mainVisible' ? true : null,
      );
      final f = await WorkspaceAttentionFixture.create();
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          monitorEnabled: true,
          backend: f.backend,
          sourceController: f.sources,
          sessionMetricsController: f.metrics,
          attentionController: f.attention,
          benchmarkController: f.benchmark,
        ),
      );
      await tester.pumpAndSettle();
      await nativeAction('attentionDetails');
      await tester.pumpAndSettle();
      expect(find.byType(SessionAttentionPage), findsOneWidget);
      expect(f.metrics.selected, workspacePathB);
      await nativeAction('sessionDetails');
      await tester.pumpAndSettle();
      expect(find.byType(MonitoringPage), findsOneWidget);
      expect(f.metrics.selected, workspacePathB);
      await nativeAction('monitorDetails');
      await tester.pumpAndSettle();
      expect(find.byType(AccountUsagePanel), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );
  for (final identity in [
    null,
    'invalid',
    <String, dynamic>{},
    {'id': ''},
    {'id': 'other'},
  ]) {
    test('notice selection rejects unverified identity $identity', () async {
      final feed = IdentityFeed()..identity = identity;
      final metrics = SessionMetricsController(feed);
      metrics.select('original-path', expectedId: 'original-id');
      await Future<void>.delayed(Duration.zero);
      expect(metrics.error, isNotNull);
      expect(metrics.data, isNull);
      expect(metrics.selected, 'original-path');
      metrics.dispose();
    });
  }
}
