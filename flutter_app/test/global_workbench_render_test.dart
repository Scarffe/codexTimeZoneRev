import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/global_workbench_fixture.dart';
import 'support/workspace_attention_fixture.dart';

void main() {
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
      ('Microsoft YaHei UI', 'msyh.ttc'),
      ('Microsoft YaHei', 'msyh.ttc'),
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
    ]) {
      final font = File('C:/Windows/Fonts/$file');
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  for (final (style, mode, language, width) in [
    (DashboardThemeStyle.soft, 'light', AppLanguage.zh, 1280.0),
    (DashboardThemeStyle.soft, 'dark', AppLanguage.en, 760.0),
    (DashboardThemeStyle.tech, 'light', AppLanguage.en, 1280.0),
    (DashboardThemeStyle.tech, 'dark', AppLanguage.zh, 760.0),
    (DashboardThemeStyle.graphite, 'light', AppLanguage.zh, 600.0),
    (DashboardThemeStyle.graphite, 'dark', AppLanguage.en, 600.0),
  ]) {
    testWidgets('global ${style.id} $mode ${language.name} $width at 125%', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1200);
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fixture = await WorkspaceAttentionFixture.create();
      final global = GlobalWorkbenchController(
        service: SyntheticGlobalWorkbenchService(
          snapshot: GlobalSnapshot.fromJson(
            globalSnapshotFixture(
              sessions: [globalSessionFixture(canOpenDetail: false)],
            ),
          ),
        ),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: LauncherApplication(
            offlineTrial: true,
            backend: fixture.backend,
            sourceController: fixture.sources,
            sessionMetricsController: fixture.metrics,
            attentionController: fixture.attention,
            benchmarkController: fixture.benchmark,
            globalController: global,
            initialThemeStyle: style,
            initialAppearance: mode,
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).onLanguage!(
        language,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-overview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('global-workbench')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final output = Platform.environment['GLOBAL_WORKBENCH_RENDER_DIR'];
      if (output != null) {
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
            final target = File(
              '$output/${style.id}-$mode-${language.name}-${width.toInt()}.png',
            );
            if (target.existsSync()) {
              throw StateError('preserve render evidence');
            }
            await target.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      final open = find.byKey(
        const ValueKey('global-open-synthetic-thread-01'),
      );
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('global-summary-drawer')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(
        fixture.backend.calls.where((v) => v.startsWith('global_monitor')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
