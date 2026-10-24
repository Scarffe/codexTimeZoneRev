import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Existing shared_preferences test transport; no additional dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/workspace_attention_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

class ObservedPreferences extends InMemorySharedPreferencesStore {
  ObservedPreferences()
    : super.withData({
        'flutter.flutter-appearance': 'dark',
        'flutter.flutter-theme-style': 'graphite',
      });
  int reads = 0, writes = 0;
  bool rejectWrites = false;
  @override
  Future<Map<String, Object>> getAll() {
    reads++;
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes++;
    return rejectWrites
        ? Future.value(false)
        : super.setValue(valueType, key, value);
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stored family round-trips without changing brightness and rejects false saves', () async {
    final store = ObservedPreferences();
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await SharedPreferences.getInstance();
    expect(readLauncherAppearancePreferences(prefs), (
      appearance: 'dark',
      style: DashboardThemeStyle.graphite,
    ));
    await saveLauncherThemeStyle(prefs, DashboardThemeStyle.tech);
    await prefs.reload();
    expect(readLauncherAppearancePreferences(prefs), (
      appearance: 'dark',
      style: DashboardThemeStyle.tech,
    ));
    store.rejectWrites = true;
    await expectLater(
      saveLauncherThemeStyle(prefs, DashboardThemeStyle.soft),
      throwsStateError,
    );
    await prefs.reload();
    expect(prefs.getString('flutter-theme-style'), 'tech');
  });

  for (final invalid in [null, 'old-gold', 7, false]) {
    test(
      'invalid family $invalid preserves independently valid dark preference',
      () async {
        SharedPreferences.setMockInitialValues({
          'flutter-appearance': 'dark',
          'flutter-theme-style': ?invalid,
        });
        final prefs = await SharedPreferences.getInstance();
        expect(readLauncherAppearancePreferences(prefs), (
          appearance: 'dark',
          style: DashboardThemeStyle.soft,
        ));
      },
    );
  }

  for (final trial in [false, true]) {
    testWidgets(
      '${trial ? 'trial' : 'preview'} style actions perform zero preference IO',
      (tester) async {
        final store = ObservedPreferences();
        SharedPreferencesStorePlatform.instance = store;
        await tester.pumpWidget(
          LauncherApplication(
            preview: !trial,
            backend: const PreviewBackend(),
            offlineTrial: trial,
            initialAppearance: 'light',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).themeStyle,
          DashboardThemeStyle.soft,
        );
        await tester.tap(find.byKey(const ValueKey('workspace-theme')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('石墨·香槟'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).appearance,
          'light',
        );
        expect(store.reads, 0);
        expect(store.writes, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'family-only sync retains drafts sources scroll and read owners',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final calls = <MethodCall>[];
      const channel = MethodChannel('codex_timezone/window');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return {
              'status': 'applied',
              'darkHresult': 0,
              'captionHresult': 0,
              'textHresult': 0,
              'borderHresult': 0,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final f = await WorkspaceAttentionFixture.create();
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          initialAppearance: 'light',
          backend: f.backend,
          sourceController: f.sources,
          sessionMetricsController: f.metrics,
          attentionController: f.attention,
          benchmarkController: f.benchmark,
        ),
      );
      await tester.pumpAndSettle();
      final launcher = tester
          .widget<LauncherPage>(find.byType(LauncherPage))
          .launcher;
      launcher.update(
        launcher.settings.copyWith(executable: 'retained theme draft'),
      );
      await f.benchmark.selectProtocol('responses');
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const PageStorageKey('analysis-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(100);
      await tester.pumpAndSettle();
      final reads = List<String>.of(f.backend.calls);
      final quotaReads = List<String>.of(f.sourceService.queries);
      final selectedSource = f.sources.selectedId;
      final selectedLog = f.metrics.selected;
      final baseline = f.attention.watches;
      for (final (label, background, control) in [
        ('科技·极昼', 0xffe7ebf3, 0xff245deb),
        ('石墨·香槟', 0xffeae8e3, 0xff62503b),
        ('柔和·雾杉', 0xffe6ece8, 0xff326d76),
      ]) {
        final before = calls.length;
        final shell = tester.widget<WorkspaceShell>(
          find.byType(WorkspaceShell),
        );
        shell.onThemeStyle!(
          DashboardThemeStyle.values.singleWhere(
            (style) => style.label == label,
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(calls.length, before + 1);
        expect(calls.last.arguments['dark'], false);
        expect(calls.last.arguments['captionArgb'], background);
        expect(calls.last.arguments['menuAccentArgb'], control);
        expect(
          calls.last.arguments.keys,
          containsAll([
            'textArgb',
            'borderArgb',
            'menuSurfaceArgb',
            'menuSelectedArgb',
            'menuDangerArgb',
          ]),
        );
        final context = tester.element(
          find.byKey(const ValueKey('workspace-theme')),
        );
        expect(DashboardPalette.of(context).background.toARGB32(), background);
        expect(context.theme.colors.brightness, Brightness.light);
        expect(scroll.position.pixels, 100);
        expect(f.metrics.selected, selectedLog);
        expect(f.sources.selectedId, selectedSource);
        expect(f.attention.watches, baseline);
        expect(launcher.settings.executable, 'retained theme draft');
        expect(
          tester
              .widget<LauncherPage>(
                find.byType(LauncherPage, skipOffstage: false),
              )
              .launcher,
          same(launcher),
        );
        expect(f.benchmark.protocol, 'responses');
        expect(f.benchmark.snapshot, isNull);
        expect(f.backend.calls, reads);
        expect(f.sourceService.queries, quotaReads);
        await tester.pump();
        expect(calls.length, before + 1);
      }
      tester
          .widget<WorkspaceShell>(find.byType(WorkspaceShell))
          .onAppearance('dark');
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).themeStyle,
        DashboardThemeStyle.soft,
      );
      expect(calls.last.arguments['captionArgb'], 0xff141d1d);
      expect(f.backend.calls, reads);
      expect(f.sourceService.queries, quotaReads);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('system brightness keeps family across routes and overlays', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      const LauncherApplication(
        preview: true,
        initialThemeStyle: DashboardThemeStyle.graphite,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-theme')));
    await tester.pumpAndSettle();
    expect(
      DashboardStyleScope.of(tester.element(find.text('石墨·香槟'))),
      DashboardThemeStyle.graphite,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      DashboardPalette.of(tester.element(find.text('石墨·香槟'))).background,
      const Color(0xff1b1b1f),
    );
    final shell = tester.widget<WorkspaceShell>(find.byType(WorkspaceShell));
    expect(shell.themeStyle, DashboardThemeStyle.graphite);
    expect(shell.appearance, 'system');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'champagne menu strokes stay readable beside pale filled controls',
    (tester) async {
      await tester.pumpWidget(
        const LauncherApplication(
          preview: true,
          initialAppearance: 'light',
          initialThemeStyle: DashboardThemeStyle.graphite,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-theme')));
      await tester.pumpAndSettle();
      final sun = find.byIcon(FLucideIcons.sun).last;
      expect(sun, findsOneWidget);
      expect(IconTheme.of(tester.element(sun)).color, const Color(0xff62503b));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('default soft surfaces replace the provisional single palette', (
    tester,
  ) async {
    await tester.pumpWidget(
      const LauncherApplication(preview: true, initialAppearance: 'light'),
    );
    await tester.pumpAndSettle();
    final palette = DashboardPalette.of(
      tester.element(find.byKey(const ValueKey('workspace-theme'))),
    );
    expect(palette.background, const Color(0xffe6ece8));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'appearance menu exposes three families independently of brightness',
    (tester) async {
      await tester.pumpWidget(
        const LauncherApplication(preview: true, initialAppearance: 'light'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-theme')));
      await tester.pumpAndSettle();
      expect(find.text('柔和·雾杉'), findsOneWidget);
      expect(find.text('科技·极昼'), findsOneWidget);
      expect(find.text('石墨·香槟'), findsOneWidget);
      expect(find.text('浅色'), findsOneWidget);
      expect(find.text('深色'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
