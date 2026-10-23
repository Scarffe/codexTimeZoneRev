import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/clocks.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/launcher_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:timezone/data/latest.dart' as timezone;

class _Usage implements AccountUsageService {
  int calls = 0;
  AccountUsage? result;
  String? failure;

  @override
  Future<AccountUsage> query(String path) async {
    calls++;
    if (failure != null) throw StateError(failure!);
    return result!;
  }
}

AccountUsage _data({
  List<UsageBucket>? buckets,
  String? limitsError,
  String? tokensError,
  DateTime? fetchedAt,
  DateTime? tokensFetchedAt,
  String identity = 'account-a',
}) => AccountUsage(
  email: '$identity@example.test',
  identityKey: identity,
  plan: 'plus',
  buckets:
      buckets ??
      [
        UsageBucket(
          label: 'Codex',
          windows: [
            UsageWindow(
              usedPercent: 25,
              durationMinutes: 300,
              resetsAt: DateTime.now().add(const Duration(hours: 6)),
            ),
            UsageWindow(
              usedPercent: null,
              durationMinutes: 45,
              resetsAt: DateTime.now().subtract(const Duration(minutes: 1)),
            ),
          ],
        ),
      ],
  fetchedAt: fetchedAt ?? DateTime.now(),
  tokensFetchedAt: tokensFetchedAt ?? DateTime.utc(2026, 10, 12, 8, 30),
  lifetimeTokens: 1234567,
  latestDailyTokens: 12345,
  latestDate: '2026-10-11',
  limitsError: limitsError,
  tokensError: tokensError,
);

Widget _app(
  AccountUsageController controller,
  LauncherController launcher, {
  bool bounded = false,
}) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (_, child) => FTheme(
    data: lightLauncherTheme,
    child: FToaster(
      child: FTooltipGroup(
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 14, color: Color(0xff000000)),
          child: child!,
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) => PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => ListenableBuilder(
      listenable: controller,
      builder: (_, _) => SingleChildScrollView(
        child: SizedBox(
          height: bounded ? 800 : null,
          child: AccountUsagePanel(
            controller: controller,
            launcher: launcher,
            bounded: bounded,
          ),
        ),
      ),
    ),
  ),
);

MonitorBarChart _chart(WidgetTester tester) => tester.widget<MonitorBarChart>(
  find.byKey(const ValueKey('account-quota-chart')),
);

