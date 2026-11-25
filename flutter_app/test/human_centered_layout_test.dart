import 'dart:io';

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/launcher_page.dart';
import 'package:codex_timezone/app/session_measurement_workspace.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;
import 'session_activity_timeline_widget_test.dart' show timelineApp;
import 'sidebar_workspace_render_test.dart' show NoRenderDesktop;

void main() {
  setUpAll(() async {
    timezone.initializeTimeZones();
    // Density is evaluated with the desktop fonts, not Ahem's square glyphs.
    for (final (family, path) in [
      ('Segoe UI Variable Text', 'C:/Windows/Fonts/SegUIVar.ttf'),
      ('Microsoft YaHei UI', 'C:/Windows/Fonts/msyh.ttc'),
      ('Microsoft YaHei', 'C:/Windows/Fonts/msyh.ttc'),
    ]) {
      final file = File(path);
      if (file.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  for (final language in ['zh', 'en']) {
    for (final width in [760.0, 1280.0]) {
      testWidgets(
        '$language launch task remains compact and actionable at $width and 125%',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'flutter-language': language,
          });
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            LauncherApplication(
              backend: PageBackend(),
              usageService: PageUsage(),
              desktop: NoRenderDesktop(),
              networkFactory: () => NetworkController(preview: true),
            ),
          );
          await tester.pumpAndSettle();
          final clock = find.byKey(const ValueKey('time-preview-card'));
          expect(tester.getSize(clock).height, lessThan(320));
          final mode = tester.getRect(
            find.byKey(const ValueKey('launcher-mode')),
          );
          final zone = tester.getRect(
            find.byKey(const ValueKey('launcher-timezone')),
          );
          if (width == 760) {
            expect(mode.top, closeTo(zone.top, 1));
            expect(mode.right, lessThan(zone.left));
          } else {
            expect(mode.left, greaterThan(tester.getRect(clock).right));
          }
          final launch = find.text(
            language == 'en' ? 'Save and launch Codex' : '保存并启动 Codex',
          );
          expect(launch.hitTestable(), findsOneWidget);
          final owner = tester
              .widget<LauncherPage>(find.byType(LauncherPage))
              .launcher;
          await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('query-account-usage')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
          await tester.pumpAndSettle();
          final quotaType = tester.getRect(
            find.byKey(const ValueKey('analysis-quota-bucket')),
          );
          final quotaView = tester.getRect(
            find.byKey(const ValueKey('analysis-quota-view')),
          );
          expect(quotaType.top, closeTo(quotaView.top, 1));
          final metric = tester.getRect(
            find.byKey(const ValueKey('session-recent-metric')),
          );
          final presentation = tester.getRect(
            find.byKey(const ValueKey('session-recent-presentation')),
          );
          final range = tester.getRect(
            find.byKey(const ValueKey('session-recent-range')),
          );
          expect(metric.top, closeTo(presentation.top, 1));
          expect(metric.top, closeTo(range.top, 1));
          await tester.tap(find.byKey(const ValueKey('workspace-launcher')));
          await tester.pumpAndSettle();
          expect(
            tester.widget<LauncherPage>(find.byType(LauncherPage)).launcher,
            same(owner),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'measurement entries wrap at narrow width without losing either action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(260, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final selection = ValueNotifier(false);
      addTearDown(selection.dispose);
      await tester.pumpWidget(
        timelineApp(
          SessionMeasurementWorkspace(
            independentApiSelected: selection,
            currentSession: const Text('current fixture'),
            independentApi: const Text('api fixture'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('measurement-independent-api')),
      );
      await tester.pumpAndSettle();
      expect(selection.value, isTrue);
      expect(find.text('api fixture'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('measurement-current-session')),
      );
      await tester.pumpAndSettle();
      expect(selection.value, isFalse);
      expect(find.text('current fixture'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
