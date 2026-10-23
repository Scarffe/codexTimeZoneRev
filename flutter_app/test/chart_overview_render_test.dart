import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageUsage;
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
    final cjk = File(r'C:\Windows\Fonts\msyh.ttc');
    expect(
      cjk.existsSync(),
      isTrue,
      reason: 'Chinese evidence requires Microsoft YaHei',
    );
    await (FontLoader(
      'Microsoft YaHei',
    )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
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
      for (final state in ['populated', 'partial', 'empty']) {
        testWidgets('$appearance $width 125% $state synthetic overview', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1100);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final backend = OverviewBackend()
            ..value = overviewFixture(partial: state == 'partial');
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: overviewApplication(
                backend,
                PageUsage(),
                appearance: appearance,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await populateOverview(tester);
          if (state == 'empty') {
            final controller = tester
                .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
                .controller;
            controller.data = null;
            controller.notifyListeners();
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          for (final key in overviewGraphKeys) {
            expect(find.byKey(ValueKey(key)), findsOneWidget);
          }
          await Scrollable.ensureVisible(
            tester.element(find.byKey(ValueKey(overviewGraphKeys.first))),
            alignment: .1,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
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
        });
      }
    }
  }
}
