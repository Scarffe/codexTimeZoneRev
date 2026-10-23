import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'benchmark_fixtures.dart';

// Review artifacts exercise the production views with DTOs from the existing
// synthetic fixture. Geometry/colors are visually reviewed, never mirrored in
// unit assertions. Only the in-memory fixture backend handles explicit starts;
// no replay process or external transport is started by this matrix.
void main() {
  final output = Platform.environment['BENCHMARK_RENDER_DIR'];
  setUpAll(() async {
    timezone.initializeTimeZones();
    if (output == null) return;
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
    ]) {
      final font = File(path);
      expect(font.existsSync(), isTrue, reason: 'Evidence requires $family');
      await (FontLoader(
        family,
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

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

  for (final protocol in ['chat_completions', 'responses']) {
    for (final appearance in ['light', 'dark']) {
      for (final width in [320.0, 600.0, 760.0, 1024.0, 1280.0]) {
        for (final state in [
          'empty',
          'running',
          'completed',
          'failed',
          'cancelled',
          'restored',
        ]) {
          testWidgets(
            '$protocol $appearance $width 125% $state synthetic API',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 1100);
              tester.platformDispatcher.textScaleFactorTestValue = 1.25;
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(
                tester.platformDispatcher.clearTextScaleFactorTestValue,
              );
              final backend = BenchmarkBackend();
              final controller = BenchmarkController(
                BenchmarkService(backend),
                pollInterval: const Duration(days: 1),
              );
              await controller.initialize();
              await controller.selectProtocol(protocol);
              if (state != 'empty' && state != 'restored') {
                backend.state = state == 'running' ? 'streaming' : state;
                backend.cleaning = state == 'running';
                // Acquire ownership through the real controller so running
                // selectors/cancel/start controls render their actual guards.
                await controller.start();
              }
              if (state != 'empty') {
                final snapshot = BenchmarkSnapshot.fromJson(
                  benchmarkFixture(
                    protocol: protocol,
                    state: state == 'running'
                        ? 'streaming'
                        : state == 'restored'
                        ? 'completed'
                        : state,
                    cleaning: state == 'running',
                    success: state == 'completed' || state == 'restored',
                  ),
                );
                controller.snapshot = state == 'restored'
                    ? snapshot.recover()
                    : state == 'failed' || state == 'cancelled'
                    ? snapshot.copy(reason: 'missing_usage', clearRates: true)
                    : state == 'running'
                    ? snapshot.copy(clearRates: true)
                    : snapshot;
              }
              final boundary = GlobalKey();
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: LauncherApplication(
                    preview: true,
                    benchmarkController: controller,
                    initialAppearance: appearance,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
              await tester.pumpAndSettle();
              await tester.tap(
                find.byKey(const ValueKey('measurement-independent-api')),
              );
              await tester.pumpAndSettle();
              expect(find.text('离线回放 · 合成数据 · 客户端观测'), findsOneWidget);
              expect(backend.calls, [
                'benchmark_catalog',
                if (state != 'empty' && state != 'restored') 'benchmark_start',
              ]);
              for (final key in metricKeys) {
                expect(
                  find.byKey(ValueKey('benchmark-metric-$key')),
                  findsOneWidget,
                );
              }
              final name = '$protocol-$appearance-${width.toInt()}-$state';
              expect(tester.takeException(), isNull);
              await capture(tester, boundary, '$name-top');
              await Scrollable.ensureVisible(
                tester.element(
                  find.byKey(const ValueKey('benchmark-metric-ttftMs')),
                ),
                alignment: .04,
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await capture(tester, boundary, '$name-metrics');
              await tester.ensureVisible(find.text('请求事件时间点 · 沿客户端实测耗时定位'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await capture(tester, boundary, '$name-timing');
              final inspect = find.byKey(
                const ValueKey('benchmark-inspect-fullResponseTokensPerSecond'),
              );
              await tester.ensureVisible(inspect);
              await tester.tap(inspect);
              await tester.pumpAndSettle();
              expect(
                find.text('(输出 token − 首块 token) / (HTTP EOF − 首段内容)'),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
              await capture(tester, boundary, '$name-formula');
              await tester.tap(
                find.byKey(const ValueKey('monitor-information-close')),
              );
              await tester.pumpAndSettle();
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
