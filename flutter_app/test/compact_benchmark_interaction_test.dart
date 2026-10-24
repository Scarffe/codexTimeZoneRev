import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'benchmark_fixtures.dart';

// A formula inspector owns keyboard input while open. Removing the app's route
// guard would start a new run from this dialog or cancel the owned active run.
void main() {
  setUpAll(timezone.initializeTimeZones);

  for (final active in [false, true]) {
    testWidgets('formula route isolates shortcuts with active=$active', (
      tester,
    ) async {
      final backend = BenchmarkBackend();
      final controller = BenchmarkController(
        BenchmarkService(backend),
        pollInterval: const Duration(days: 1),
      );
      await controller.initialize();
      if (active) await controller.start();
      await tester.pumpWidget(
        LauncherApplication(preview: true, benchmarkController: controller),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
      await tester.pumpAndSettle();
      final inspect = find.byKey(const ValueKey('benchmark-inspect-ttftMs'));
      await tester.ensureVisible(inspect);
      await tester.tap(inspect);
      await tester.pumpAndSettle();
      expect(find.text('首段内容时间 − 请求开始'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(backend.sequence, active ? 1 : 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(backend.sequence, active ? 1 : 0);
      expect(backend.calls, isNot(contains('benchmark_cancel')));
      if (active) expect(controller.snapshot!.state, 'streaming');
      // Some desktop route policies leave Esc to explicit dismissal. Either way
      // the shortcut must not escape to the benchmark underneath the inspector.
      final close = find.byKey(const ValueKey('monitor-information-close'));
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      if (active) await controller.cancel();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
