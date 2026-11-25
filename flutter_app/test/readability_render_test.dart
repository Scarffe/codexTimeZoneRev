import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;
import 'sidebar_workspace_render_test.dart' show NoRenderDesktop;

void main() {
  final output = Platform.environment['TASK1_READABILITY_RENDER_DIR'];
  setUpAll(() async {
    timezone.initializeTimeZones();
    if (output == null) return;
    for (final (family, path) in [
      ('Segoe UI Variable Text', 'C:/Windows/Fonts/SegUIVar.ttf'),
      ('Microsoft YaHei UI', 'C:/Windows/Fonts/msyh.ttc'),
      ('Microsoft YaHei', 'C:/Windows/Fonts/msyh.ttc'),
    ]) {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Actual-font evidence requires $family',
      );
      await (FontLoader(
        family,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
    await (FontLoader('packages/forui_lucide/ForuiLucideIcons')
          ..addFont(rootBundle.load('packages/forui_lucide/assets/lucide.ttf')))
        .load();
  });

  for (final appearance in ['light', 'dark']) {
    for (final width in [320.0, 1100.0]) {
      testWidgets(
        '$appearance actual application at $width and 125% text stays readable',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: LauncherApplication(
                backend: PageBackend(),
                usageService: PageUsage(),
                desktop: NoRenderDesktop(),
                networkFactory: () => NetworkController(preview: true),
                initialAppearance: appearance,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final save = find.text('保存并启动 Codex');
          expect(save, findsOneWidget);
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          expect(save.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          // Capture the initial page viewport after proving its action reachable.
          final scrollable = find.byType(Scrollable).first;
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pumpAndSettle();
          if (output != null) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              try {
                final png = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(output).create(recursive: true);
                await File(
                  '$output/task1-$appearance-${width.toInt()}-125pct.png',
                ).writeAsBytes(png!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
