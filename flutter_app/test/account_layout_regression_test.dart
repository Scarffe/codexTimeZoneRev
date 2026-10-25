import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
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
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
      ('Microsoft YaHei UI', 'msyh.ttc'),
    ]) {
      final font = File('C:/Windows/Fonts/$file');
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  for (final width in [760.0, 1280.0]) {
    for (final page in ['accounts', 'analysis']) {
      testWidgets('$page spacing at $width with enlarged text', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
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
        await tester.tap(find.byKey(ValueKey('workspace-$page')));
        await tester.pumpAndSettle();
        if (page == 'accounts') {
          final source = find.byKey(const ValueKey('account-source-selector'));
          final field = find.descendant(
            of: source,
            matching: find.byType(EditableText),
          );
          final control = tester.getRect(field);
          final overview = tester.getRect(
            find.byKey(const ValueKey('toggle-source-overview')),
          );
          expect(
            (overview.center.dy - control.center.dy).abs(),
            lessThanOrEqualTo(2),
            reason:
                'Align buttons with the dropdown, not its label+field group',
          );
          for (final key in ['add-account-source', 'source-management']) {
            final rect = tester.getRect(find.byKey(ValueKey(key)));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
          }
          await tester.tap(
            find.byKey(const ValueKey('toggle-source-overview')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('source-overview-profile-primary')),
            findsOneWidget,
          );
        } else {
          final source = tester.getRect(
            find.byKey(const ValueKey('analysis-account-source')),
          );
          final bucket = tester.getRect(
            find.byKey(const ValueKey('analysis-quota-bucket')),
          );
          final view = tester.getRect(
            find.byKey(const ValueKey('analysis-quota-view')),
          );
          expect(bucket.top - source.bottom, greaterThanOrEqualTo(12));
          if (view.top > bucket.top + 2) {
            expect(view.top - bucket.bottom, greaterThanOrEqualTo(12));
          }
        }
        expect(tester.takeException(), isNull);
        final output = Platform.environment['ACCOUNT_LAYOUT_RENDER_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File('$output/${page}_${width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
