import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/session_rhythm_charts.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'session_rhythm_application_test.dart' show RhythmAppBackend;
import 'support/session_rhythm_fixture.dart';

void main() {
  final output = Platform.environment['SESSION_RHYTHM_RENDER_DIR'];
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
        testWidgets('${style.id} $mode $width rhythm 125 percent', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1400);
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final backend = RhythmAppBackend(),
              store = SessionRhythmStore.memory();
          await store.write(rhythmFixtureCache());
          final rhythm = SessionRhythmController(
            backend: backend,
            store: store,
            now: () => rhythmFixtureNow,
          );
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: LauncherApplication(
                preview: true,
                backend: backend,
                rhythmController: rhythm,
                initialThemeStyle: style,
                initialAppearance: mode,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('会话节奏'));
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

          await capture('three-charts');
          tester
              .widget<RhythmInspection>(find.byType(RhythmInspection).at(2))
              .onSelect(4);
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('rhythm-turn-summary')),
          );
          await tester.pumpAndSettle();
          await capture('selected-summary');
          expect(
            backend.calls.where((c) => c['command'] == 'session_metrics'),
            isEmpty,
          );
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
