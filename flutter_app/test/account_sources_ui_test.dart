import 'dart:async';

import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/monitor_presentation.dart';
import 'package:codex_timezone/app/accounts_workspace_page.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/launcher_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';

class _ForbiddenUsage implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) =>
      throw StateError('Legacy usage forbidden');
}

Widget sourcesHost(Widget child, {bool dark = false}) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (_, child) => FTheme(
    data: dark ? darkLauncherTheme : lightLauncherTheme,
    child: FToaster(
      child: FTooltipGroup(
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 14),
          child: child!,
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
    'source controls start collapsed and leave local session unchanged',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(
        _ForbiddenUsage(),
        sources: f.owner,
        offlineTrial: true,
      );
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      await launcher.initialize();
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-source-selector')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-overview-current')),
        findsNothing,
      );
      expect(find.textContaining('@example.test'), findsNothing);
      final originalSession = f.metrics.selected;
      final originalTurn = f.metrics.last?['turnId'];
      final originalRate = f.metrics.verifiedTokensPerSecond;
      final calls = f.service.queries.length;
      tester
          .widget<MonitorChoice>(
            find.byKey(const ValueKey('account-source-selector')),
          )
          .onChanged('profile-unknown');
      await tester.pumpAndSettle();
      expect(usage.data!.buckets.first.windows.first.usedPercent, isNull);
      expect(f.metrics.selected, originalSession);
      expect(f.metrics.last?['turnId'], originalTurn);
      expect(f.metrics.verifiedTokensPerSecond, originalRate);
      expect(f.service.queries.length, calls);
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same observed identity changes quota inspection ownership on source selection',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) => SingleChildScrollView(
              child: AccountUsagePanel(controller: usage, launcher: launcher),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = tester
          .widget<AccountQuotaPresentation>(
            find.byKey(const ValueKey('account-quota-chart')),
          )
          .inspectionIdentity;
      f.owner.select('profile-stale');
      await tester.pumpAndSettle();
      final next = tester
          .widget<AccountQuotaPresentation>(
            find.byKey(const ValueKey('account-quota-chart')),
          )
          .inspectionIdentity;
      expect(
        next,
        isNot(first),
        reason: 'Source ID and generation own chart inspection, even for equal identities',
      );
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline synthetic owner retains explicit quota refresh capability',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(
        _ForbiddenUsage(),
        sources: f.owner,
        offlineTrial: true,
      );
      final launcher = LauncherController(f.backend, offlineTrial: true);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      await tester.pumpWidget(
        sourcesHost(AccountUsagePanel(controller: usage, launcher: launcher)),
      );
      await tester.pumpAndSettle();
      final before = f.service.queries.length;
      await tester.tap(find.byKey(const ValueKey('query-account-usage')));
      await tester.pumpAndSettle();
      expect(f.service.queries.length, before + 1);
      expect(f.service.queries.last, 'current');
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'overview sorts unknown last and pinning does not change selection or query',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle-source-overview')));
      await tester.pumpAndSettle();
      final cards = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('source-overview-') &&
            w is! MonitorChoice,
      );
      expect(tester.widgetList(cards).map((w) => w.key), [
        const ValueKey('source-overview-profile-stale'),
        const ValueKey('source-overview-current'),
        const ValueKey('source-overview-profile-unknown'),
      ]);
      expect(find.textContaining('网络暂不可用'), findsOneWidget);
      expect(find.textContaining('数据已过期'), findsOneWidget);
      expect(find.textContaining('@example.test'), findsNothing);
      final before = f.service.queries.length;
      await tester.tap(find.byKey(const ValueKey('source-pin-profile-stale')));
      await tester.pumpAndSettle();
      expect(f.owner.pinnedId, 'profile-stale');
      expect(f.owner.selectedId, 'current');
      expect(f.service.queries.length, before);
      tester
          .widget<MonitorChoice>(
            find.byKey(const ValueKey('source-overview-sort')),
          )
          .onChanged('reset');
      await tester.pumpAndSettle();
      expect(
        tester.widgetList(cards).last.key,
        const ValueKey('source-overview-profile-unknown'),
      );
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'official add flow keeps progress and cancellation in app, retry refreshes once',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-account-source')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('source-alias-input')),
          matching: find.byType(EditableText),
        ),
        '实验来源',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('source-add-login')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('等待官方浏览器登录'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
      await tester.pumpAndSettle();
      final id = f.owner.states.last.id;
      expect(f.owner.states.last.loginState, 'cancelled');
      final before = f.service.queries.length;
      await tester.tap(find.byKey(const ValueKey('source-login-retry')));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(f.owner.states.last.loginState, 'succeeded');
      expect(f.service.queries.skip(before), [id]);
      await tester.tap(find.byKey(const ValueKey('source-login-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('source-rename-input')),
          matching: find.byType(EditableText),
        ),
        '确认后的来源',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('source-rename-save')));
      await tester.pumpAndSettle();
      expect(f.owner.states.last.alias, '确认后的来源');
      expect(f.service.queries.skip(before), [id]);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'successful source can explicitly relogin after quota authentication failure',
    (tester) async {
      final f = await syntheticMultiFixture();
      final id = 'profile-unknown';
      f.owner.select(id);
      await f.owner.login(id);
      for (var i = 0; i < 3; i++) {
        await f.owner.pollLogin(id);
      }
      expect(f.owner.selected!.loginState, 'succeeded');
      await f.owner.refresh(id);
      expect(f.owner.selected!.usage, isNotNull);
      f.service.queryFailureKinds[id] = 'auth_required';
      await f.owner.refresh(id);
      expect(f.owner.selected!.usage, isNull);
      expect(f.owner.selected!.errorKind, 'auth_required');
      expect(f.owner.selected!.loginState, 'succeeded');
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final generation = f.owner.selected!.generation;
      final queries = f.service.queries.length;
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-login')));
      await tester.pumpAndSettle();
      expect(
        f.owner.selected!.generation,
        generation,
        reason: 'Opening the editor must not begin another login',
      );
      expect(
        f.service.queries.length,
        queries,
        reason: 'Opening the editor must not query quota',
      );
      expect(find.byKey(const ValueKey('source-login-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-login-retry')), findsOneWidget);
      final other = (await f.owner.create('另一个来源'))!;
      await f.owner.login(other);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<FButton>(find.byKey(const ValueKey('source-login-retry')))
            .onPress,
        isNull,
      );
      await f.owner.cancelLogin(other);
      await tester.pumpAndSettle();
      expect(f.owner.selected!.generation, generation);
      expect(f.service.queries.length, queries);
      await tester.tap(find.byKey(const ValueKey('source-login-retry')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.owner.selected!.generation, generation + 1);
      expect(f.owner.selected!.loginState, 'waiting');
      expect(f.owner.selected!.jobId, isNotNull);
      expect(f.service.queries.length, queries);
      await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
      await tester.pumpAndSettle();
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source management protects default and limits identity to details',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('source-remove')), findsNothing);
      expect(find.byKey(const ValueKey('source-login')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('source-details')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('same-synthetic-identity@example.test'),
        findsOneWidget,
      );
      expect(find.textContaining('默认来源受保护'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('monitor-information-close')));
      await tester.pumpAndSettle();
      expect(find.textContaining('@example.test'), findsNothing);
      f.owner.select('profile-unknown');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('source-rename-input')),
          matching: find.byType(EditableText),
        ),
        '实验项目',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('source-rename-save')));
      await tester.pumpAndSettle();
      expect(f.owner.selected!.alias, '实验项目');
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-remove-confirm')));
      await tester.pumpAndSettle();
      expect(f.owner.states.map((s) => s.id), ['current', 'profile-stale']);
      expect(f.owner.selectedId, 'current');
      expect(tester.takeException(), isNull);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cancelled login ignores late successful status without querying',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      final pending = f.service.statusGate = Completer<SourceLoginStatus>();
      f.owner.select('profile-unknown');
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-login-retry')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
      await tester.pump(const Duration(milliseconds: 100));
      final before = f.service.queries.length;
      pending.complete(const SourceLoginStatus('succeeded'));
      await tester.pumpAndSettle();
      expect(f.owner.selected!.loginState, 'cancelled');
      expect(f.owner.selected!.usage, isNull);
      expect(f.service.queries.length, before);
      expect(find.textContaining('登录已完成'), findsNothing);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed cancel remains owned and offers retry until acknowledgement',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      f.service.cancelFailures = 1;
      f.owner.select('profile-unknown');
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-login-retry')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('取消登录未确认，请重试取消。'), findsOneWidget);
      expect(find.text('重试取消登录'), findsOneWidget);
      expect(f.owner.selected!.loggingIn, isTrue);
      expect(f.owner.selected!.jobId, isNotNull);
      await tester.tap(find.byKey(const ValueKey('source-login-cancel')));
      await tester.pumpAndSettle();
      expect(f.owner.selected!.loginState, 'cancelled');
      expect(f.owner.selected!.jobId, isNull);
      expect(find.text('重试取消登录'), findsNothing);
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending removal exposes collapsed retry and disables quota selection and pin',
    (tester) async {
      final f = await syntheticMultiFixture();
      final usage = AccountUsageController(_ForbiddenUsage(), sources: f.owner);
      final launcher = LauncherController(f.backend);
      addTearDown(() {
        usage.dispose();
        f.owner.dispose();
        f.metrics.dispose();
        launcher.dispose();
      });
      f.service.removeFailures = 1;
      f.owner.select('profile-unknown');
      await tester.pumpWidget(
        sourcesHost(
          ListenableBuilder(
            listenable: usage,
            builder: (_, _) =>
                AccountsWorkspacePage(launcher: launcher, usage: usage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-management')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-remove-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('retry-remove-profile-unknown')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-overview-profile-unknown')),
        findsNothing,
      );
      expect(
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('account-source-selector')),
            )
            .items
            .values,
        isNot(contains('profile-unknown')),
      );
      await tester.tap(find.byKey(const ValueKey('toggle-source-overview')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FButton>(
              find.byKey(const ValueKey('source-select-profile-unknown')),
            )
            .onPress,
        isNull,
      );
      expect(
        tester
            .widget<MonitorIconAction>(
              find.byKey(const ValueKey('source-pin-profile-unknown')),
            )
            .onPress,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('toggle-source-overview')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('retry-remove-profile-unknown')),
      );
      await tester.pumpAndSettle();
      expect(f.owner.states.map((s) => s.id), ['current', 'profile-stale']);
      expect(
        find.byKey(const ValueKey('retry-remove-profile-unknown')),
        findsNothing,
      );
      f.metrics.select(null);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
