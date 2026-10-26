import 'package:codex_timezone/app/session_attention_page.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/app/session_rhythm_panel.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/session_attention_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'session_attention_test.dart' show AttentionFeed;
import 'session_compact_workspace_test.dart' show compactFixture, sourcePath;
import 'session_measurement_quality_test.dart' show QualityBackend;
import 'session_metrics_test.dart' show Backend;

Widget localeApp(Widget child, AppLanguage language) => AppCopyScope(
  language: language,
  child: WidgetsApp(
    color: const Color(0xff000000),
    localizationsDelegates: FLocalizations.localizationsDelegates,
    supportedLocales: FLocalizations.supportedLocales,
    builder: (context, child) => FTheme(
      data: lightLauncherTheme,
      child: FToaster(
        child: FTooltipGroup(
          child: DefaultTextStyle(
            style: const TextStyle(fontSize: 14),
            child: child!,
          ),
        ),
      ),
    ),
    onGenerateRoute: (_) => PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => SingleChildScrollView(child: child),
    ),
  ),
);

void main() {
  testWidgets(
    'changing language preserves the open chart inspector and its raw label',
    (tester) async {
      final language = ValueNotifier(AppLanguage.en);
      addTearDown(language.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<AppLanguage>(
          valueListenable: language,
          builder: (_, value, _) => localeApp(
            const MonitorBarChart(
              bars: [ChartBar(label: 'raw-model-中文', value: null)],
              unit: 'tokens',
              showInspection: true,
              inspectionIdentity: 'same-sample',
            ),
            value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect values'));
      await tester.pumpAndSettle();
      expect(find.text('Chart values'), findsOneWidget);
      expect(find.textContaining('raw-model-中文'), findsWidgets);
      language.value = AppLanguage.zh;
      await tester.pumpAndSettle();
      expect(find.text('图表数值'), findsOneWidget);
      expect(find.textContaining('raw-model-中文：未知'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('English inbox explains explicit watches without reading logs', (
    tester,
  ) async {
    final backend = AttentionFeed();
    final controller = SessionAttentionController(backend);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      localeApp(
        SessionAttentionPage(controller: controller, onOpenNotice: (_) {}),
        AppLanguage.en,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Watched 0/8 · Unread 0'), findsOneWidget);
    expect(find.text('List available sessions'), findsOneWidget);
    expect(find.text('No unread reminders.'), findsOneWidget);
    expect(backend.polledPaths, isEmpty);
    expect(controller.alertSerial, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'English analysis translates chart controls and typed quality while preserving raw source',
    (tester) async {
      tester.view.physicalSize = const Size(760, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = SessionMetricsController(QualityBackend())
        ..selected = sourcePath
        ..data = compactFixture();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        localeApp(SessionMetricsPanel(controller: controller), AppLanguage.en),
      );
      await tester.pumpAndSettle();
      expect(find.text('Session turn statistics'), findsOneWidget);
      expect(find.text('Recent turns'), findsOneWidget);
      expect(find.text('Configuration comparison'), findsOneWidget);
      expect(find.text('Last-turn activity'), findsOneWidget);
      expect(
        find.text('Last-turn responses · Recent responses'),
        findsOneWidget,
      );
      expect(find.textContaining('Sample quality: Verified'), findsOneWidget);
      expect(find.text('Unclassified ≠ waiting'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-information')));
      await tester.pumpAndSettle();
      expect(find.text('Log: $sourcePath'), findsOneWidget);
      expect(find.text('Session ID: original-session-id'), findsOneWidget);
      expect(find.textContaining('Message #1'), findsWidgets);
      expect(find.textContaining('Unix epoch milliseconds'), findsWidgets);
      expect(controller.selected, sourcePath);
      expect(controller.alertSerial, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('English rhythm empty state preserves offline source boundary', (
    tester,
  ) async {
    final backend = Backend();
    final controller = SessionRhythmController(
      backend: backend,
      store: SessionRhythmStore.memory(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      localeApp(
        SessionRhythmPanel(
          controller: controller,
          onList: () {},
          onOpen: (_) {},
        ),
        AppLanguage.en,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sources 0/8'), findsOneWidget);
    expect(
      find.text('Add explicit sources to show session rhythm'),
      findsOneWidget,
    );
    expect(find.text('List available local sessions'), findsOneWidget);
    expect(backend.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'locale redraw keeps chart selection and the session owner without reads',
    (tester) async {
      tester.view.physicalSize = const Size(760, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = Backend();
      final controller = SessionMetricsController(backend)
        ..selected = sourcePath
        ..data = compactFixture();
      final language = ValueNotifier(AppLanguage.en);
      addTearDown(controller.dispose);
      addTearDown(language.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<AppLanguage>(
          valueListenable: language,
          builder: (_, value, _) =>
              localeApp(SessionMetricsPanel(controller: controller), value),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<MonitorChoice>(
            find.byKey(const ValueKey('session-recent-metric')),
          )
          .onChanged('status');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('session-recent-metric')),
            )
            .value,
        'status',
      );
      language.value = AppLanguage.zh;
      await tester.pumpAndSettle();
      expect(find.text('会话回合统计'), findsOneWidget);
      expect(
        tester
            .widget<MonitorChoice>(
              find.byKey(const ValueKey('session-recent-metric')),
            )
            .value,
        'status',
      );
      expect(controller.selected, sourcePath);
      expect(backend.calls, isEmpty);
      expect(controller.alertSerial, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
