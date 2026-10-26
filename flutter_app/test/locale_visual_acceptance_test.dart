import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:codex_timezone/app/session_rhythm_charts.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
import 'support/quota_history_fixture.dart';
import 'support/session_rhythm_fixture.dart';
import 'support/workspace_attention_fixture.dart';

// Six representative cases, not a Cartesian product. Every palette has light
// and dark coverage; both languages, three widths and 125% text are exercised.
const _cases = [
  (DashboardThemeStyle.soft, 'light', AppLanguage.zh, 1280.0),
  (DashboardThemeStyle.soft, 'dark', AppLanguage.en, 760.0),
  (DashboardThemeStyle.tech, 'light', AppLanguage.en, 1280.0),
  (DashboardThemeStyle.tech, 'dark', AppLanguage.zh, 760.0),
  (DashboardThemeStyle.graphite, 'light', AppLanguage.zh, 600.0),
  (DashboardThemeStyle.graphite, 'dark', AppLanguage.en, 600.0),
];

void main() {
  final output = Platform.environment['LOCALE_RENDER_DIR'];
  setUpAll(() async {
    timezone.initializeTimeZones();
    for (final (family, asset) in [
      ('packages/forui/Inter', 'packages/forui/assets/fonts/inter/Inter.ttf'),
      (
        'packages/forui_lucide/ForuiLucideIcons',
        'packages/forui_lucide/assets/lucide.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    for (final (family, file) in [
      ('Segoe UI', 'segoeui.ttf'),
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
      ('Microsoft YaHei UI', 'msyh.ttc'),
      ('Microsoft YaHei', 'msyh.ttc'),
    ]) {
      final font = File('C:/Windows/Fonts/$file');
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (style, mode, language, width) in _cases) {
    final name = '${style.id}-$mode-${language.name}-${width.toInt()}';
    testWidgets('$name six workspaces, settings, U1 and U2 at 125%', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1100);
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final fixture = await WorkspaceAttentionFixture.create();
      final aliases = fixture.sources.states.map((s) => s.alias).toList();
      final sourceQueries = fixture.sourceService.queries.length;
      final selectedSource = fixture.sources.selectedId;
      final selectedSession = fixture.metrics.selected;
      for (final source in fixture.sources.states) {
        source.historySegmentId = 'current-segment';
        source.historyNeedsNewSegment = false;
      }
      final history = await HistoryFixture.create(
        records: [
          for (var hour = 0; hour < 24; hour++)
            historyRecord(
              hour,
              minutesAgo: 24 * 60 - hour * 60,
              used: (hour * 3 % 80) + .25,
              failed: hour == 11,
            ),
        ],
      );
      // The application uses the workspace's one source owner. Only the pure
      // local reader/projector from this history fixture is injected below.
      history.owner.dispose();
      final rhythmStore = SessionRhythmStore.memory();
      await rhythmStore.write(rhythmFixtureCache());
      final rhythm = SessionRhythmController(
        backend: fixture.backend,
        store: rhythmStore,
        now: () => rhythmFixtureNow,
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: LauncherApplication(
            offlineTrial: true,
            initialThemeStyle: style,
            initialAppearance: mode,
            backend: fixture.backend,
            desktop: SyntheticMultiDesktop(),
            sourceController: fixture.sources,
            sessionMetricsController: fixture.metrics,
            attentionController: fixture.attention,
            benchmarkController: fixture.benchmark,
            historyController: history.controller,
            rhythmController: rhythm,
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).onLanguage!(
        language,
      );
      await tester.pumpAndSettle();
      await fixture.completeA();
      final copy = AppCopy(language);

      Future<void> capture(String suffix) async {
        expect(tester.takeException(), isNull, reason: '$name $suffix');
        expect(fixture.sources.selectedId, selectedSource);
        expect(fixture.metrics.selected, selectedSession);
        expect(fixture.sources.states.map((s) => s.alias), aliases);
        expect(fixture.sourceService.queries.length, sourceQueries);
        if (output == null) return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            final file = File('$output/$name-$suffix.png');
            if (await file.exists()) {
              throw StateError(
                'Do not overwrite render evidence: ${file.path}',
              );
            }
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      Future<void> open(String page) async {
        await tester.tap(find.byKey(ValueKey('workspace-$page')));
        await tester.pumpAndSettle();
      }

      for (final page in [
        'launcher',
        'overview',
        'accounts',
        'sessions',
        'analysis',
        'benchmark',
      ]) {
        await open(page);
        if (page == 'accounts') {
          expect(find.text(aliases.first), findsWidgets);
        }
        if (page == 'sessions') {
          expect(find.textContaining('合成 A · 图像处理'), findsWidgets);
        }
        if (page == 'analysis') {
          await Scrollable.ensureVisible(
            tester.element(find.byKey(const ValueKey('account-quota-chart'))),
            alignment: .05,
          );
          await tester.pumpAndSettle();
        }
        await capture(page);

        // Four extra images in one wide English case expose all current-session
        // graphs. The analysis image above includes the fifth, account quota.
        if (page == 'analysis' &&
            style == DashboardThemeStyle.tech &&
            language == AppLanguage.en &&
            width == 1280) {
          for (final chart in [
            'session-recent-chart',
            'session-configuration-chart',
            'session-activity-chart',
            'session-response-chart',
          ]) {
            await Scrollable.ensureVisible(
              tester.element(find.byKey(ValueKey(chart))),
              alignment: .05,
            );
            await tester.pumpAndSettle();
            await capture(chart);
          }
        }
      }

      await open('accounts');
      await tester.tap(find.byKey(const ValueKey('accounts-history')));
      await tester.pumpAndSettle();
      expect(history.controller.projection!.sampleCount, greaterThan(0));
      expect(find.byType(MonitorChartFrame), findsNWidgets(3));
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('quota-history-trend'))),
        alignment: .05,
      );
      await tester.pumpAndSettle();
      await capture('quota-history');

      await open('analysis');
      await tester.ensureVisible(
        find.text(copy.text('analysis.sessionRhythm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(copy.text('analysis.sessionRhythm')));
      await tester.pumpAndSettle();
      expect(find.byType(RhythmInspection), findsNWidgets(3));
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('rhythm-heatmap'))),
        alignment: .05,
      );
      await tester.pumpAndSettle();
      await capture('session-rhythm');

      await tester.tap(find.byKey(const ValueKey('monitor-settings')));
      await tester.pumpAndSettle();
      await capture('settings');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
