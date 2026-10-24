import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/compact_dashboard_fixture.dart';
import 'sidebar_workspace_render_test.dart' show NoRenderDesktop;
import 'chart_overview_test.dart';

void main() {
  final output = Platform.environment['CHART_OVERVIEW_RENDER_DIR'];
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
    for (final (family, path) in [
      ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
      ('Segoe UI Variable Text', r'C:\Windows\Fonts\SegUIVar.ttf'),
    ]) {
      final font = File(path);
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
    final cjk = File(r'C:\Windows\Fonts\msyh.ttc');
    expect(
      cjk.existsSync(),
      isTrue,
      reason: 'Chinese evidence requires Microsoft YaHei',
    );
    for (final family in ['Microsoft YaHei UI', 'Microsoft YaHei']) {
      await (FontLoader(
        family,
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (output == null) return;
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File('$output/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  for (final appearance in ['light', 'dark']) {
    for (final width in [320.0, 600.0, 760.0, 1024.0, 1280.0]) {
      for (final scenario in CompactDashboardScenario.values) {
        final selectedScenarios = Platform
            .environment['CHART_OVERVIEW_SCENARIOS']
            ?.split(',');
        if (selectedScenarios != null &&
            !selectedScenarios.contains(scenario.name)) {
          continue;
        }
        for (final scale in [
          1.25,
          if (width == 1280 && scenario == CompactDashboardScenario.populated)
            1.0,
        ]) {
          testWidgets(
            '$appearance $width ${(scale * 100).round()}% ${scenario.name} synthetic overview',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 1100);
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(
                tester.platformDispatcher.clearTextScaleFactorTestValue,
              );
              final state = '${scenario.name}${scale == 1.0 ? '-100pct' : ''}';
              final backend = CompactDashboardBackend(scenario: scenario);
              final boundary = GlobalKey();
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: LauncherApplication(
                    backend: backend,
                    usageService: CompactDashboardUsageService(
                      scenario: scenario,
                    ),
                    desktop: NoRenderDesktop(),
                    networkFactory: () => NetworkController(preview: true),
                    initialAppearance: appearance,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              await overviewTap(tester, 'workspace-accounts');
              await overviewTap(tester, 'query-account-usage');
              await overviewTap(tester, 'workspace-analysis');
              await overviewTap(tester, 'session-refresh');
              tester
                  .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
                  .controller
                  .select(compactDashboardSessionPath);
              await tester.pumpAndSettle();
              if (scenario == CompactDashboardScenario.dense64) {
                await chooseOverview(tester, 'session-recent-range', '64');
              }
              expect(tester.takeException(), isNull);
              final graphKeys =
                  scenario == CompactDashboardScenario.empty ||
                      scenario == CompactDashboardScenario.error
                  ? overviewGraphKeys.skip(1).toList()
                  : overviewGraphKeys;
              for (final key in graphKeys) {
                expect(find.byKey(ValueKey(key)), findsOneWidget);
              }
              // The account capture is the actual initial page position. Moving
              // an inner quota chart to the top hides its title/state toolbar.
              Scrollable.of(
                tester.element(
                  find.byKey(const ValueKey('analysis-quota-card')),
                ),
              ).position.jumpTo(0);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final quotaExtent = tester
                  .getSize(find.byKey(const ValueKey('analysis-quota-card')))
                  .height;
              final sessionExtent = tester
                  .getSize(
                    find
                        .descendant(
                          of: find.byType(SessionMetricsPanel),
                          matching: find.byType(FCard),
                        )
                        .first,
                  )
                  .height;
              debugPrint(
                'COMPACT_EXTENTS $appearance $width ${(scale * 100).round()}% ${scenario.name}: quota=$quotaExtent session=$sessionExtent',
              );
              await capture(
                tester,
                boundary,
                '$appearance-${width.toInt()}-$state-account',
              );
              for (final key in overviewGraphKeys.skip(1)) {
                await Scrollable.ensureVisible(
                  tester.element(find.byKey(ValueKey(key))),
                  alignment: .1,
                );
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull);
                await capture(
                  tester,
                  boundary,
                  '$appearance-${width.toInt()}-$state-$key',
                );
              }
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
