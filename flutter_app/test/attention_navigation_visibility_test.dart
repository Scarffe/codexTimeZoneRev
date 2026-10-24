import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/session_attention_page.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'monitor_lifecycle_test.dart' show nativeAction;
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
    for (final (family, path) in [
      ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
      ('Segoe UI Variable Text', r'C:\Windows\Fonts\SegUIVar.ttf'),
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
    ]) {
      final font = File(path);
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  for (final route in ['legacy', 'inbox']) {
    testWidgets(
      '$route explicit analysis target is visible after retained deep scroll',
      (tester) async {
        tester.view.physicalSize = const Size(760, 1100);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.25;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          DesktopMonitor.channel,
          (call) async => call.method == 'mainVisible' ? true : null,
        );
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
        );
        final fixture = await WorkspaceAttentionFixture.create();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: LauncherApplication(
              offlineTrial: true,
              monitorEnabled: true,
              backend: fixture.backend,
              sourceController: fixture.sources,
              sessionMetricsController: fixture.metrics,
              attentionController: fixture.attention,
              benchmarkController: fixture.benchmark,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await fixture.completeA();
        await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('session-response-chart'))),
          alignment: .1,
        );
        await tester.pumpAndSettle();
        final analysis = find.byKey(const PageStorageKey('analysis-scroll'));
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(of: analysis, matching: find.byType(Scrollable))
              .first,
        );
        final deepOffset = scroll.position.pixels;
        expect(deepOffset, greaterThan(500));
        await tester.tap(find.byKey(const ValueKey('workspace-launcher')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
        await tester.pumpAndSettle();
        expect(
          scroll.position.pixels,
          closeTo(deepOffset, .1),
          reason: 'ordinary navigation retains offset',
        );
        await tester.tap(find.byKey(const ValueKey('workspace-launcher')));
        await tester.pumpAndSettle();
        if (route == 'legacy') {
          await nativeAction('sessionDetails');
        } else {
          await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
          await tester.pumpAndSettle();
          final button = find.byKey(
            ValueKey('notice-open-${fixture.attention.notices.single.id}'),
          );
          await tester.ensureVisible(button);
          await tester.tap(button);
        }
        await tester.pumpAndSettle();
        // Capture production navigation before assertions, including the RED state.
        final output = Platform.environment['ATTENTION_TARGET_RENDER_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final picture =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File('$output/$route.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }
        final target = route == 'legacy'
            ? find.text('会话回合统计')
            : find.byKey(const ValueKey('notice-analysis-context'));
        final viewport = tester.getRect(analysis);
        final rect = tester.getRect(target);
        expect(
          rect.top,
          greaterThanOrEqualTo(viewport.top),
          reason: 'explicit target must be inside viewport without test-side scrolling',
        );
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(
          fixture.metrics.selected,
          route == 'legacy' ? workspacePathB : workspacePathA,
        );
        if (route == 'inbox') {
          expect(find.textContaining('原回合 a-current'), findsOneWidget);
          expect(find.text(workspacePathA), findsOneWidget);
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const ValueKey('session-response-chart')),
            ),
            alignment: .1,
          );
          await tester.pumpAndSettle();
          final retainedOffset = scroll.position.pixels;
          final openNotice = tester
              .widget<SessionAttentionPage>(
                find.byType(SessionAttentionPage, skipOffstage: false),
              )
              .onOpenNotice;
          final select = tester
              .widget<WorkspaceShell>(find.byType(WorkspaceShell))
              .onSelect;
          // A later ordinary navigation cancels an already queued reveal.
          openNotice(fixture.attention.notices.single);
          select(WorkspaceDestination.launcher);
          await tester.pumpAndSettle();
          expect(scroll.position.pixels, closeTo(retainedOffset, .1));
          expect(find.text('保存并启动'), findsOneWidget);
          // Disposing before the reveal callback must not access a dead page.
          openNotice(fixture.attention.notices.single);
          await tester.pumpWidget(const SizedBox());
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
