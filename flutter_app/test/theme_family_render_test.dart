import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/workspace_attention_fixture.dart';
import 'support/multi_account_fixture.dart';

void main() {
  final output = Platform.environment['THEME_FAMILY_RENDER_DIR'];
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

  for (final style in DashboardThemeStyle.values) {
    for (final mode in ['light', 'dark']) {
      for (final width in [760.0, 1280.0]) {
        testWidgets(
          '${style.id} $mode $width actual workspaces at 125 percent',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1100);
            tester.platformDispatcher.textScaleFactorTestValue = 1.25;
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final f = await WorkspaceAttentionFixture.create();
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: LauncherApplication(
                  offlineTrial: true,
                  initialAppearance: mode,
                  initialThemeStyle: style,
                  backend: f.backend,
                  desktop: SyntheticMultiDesktop(),
                  sourceController: f.sources,
                  sessionMetricsController: f.metrics,
                  attentionController: f.attention,
                  benchmarkController: f.benchmark,
                ),
              ),
            );
            await tester.pumpAndSettle();
            Future<void> capture(String name) async {
              expect(tester.takeException(), isNull);
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
                  await File(
                    '$output/${style.id}-$mode-${width.toInt()}-$name.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
            }

            await capture('launcher');
            await tester.tap(find.byKey(const ValueKey('workspace-theme')));
            await tester.pumpAndSettle();
            expect(find.text(style.label), findsOneWidget);
            expect(
              DashboardStyleScope.of(tester.element(find.text(style.label))),
              style,
            );
            await capture('appearance-popup');
            await tester.tap(find.byKey(const ValueKey('workspace-theme')));
            await tester.pumpAndSettle();
            expect(find.text('配色风格'), findsNothing);
            await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
            await tester.pumpAndSettle();
            for (final chart in [
              'account-quota-chart',
              'session-recent-chart',
              'session-configuration-chart',
              'session-activity-chart',
              'session-response-chart',
            ]) {
              final target = find.byKey(ValueKey(chart));
              expect(target, findsOneWidget);
              await Scrollable.ensureVisible(
                tester.element(target),
                alignment: .1,
              );
              await tester.pumpAndSettle();
              await capture(chart);
            }
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
