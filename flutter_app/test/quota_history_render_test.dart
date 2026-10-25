import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/monitor_charts.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/quota_history_fixture.dart';
import 'support/multi_account_fixture.dart';
import 'support/compact_dashboard_fixture.dart';

void main() {
  final output = Platform.environment['QUOTA_HISTORY_RENDER_DIR'];
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
  for (final style in DashboardThemeStyle.values) {
    for (final mode in ['light', 'dark']) {
      for (final width in [760.0, 1280.0]) {
        testWidgets('history ${style.id} $mode $width at 125 percent', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1100);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final f = await HistoryFixture.create(
            records: [
              for (var hour = 0; hour < 144; hour++)
                for (var point = 0; point < 3; point++)
                  if (hour % 19 != 0)
                    historyRecord(
                      hour * 3 + point,
                      minutesAgo: 6 * 24 * 60 - hour * 60 - point * 2,
                      used: (hour * 3 % 85) + point * .75,
                      failed: hour % 17 == 0 && point == 1,
                    ),
            ],
          );
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: LauncherApplication(
                offlineTrial: true,
                initialAppearance: mode,
                initialThemeStyle: style,
                backend: CompactDashboardBackend(),
                sourceController: f.owner,
                historyController: f.controller,
                desktop: SyntheticMultiDesktop(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('accounts-history')));
          await tester.pumpAndSettle();
          expect(f.service.queries, isEmpty);
          final selectors = [
            'history-bucket',
            'history-window',
            'history-range',
            'history-segment',
          ].map((key) => tester.getRect(find.byKey(ValueKey(key)))).toList();
          for (var i = 0; i < selectors.length; i++) {
            expect(selectors[i].left, greaterThanOrEqualTo(0));
            expect(selectors[i].right, lessThanOrEqualTo(width));
            for (var j = i + 1; j < selectors.length; j++) {
              expect(selectors[i].overlaps(selectors[j]), isFalse);
              if ((selectors[i].top - selectors[j].top).abs() < 1) {
                expect(
                  (selectors[i].right - selectors[j].left).abs(),
                  greaterThanOrEqualTo(15),
                );
              }
            }
          }
          Future<void> capture(String suffix) async {
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
                final file = File(
                  '$output/${style.id}-$mode-${width.toInt()}-$suffix.png',
                );
                if (await file.exists()) {
                  throw StateError('Do not overwrite render evidence');
                }
                await file.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }

          await capture('controls');
          for (final (key, name) in [
            ('quota-history-trend', 'trend'),
            ('quota-history-heatmap', 'heatmap'),
            ('quota-history-events', 'events'),
          ]) {
            await Scrollable.ensureVisible(
              tester.element(find.byKey(ValueKey(key))),
              alignment: .05,
            );
            await tester.pumpAndSettle();
            await capture(name);
          }
          expect(find.byType(MonitorChartFrame), findsNWidgets(3));
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
