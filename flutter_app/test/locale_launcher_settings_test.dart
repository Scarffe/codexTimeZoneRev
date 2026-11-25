import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/monitor_information.dart';
import 'package:codex_timezone/app/monitor_settings_dialog.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/domain/settings.dart';
import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/launcher_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:timezone/data/latest.dart' as timezone;

class _LocalBackend implements LauncherBackend {
  final List<String> calls = [];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) {
    calls.add(command);
    return const PreviewBackend().call(command, payload);
  }
}

class _NoUsage implements AccountUsageService {
  @override
  Future<AccountUsage> query(String path) =>
      throw StateError('locale redraw must never query');
}

Widget _app(Widget child, ValueNotifier<AppLanguage> language) =>
    ValueListenableBuilder<AppLanguage>(
      valueListenable: language,
      builder: (_, value, _) => AppCopyScope(
        language: value,
        child: WidgetsApp(
          color: const Color(0xff000000),
          locale: value.locale,
          localizationsDelegates: FLocalizations.localizationsDelegates,
          supportedLocales: FLocalizations.supportedLocales,
          builder: (context, child) => FTheme(
            data: lightLauncherTheme,
            child: FTooltipGroup(
              child: DefaultTextStyle(
                style: const TextStyle(fontSize: 14),
                child: child!,
              ),
            ),
          ),
          onGenerateRoute: (_) =>
              PageRouteBuilder<void>(pageBuilder: (_, _, _) => child),
        ),
      ),
    );

void main() {
  setUpAll(timezone.initializeTimeZones);

  testWidgets(
    'launcher redraw translates workflow while retaining raw data and draft',
    (tester) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final language = ValueNotifier(AppLanguage.zh);
      final backend = _LocalBackend();
      final launcher = LauncherController(backend);
      final network = NetworkController(offlineTrial: true)
        ..domestic = const IpInfo(
          ip: '192.0.2.8',
          timezone: 'Asia/Shanghai',
          source: '原始来源',
          location: '原始位置',
          organization: '原始网络',
        );
      addTearDown(language.dispose);
      addTearDown(launcher.dispose);
      addTearDown(network.dispose);
      await launcher.initialize();
      launcher.update(
        launcher.settings.copyWith(executable: r'C:\原始路径\Codex.exe'),
      );
      await tester.pumpWidget(
        _app(
          ListenableBuilder(
            listenable: launcher,
            builder: (_, _) =>
                LauncherPage(launcher: launcher, network: network),
          ),
          language,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保存并启动 Codex'), findsOneWidget);
      language.value = AppLanguage.en;
      await tester.pumpAndSettle();
      expect(find.text('Save and launch Codex'), findsOneWidget);
      expect(find.text('Launch settings'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.textContaining(r'C:\原始路径\Codex.exe'), findsWidgets);
      await tester.ensureVisible(find.text('Network location reference'));
      expect(find.text('Domestic route'), findsOneWidget);
      expect(find.text('原始位置'), findsOneWidget);
      expect(find.text('Asia/Shanghai · 原始来源'), findsOneWidget);
      expect(launcher.settings.executable, r'C:\原始路径\Codex.exe');
      expect(backend.calls, ['bootstrap']);
      launcher.report('操作失败。', detail: 'raw error: 原样保存');
      await tester.pumpAndSettle();
      expect(find.text('Operation failed.'), findsWidgets);
      expect(find.text('raw error: 原样保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'English clock retains target timezone calendar across midnight',
    (tester) async {
      final language = ValueNotifier(AppLanguage.en);
      addTearDown(language.dispose);
      await tester.pumpWidget(
        _app(
          const ClockPanel(
            settings: LauncherSettings(zoneId: 'America/New_York'),
            preview: true,
          ),
          language,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('21:24:08'), findsOneWidget);
      expect(find.text('Sep 21, 2026 · Monday'), findsOneWidget);
      expect(find.text('Sep 22, 2026 · Tuesday'), findsOneWidget);
      expect(find.text('Local time · Asia/Shanghai'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'English settings remain usable at narrow width and retain preference changes',
    (tester) async {
      tester.view.physicalSize = const Size(430, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final language = ValueNotifier(AppLanguage.en);
      final usage = AccountUsageController(_NoUsage(), offlineTrial: true);
      addTearDown(language.dispose);
      addTearDown(usage.dispose);
      await tester.pumpWidget(
        _app(MonitorSettingsDialog(controller: usage), language),
      );
      await tester.pumpAndSettle();
      expect(find.text('Monitoring and alerts'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reduced-motion')));
      await tester.pumpAndSettle();
      expect(find.text('Reduce motion: On'), findsOneWidget);
      expect(usage.reducedMotion, isTrue);
      await tester.ensureVisible(find.text('2 minutes'));
      await tester.tap(find.text('2 minutes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 minutes').last);
      await tester.pumpAndSettle();
      expect(usage.interval, const Duration(minutes: 5));
      await tester.ensureVisible(
        find.byKey(const ValueKey('session-alerts-toggle')),
      );
      await tester.tap(find.byKey(const ValueKey('session-alerts-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Turn completion alerts: On'), findsOneWidget);
      language.value = AppLanguage.zh;
      await tester.pumpAndSettle();
      expect(find.text('减少动态效果：开启'), findsOneWidget);
      expect(find.text('5 分钟'), findsOneWidget);
      expect(usage.sessionAlertsEnabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('English information actions retain raw copyable values', (
    tester,
  ) async {
    final language = ValueNotifier(AppLanguage.en);
    addTearDown(language.dispose);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => FButton(
            onPress: () => showMonitorInformation(
              context,
              title: AppCopy.of(context).text('launcher.settings'),
              titleKey: 'launcher.settings',
              builder: (_) => const MonitorInformationFact(
                label: 'Source path',
                value: r'C:\原文\source.jsonl',
                copyable: true,
              ),
            ),
            child: const Text('Open details'),
          ),
        ),
        language,
      ),
    );
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Copy Source path'), findsOneWidget);
    expect(find.text(r'Source path: C:\原文\source.jsonl'), findsOneWidget);
    expect(find.text('Launch settings'), findsOneWidget);
    language.value = AppLanguage.zh;
    await tester.pumpAndSettle();
    expect(find.text('启动设置'), findsOneWidget);
    expect(find.text(r'Source path：C:\原文\source.jsonl'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
