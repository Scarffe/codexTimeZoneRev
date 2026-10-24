import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/workspace_attention_fixture.dart';
import 'support/multi_account_fixture.dart';

void main() {
  final output = Platform.environment['WORKSPACE_ATTENTION_RENDER_DIR'];
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
  for (final theme in ['light', 'dark']) {
    for (final width in [760.0, 1280.0]) {
      testWidgets('$theme $width full six workspaces at 125 percent', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1100);
        tester.platformDispatcher.textScaleFactorTestValue = 1.25;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final fixture = await WorkspaceAttentionFixture.create();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: LauncherApplication(
              offlineTrial: true,
              initialAppearance: theme,
              backend: fixture.backend,
              desktop: SyntheticMultiDesktop(),
              sourceController: fixture.sources,
              sessionMetricsController: fixture.metrics,
              attentionController: fixture.attention,
              benchmarkController: fixture.benchmark,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await fixture.completeA();
        Future<void> capture(String name) async {
          expect(tester.takeException(), isNull);
          if (output == null) return;
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File('$output/$theme-${width.toInt()}-$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        for (final page in [
          'launcher',
          'overview',
          'accounts',
          'sessions',
          'analysis',
          'benchmark',
        ]) {
          await tester.tap(find.byKey(ValueKey('workspace-$page')));
          await tester.pumpAndSettle();
          await capture(page);
          if (page == 'analysis') {
            for (final chart in [
              'session-recent-chart',
              'session-configuration-chart',
              'session-activity-chart',
              'session-response-chart',
            ]) {
              await Scrollable.ensureVisible(
                tester.element(find.byKey(ValueKey(chart))),
                alignment: .1,
              );
              await tester.pumpAndSettle();
              await capture(chart);
            }
          }
        }
        await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
        await tester.pumpAndSettle();
        final notice = fixture.attention.notices.single;
        await tester.ensureVisible(
          find.byKey(ValueKey('notice-open-${notice.id}')),
        );
        await tester.tap(find.byKey(ValueKey('notice-open-${notice.id}')));
        await tester.pumpAndSettle();
        final noticeRect = tester.getRect(
          find.byKey(const ValueKey('notice-analysis-context')),
        );
        final analysisViewport = tester.getRect(
          find.byKey(const PageStorageKey('analysis-scroll')),
        );
        expect(noticeRect.top, greaterThanOrEqualTo(analysisViewport.top));
        expect(noticeRect.bottom, lessThanOrEqualTo(analysisViewport.bottom));
        await capture('notice-source-context');
        await fixture.unreadableB();
        await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('attention-filter-active')),
        );
        await tester.tap(find.byKey(const ValueKey('attention-filter-active')));
        await tester.pumpAndSettle();
        await capture('active-read-error');
        await tester.tap(find.byKey(const ValueKey('monitor-settings')));
        await tester.pumpAndSettle();
        await capture('settings');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
