import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/independent_benchmark_panel.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';

import 'package:timezone/data/latest.dart' as timezone;

void main() {
  setUpAll(timezone.initializeTimeZones);
  Future<BenchmarkController> show(
    WidgetTester tester,
    BenchmarkBackend backend, {
    double width = 600,
    bool dark = false,
    BenchmarkSnapshot? snapshot,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = BenchmarkController(
      BenchmarkService(backend),
      pollInterval: const Duration(days: 1),
    );
    await controller.initialize();
    controller.snapshot = snapshot;
    await tester.pumpWidget(
      LauncherApplication(
        preview: true,
        benchmarkController: controller,
        initialAppearance: dark ? 'dark' : 'light',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
    await tester.pumpAndSettle();
    return controller;
  }

  for (final protocol in ['chat_completions', 'responses']) {
    testWidgets(
      '$protocol selection and explicit start payload; panel never autostarts',
      (tester) async {
        final backend = BenchmarkBackend();
        final controller = await show(tester, backend);
        expect(find.byType(IndependentBenchmarkPanel), findsOneWidget);
        expect(backend.sequence, 0);
        await tester.tap(find.byKey(const ValueKey('benchmark-protocol')));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(protocol == 'responses' ? 'Responses' : 'Chat Completions')
              .last,
        );
        await tester.pumpAndSettle();
        expect(controller.protocol, protocol);
        await tester.ensureVisible(
          find.byKey(const ValueKey('benchmark-start')),
        );
        await tester.tap(find.byKey(const ValueKey('benchmark-start')));
        await tester.pumpAndSettle();
        expect(backend.payloads[backend.calls.indexOf('benchmark_start')], {
          'mode': 'offline_replay',
          'protocol': protocol,
          'scenarioId': protocol == 'responses'
              ? 'responses_text_complete'
              : 'chat_text_complete',
        });
        expect(find.text('离线回放 · 合成数据 · 客户端观测'), findsOneWidget);
        await controller.cancel();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final width in [320.0, 600.0, 1024.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'five metrics and timing markers fit $width dark=$dark at 125%',
        (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final raw = benchmarkFixture();
          raw['metrics']['streamTokensPerSecond']['reasons'] = [
            'text_generation_boundary_unknown',
            'reasoning_generation_boundary_unknown',
          ];
          await show(
            tester,
            BenchmarkBackend(),
            width: width,
            dark: dark,
            snapshot: BenchmarkSnapshot.fromJson(raw).recover(),
          );
          for (final key in metricKeys) {
            expect(
              find.byKey(ValueKey('benchmark-metric-$key')),
              findsOneWidget,
            );
          }
          expect(find.textContaining('已恢复'), findsOneWidget);
          expect(find.textContaining('估计'), findsWidgets);
          await tester.ensureVisible(
            find.byKey(const ValueKey('benchmark-inspect-e2eTokensPerSecond')),
          );
          await tester.tap(
            find.byKey(const ValueKey('benchmark-inspect-e2eTokensPerSecond')),
          );
          await tester.pumpAndSettle();
          expect(
            find.textContaining(
              'reported_completion_tokens_including_reasoning',
            ),
            findsWidgets,
          );
          expect(find.textContaining('100 × 10^9 / 4000000000'), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final state in ['cancelled', 'failed', 'interrupted']) {
    testWidgets(
      '$state unavailable state displays reasons without successful label',
      (tester) async {
        final snapshot = BenchmarkSnapshot.fromJson(
          benchmarkFixture(state: state, success: false),
        ).copy(reason: 'missing_usage', clearRates: true);
        await show(tester, BenchmarkBackend(), snapshot: snapshot);
        expect(find.textContaining('样本有效'), findsNothing);
        expect(find.text('—'), findsWidgets);
        expect(find.textContaining('missing_usage'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('keyboard start/cancel and source switching preserve owned job', (
    tester,
  ) async {
    final backend = BenchmarkBackend();
    final controller = await show(tester, backend);
    expect(find.textContaining('尚无测试结果'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('benchmark-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
    await tester.pumpAndSettle();
    expect(backend.sequence, 1);
    expect(controller.keepAlive, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.snapshot!.state, 'cancelled');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(backend.sequence, 2);
    await controller.cancel();
    await tester.tap(find.byKey(const ValueKey('workspace-launcher')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      backend.sequence,
      2,
      reason: 'hidden benchmark pane cannot receive keyboard start',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
