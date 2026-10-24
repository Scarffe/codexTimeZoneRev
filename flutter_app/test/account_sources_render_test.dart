import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
import 'chart_overview_test.dart' show overviewGraphKeys;

void main() {
  final output = Platform.environment['MULTI_ACCOUNT_RENDER_DIR'];
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
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
    ]) {
      final file = File(path);
      if (file.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
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

  for (final dark in [false, true]) {
    for (final width in [1280.0, 760.0]) {
      testWidgets(
        '${dark ? 'dark' : 'light'} $width 125 percent multi source production widgets',
        (tester) async {
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final f = await syntheticMultiFixture();
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: LauncherApplication(
                offlineTrial: true,
                backend: f.backend,
                sourceController: f.owner,
                sessionMetricsController: f.metrics,
                initialAppearance: dark ? 'dark' : 'light',
                desktop: SyntheticMultiDesktop(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
          await tester.pumpAndSettle();
          await f.owner.refresh('profile-stale');
          await tester.pumpAndSettle();
          for (final key in overviewGraphKeys) {
            expect(find.byKey(ValueKey(key)), findsOneWidget);
          }
          expect(
            find.byKey(const ValueKey('source-overview-current')),
            findsNothing,
          );
          expect(find.textContaining('@example.test'), findsNothing);
          final name = '${dark ? 'dark' : 'light'}-${width.toInt()}-125pct';
          await capture(tester, boundary, '$name-collapsed');
          await tester.tap(
            find.byKey(const ValueKey('toggle-source-overview')),
          );
          await tester.pumpAndSettle();
          final current = tester.getRect(
            find.byKey(const ValueKey('source-overview-current')),
          );
          final stale = tester.getRect(
            find.byKey(const ValueKey('source-overview-profile-stale')),
          );
          if (width == 1280) {
            expect(current.top, closeTo(stale.top, .1));
          } else {
            expect(current.top, greaterThan(stale.bottom));
          }
          expect(find.textContaining('网络暂不可用'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(tester, boundary, '$name-overview');
          await tester.tap(
            find.byKey(const ValueKey('toggle-source-overview')),
          );
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const ValueKey('session-response-chart')),
            ),
            alignment: 1,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture(tester, boundary, '$name-session');
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
