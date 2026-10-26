import 'dart:async';

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Reuse the package's existing in-memory transport; never access a real profile.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/workspace_attention_fixture.dart';

class LanguagePreferences extends InMemorySharedPreferencesStore {
  LanguagePreferences({String? language})
    : super.withData({
        if (language != null) 'flutter.flutter-language': language,
      });
  int reads = 0, writes = 0;
  bool rejectWrites = false;
  @override
  Future<Map<String, Object>> getAll() {
    reads++;
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) {
    writes++;
    return rejectWrites
        ? Future.value(false)
        : super.setValue(type, key, value);
  }
}

class HeldLanguagePreferences extends LanguagePreferences {
  final gate = Completer<Map<String, Object>>();
  @override
  Future<Map<String, Object>> getAll() {
    reads++;
    return gate.future;
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('codex_timezone/window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'status': 'applied',
            'darkHresult': 0,
            'captionHresult': 0,
            'textHresult': 0,
            'borderHresult': 0,
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('codex_timezone/window'),
          null,
        );
  });

  LauncherApplication normalApplication() => LauncherApplication(
    backend: const PreviewBackend(),
    networkFactory: () => NetworkController(preview: true),
  );
  Locale? locale(WidgetTester tester) =>
      tester.widget<WidgetsApp>(find.byType(WidgetsApp)).locale;
  Future<void> selectEnglish(WidgetTester tester) async {
    // Missing or ineffective language controls, rather than a dictionary literal,
    // make every new behavior below fail against the original application.
    expect(find.byKey(const ValueKey('workspace-language')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
  }

  for (final trial in [false, true]) {
    testWidgets(
      'language choice in ${trial ? 'offline trial' : 'preview'} is session-only',
      (tester) async {
        final preferences = LanguagePreferences(language: 'en');
        SharedPreferencesStorePlatform.instance = preferences;
        await tester.pumpWidget(
          LauncherApplication(
            preview: !trial,
            offlineTrial: trial,
            backend: const PreviewBackend(),
          ),
        );
        await tester.pumpAndSettle();
        expect(locale(tester), const Locale('zh', 'CN'));
        await selectEnglish(tester);
        expect(locale(tester), const Locale('en', 'US'));
        expect(find.text('Launcher'), findsOneWidget);
        expect(preferences.reads, 0);
        expect(preferences.writes, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('normal language selection survives app restart', (tester) async {
    final preferences = LanguagePreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    await tester.pumpWidget(normalApplication());
    await tester.pumpAndSettle();
    await selectEnglish(tester);
    expect(locale(tester), const Locale('en', 'US'));
    final saved = await SharedPreferences.getInstance();
    expect(saved.getString('flutter-language'), 'en');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(normalApplication());
    await tester.pumpAndSettle();
    expect(locale(tester), const Locale('en', 'US'));
    expect(find.text('Launcher'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late saved language never undoes the new visible choice', (
    tester,
  ) async {
    final preferences = HeldLanguagePreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    await tester.pumpWidget(normalApplication());
    await tester.pumpAndSettle();
    try {
      await selectEnglish(tester);
      expect(locale(tester), const Locale('en', 'US'));
    } finally {
      preferences.gate.complete({'flutter.flutter-language': 'zh'});
      await tester.pumpAndSettle();
    }
    expect(locale(tester), const Locale('en', 'US'));
    expect(
      (await SharedPreferences.getInstance()).getString('flutter-language'),
      'en',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locale redraw retains data owners drafts and requests', (
    tester,
  ) async {
    final fixture = await WorkspaceAttentionFixture.create();
    await tester.pumpWidget(
      LauncherApplication(
        offlineTrial: true,
        backend: fixture.backend,
        sourceController: fixture.sources,
        sessionMetricsController: fixture.metrics,
        attentionController: fixture.attention,
        benchmarkController: fixture.benchmark,
      ),
    );
    await tester.pumpAndSettle();
    final launcher = tester
        .widget<LauncherPage>(find.byType(LauncherPage))
        .launcher;
    launcher.update(
      launcher.settings.copyWith(executable: r'D:\用户草稿\Codex.exe'),
    );
    await fixture.benchmark.selectProtocol('responses');
    final calls = List<String>.of(fixture.backend.calls);
    final queries = List<String>.of(fixture.sourceService.queries);
    final selectedSource = fixture.sources.selectedId;
    final selectedLog = fixture.metrics.selected;
    final watches = fixture.attention.watches;
    final alertSerial = fixture.attention.alertSerial;
    // Exercise the redraw without advancing through menu animations: the
    // fixture's normal two-second polling remains independently enabled.
    tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).onLanguage!(
      AppLanguage.en,
    );
    await tester.pump();
    await tester.pump();
    expect(locale(tester), const Locale('en', 'US'));
    expect(
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).selected,
      WorkspaceDestination.launcher,
    );
    expect(
      tester.widget<LauncherPage>(find.byType(LauncherPage)).launcher,
      same(launcher),
    );
    expect(launcher.settings.executable, r'D:\用户草稿\Codex.exe');
    expect(fixture.sources.selectedId, selectedSource);
    expect(fixture.metrics.selected, selectedLog);
    expect(fixture.attention.watches, watches);
    expect(fixture.attention.alertSerial, alertSerial);
    expect(fixture.benchmark.protocol, 'responses');
    expect(fixture.backend.calls, calls);
    expect(fixture.sourceService.queries, queries);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('save failure keeps English choice with a visible warning', (
    tester,
  ) async {
    final preferences = LanguagePreferences()..rejectWrites = true;
    SharedPreferencesStorePlatform.instance = preferences;
    await tester.pumpWidget(normalApplication());
    await tester.pumpAndSettle();
    await selectEnglish(tester);
    expect(locale(tester), const Locale('en', 'US'));
    expect(
      find.text('Language changed, but the preference could not be saved.'),
      findsWidgets,
    );
    expect(
      (await preferences.getAll())['flutter.flutter-language'],
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