Future<void> _choose(WidgetTester tester, String key, String value) async {
  tester.widget<MonitorChoice>(find.byKey(ValueKey(key))).onChanged(value);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(timezone.initializeTimeZones);

  late _Usage service;
  late AccountUsageController controller;
  late LauncherController launcher;
  setUp(() {
    service = _Usage()..result = _data();
    controller = AccountUsageController(service);
    launcher = LauncherController(const PreviewBackend());
  });
  tearDown(() {
    controller.dispose();
    launcher.dispose();
  });

  testWidgets(
    'remaining used and reset selectors change actual chart data locally',
    (tester) async {
      await controller.query('desktop');
      await tester.pumpWidget(_app(controller, launcher));
      await tester.pumpAndSettle();
      expect(_chart(tester).horizontal, isTrue);
      expect(_chart(tester).unit, '%');
      expect(_chart(tester).maxValue, 100);
      expect(_chart(tester).bars.map((b) => b.label), ['5 小时额度', '45 分钟额度']);
      expect(_chart(tester).bars.map((b) => b.value), [75, null]);
      await _choose(tester, 'account-quota-view', 'used');
      expect(_chart(tester).bars.map((b) => b.value), [25, null]);
      expect(_chart(tester).maxValue, 100);
      await _choose(tester, 'account-quota-view', 'reset');
      expect(_chart(tester).unit, '小时');
      expect(_chart(tester).maxValue, isNull);
      expect(_chart(tester).bars.first.value, closeTo(6, .01));
      expect(find.textContaining('到期 · 待查询'), findsWidgets);
      expect(service.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'actual bucket identity survives reorder and falls back when removed',
    (tester) async {
      const other = UsageBucket(
        id: 'other',
        label: '专用额度',
        windows: [UsageWindow(usedPercent: 42, durationMinutes: 60)],
      );
      final original = _data().buckets.first;
      service.result = _data(buckets: [other, original]);
      await controller.query('desktop');
      await tester.pumpWidget(_app(controller, launcher));
      await tester.pumpAndSettle();
      expect(_chart(tester).bars.first.value, 75);
      await _choose(tester, 'account-quota-bucket', 'other');
      expect(_chart(tester).bars.single.value, 58);
      service.result = _data(buckets: [original, other]);
      await controller.query('desktop');
      await tester.pumpAndSettle();
      expect(_chart(tester).bars.single.value, 58);
      service.result = _data(buckets: [original]);
      await controller.query('desktop');
      await tester.pumpAndSettle();
      expect(_chart(tester).bars.first.value, 75);
      expect(service.calls, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty windows and null values never fabricate a quota', (
    tester,
  ) async {
    service.result = _data(
      buckets: [const UsageBucket(label: 'Codex', windows: [])],
    );
    await controller.query('desktop');
    await tester.pumpWidget(_app(controller, launcher));
    await tester.pumpAndSettle();
    expect(find.text('额度信息暂不可用'), findsWidgets);
    expect(find.byKey(const ValueKey('account-quota-chart')), findsNothing);
    service.result = _data(
      buckets: [
        const UsageBucket(
          label: 'Codex',
          windows: [
            UsageWindow(durationMinutes: 90),
            UsageWindow(usedPercent: 100, durationMinutes: 120),
          ],
        ),
      ],
    );
    await controller.query('desktop');
    await tester.pumpAndSettle();
    expect(_chart(tester).bars.map((b) => b.value), [null, 0]);
    await _choose(tester, 'account-quota-view', 'reset');
    expect(_chart(tester).bars.map((b) => b.value), [null, null]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed refresh retains authorized cache but source change clears chart',
    (tester) async {
      await controller.query('desktop');
      await tester.pumpWidget(_app(controller, launcher));
      await tester.pumpAndSettle();
      service.failure = '临时读取失败';
      await controller.query('desktop');
      await tester.pumpAndSettle();
      expect(_chart(tester).bars.first.value, 75);
      expect(find.textContaining('上次观测'), findsWidgets);
      expect(find.textContaining('退避'), findsWidgets);
      controller.sourceChanged('another-desktop');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-quota-chart')), findsNothing);
      expect(find.textContaining('account-a@example.test'), findsNothing);
      expect(find.text('1,234,567'), findsNothing);
      expect(service.calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('account identity failure clears old chart and token facts', (
    tester,
  ) async {
    await controller.query('desktop');
    await tester.pumpWidget(_app(controller, launcher));
    await tester.pumpAndSettle();
    service.failure = '未检测到已登录账号';
    await controller.query('desktop');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('account-quota-chart')), findsNothing);
    expect(find.text('1,234,567'), findsNothing);
    expect(find.textContaining('查询失败'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'partial token failure preserves quota and actual dated token facts',
    (tester) async {
      final tokenTime = DateTime.utc(2026, 10, 12, 8, 30);
      final quotaTime = DateTime.utc(2026, 10, 23, 9, 15);
      service.result = _data(
        tokensError: 'token统计暂时失败',
        fetchedAt: quotaTime,
        tokensFetchedAt: tokenTime,
      );
      await controller.query('desktop');
      await tester.pumpWidget(_app(controller, launcher));
      await tester.pumpAndSettle();
      expect(_chart(tester).bars.first.value, 75);
      expect(find.text('1,234,567'), findsOneWidget);
      expect(find.text('12,345'), findsOneWidget);
      expect(find.textContaining('2026-10-11'), findsWidgets);
      expect(find.textContaining('token 更新失败'), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const ValueKey('account-usage-info')),
      );
      await tester.tap(find.byKey(const ValueKey('account-usage-info')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(quotaTime.toLocal().toIso8601String()),
        findsWidgets,
      );
      expect(
        find.textContaining(tokenTime.toLocal().toIso8601String()),
        findsWidgets,
      );
      expect(find.textContaining('token统计暂时失败'), findsWidgets);
      expect(service.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('limits failure keeps separate available token statistics', (
    tester,
  ) async {
    service.result = _data(buckets: [], limitsError: '额度暂时失败');
    await controller.query('desktop');
    await tester.pumpWidget(_app(controller, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('account-quota-chart')), findsNothing);
    expect(find.text('1,234,567'), findsOneWidget);
    expect(find.text('12,345'), findsOneWidget);
    expect(find.textContaining('额度更新失败'), findsWidgets);
    expect(find.textContaining('token 更新失败'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'time basis and minute countdown never query or change launcher settings',
    (tester) async {
      await controller.query('desktop');
      final settings = launcher.settings;
      final reset = controller.data!.buckets.first.windows.first.resetsAt!;
      await tester.pumpWidget(_app(controller, launcher, bounded: true));
      await tester.pumpAndSettle();
      await _choose(tester, 'usage-time-basis', 'node');
      expect(controller.useLocalTime, isFalse);
      expect(
        find.textContaining(usageResetTime(settings, reset, local: false)),
        findsWidgets,
      );
      await _choose(tester, 'usage-time-basis', 'local');
      expect(controller.useLocalTime, isTrue);
      expect(
        find.textContaining(usageResetTime(settings, reset, local: true)),
        findsWidgets,
      );
      await tester.pump(const Duration(minutes: 2));
      expect(service.calls, 1);
      expect(launcher.settings, same(settings));
      expect(find.byKey(const ValueKey('query-account-usage')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('toggle-usage-monitor')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-details-toggle')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
