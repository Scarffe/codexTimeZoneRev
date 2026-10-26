import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/account_sources_panel.dart';
import 'package:codex_timezone/app/accounts_workspace_page.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/quota_history_panel.dart';
import 'package:codex_timezone/app/quota_history_charts.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/app/workspace_overview_page.dart';
import 'package:codex_timezone/domain/settings.dart';
import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/launcher_controller.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
import 'support/quota_history_fixture.dart';

class _ForbiddenUsage implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) => throw StateError('Forbidden');
}

Widget _host(ValueNotifier<AppLanguage> language, Widget child) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (context, route) => FTheme(
    data: lightLauncherTheme,
    child: FToaster(
      child: FTooltipGroup(
        child: ValueListenableBuilder<AppLanguage>(
          valueListenable: language,
          builder: (context, value, _) => AppCopyScope(
            language: value,
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14),
              child: route!,
            ),
          ),
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) =>
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => child),
);

void main() {
  setUpAll(timezone.initializeTimeZones);

  testWidgets(
    'account locale redraw preserves aliases, expanded source and reads',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      final language = ValueNotifier(AppLanguage.zh);
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() {
        language.dispose();
        usage.dispose();
        launcher.dispose();
        f.owner.dispose();
        f.metrics.dispose();
      });
      await tester.pumpWidget(
        _host(
          language,
          AccountsWorkspacePage(usage: usage, launcher: launcher),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle-source-overview')));
      await tester.pumpAndSettle();
      final selected = f.owner.selectedId;
      final session = f.metrics.selected;
      final queries = f.service.queries.length;
      final alias = f.owner.selected!.alias;
      expect(find.text('剩余额度'), findsWidgets);
      language.value = AppLanguage.en;
      await tester.pumpAndSettle();
      expect(find.text('Quota sources'), findsOneWidget);
      expect(find.text('Remaining quota'), findsWidgets);
      expect(
        find.text('Network unavailable; previous observation retained.'),
        findsOneWidget,
      );
      expect(find.text(alias), findsWidgets);
      expect(find.byKey(ValueKey('source-overview-$selected')), findsOneWidget);
      expect(f.owner.selectedId, selected);
      expect(f.metrics.selected, session);
      expect(f.service.queries.length, queries);
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'quota labels and reset readout follow language without changing values',
    (tester) async {
      final language = ValueNotifier(AppLanguage.en);
      addTearDown(language.dispose);
      final now = DateTime.utc(2026, 10, 26, 12);
      final bucket = UsageBucket(
        label: 'Raw 中文 model',
        windows: [
          UsageWindow(
            durationMinutes: 300,
            usedPercent: 28,
            resetsAt: now.add(const Duration(hours: 2)),
          ),
          const UsageWindow(durationMinutes: 10080),
        ],
      );
      await tester.pumpWidget(
        _host(
          language,
          AccountQuotaPresentation(
            bucket: bucket,
            settings: const LauncherSettings(),
            useLocalTime: true,
            now: now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      var chart = tester.widget<MonitorRingChart>(
        find.byType(MonitorRingChart),
      );
      expect(chart.bars.map((b) => b.label), ['5-hour quota', 'Weekly quota']);
      expect(chart.bars.first.value, 72);
      expect(chart.bars.first.detail, contains('Resets in'));
      expect(chart.bars.last.detail, contains('Reset time unavailable'));
      language.value = AppLanguage.zh;
      await tester.pumpAndSettle();
      chart = tester.widget<MonitorRingChart>(find.byType(MonitorRingChart));
      expect(chart.bars.map((b) => b.label), ['5 小时额度', '周额度']);
      expect(chart.bars.first.value, 72);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history redraw preserves local filter and translates event and inspection',
    (tester) async {
      final f = await HistoryFixture.create(
        records: [historyRecord(1), historyRecord(2, failed: true)],
      );
      final language = ValueNotifier(AppLanguage.zh);
      addTearDown(f.dispose);
      addTearDown(language.dispose);
      await tester.pumpWidget(
        _host(
          language,
          SingleChildScrollView(
            child: QuotaHistoryPanel(controller: f.controller, owner: f.owner),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<MonitorChoice>(find.byKey(const ValueKey('history-range')))
          .onChanged('1');
      await tester.pumpAndSettle();
      final filter = f.controller.filter;
      tester
          .widget<FButton>(find.byKey(const ValueKey('history-event-0')))
          .onPress!();
      await tester.pumpAndSettle();
      final highlighted = tester
          .widget<QuotaHistoryTrendChart>(find.byType(QuotaHistoryTrendChart))
          .highlightedInterval;
      final chart = find.byType(QuotaHistoryTrendChart);
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      final focus = find
          .descendant(of: chart, matching: find.byType(Focus))
          .first;
      Focus.of(
        tester.element(
          find
              .descendant(of: focus, matching: find.byType(LayoutBuilder))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.textContaining('已用 25.00%'), findsOneWidget);
      language.value = AppLanguage.en;
      await tester.pumpAndSettle();
      expect(identical(f.controller.filter, filter), isTrue);
      expect(find.text('Reload local history'), findsOneWidget);
      expect(find.textContaining('Query failed · network'), findsOneWidget);
      expect(find.textContaining('Hover or focus'), findsWidgets);
      expect(find.textContaining('Used 25.00%'), findsOneWidget);
      expect(
        tester
            .widget<QuotaHistoryTrendChart>(find.byType(QuotaHistoryTrendChart))
            .highlightedInterval,
        highlighted,
      );
      expect(
        tester
            .widget<MonitorChoice>(find.byKey(const ValueKey('history-range')))
            .items['24 hours'],
        '1',
      );
      expect(f.service.queries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'open source details redraw their heading and retain account identity',
    (tester) async {
      final f = await syntheticMultiFixture();
      f.metrics.select(null);
      final language = ValueNotifier(AppLanguage.zh);
      addTearDown(() {
        language.dispose();
        f.owner.dispose();
        f.metrics.dispose();
      });
      await tester.pumpWidget(
        _host(language, AccountSourcesPanel(owner: f.owner)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-details')));
      await tester.pumpAndSettle();
      final queries = f.service.queries.length;
      final identity = f.owner.selected!.usage!.email!;
      expect(find.text('来源详情'), findsOneWidget);
      expect(find.textContaining(identity), findsOneWidget);
      language.value = AppLanguage.en;
      await tester.pumpAndSettle();
      expect(find.text('Source details'), findsOneWidget);
      expect(find.text('Account: $identity'), findsOneWidget);
      expect(f.service.queries.length, queries);
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'overview translates empty and status summaries while keeping raw alias',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final attention = SessionAttentionController(f.backend);
      final language = ValueNotifier(AppLanguage.en);
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() {
        language.dispose();
        usage.dispose();
        attention.dispose();
        f.owner.dispose();
        f.metrics.dispose();
      });
      await tester.pumpWidget(
        _host(
          language,
          WorkspaceOverviewPage(
            usage: usage,
            metrics: f.metrics,
            attention: attention,
            onSelect: (_) {},
            recentNotice: '',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Offline replay'), findsOneWidget);
      expect(find.text('System alert history'), findsOneWidget);
      expect(
        find.text('Selected · ${f.owner.selected!.alias}'),
        findsOneWidget,
      );
      expect(
        find.text('Latest completed turn · Average throughput'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
