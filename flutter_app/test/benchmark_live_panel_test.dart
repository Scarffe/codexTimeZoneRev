import 'package:codex_timezone/app/independent_benchmark_panel.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';
import 'benchmark_live_frontend_test.dart' show liveObservation;
import 'tasks_panel_test.dart' show host;

class LivePanelBackend extends BenchmarkBackend {
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command == 'benchmark_catalog') {
      return {
        ...await super.call(command),
        'offlineOnly': false,
        'liveExecutionEnabled': true,
      };
    }
    if (command == 'benchmark_start') {
      calls.add(command);
      payloads.add(Map.of(payload));
      sequence++;
      return liveObservation();
    }
    return super.call(command, payload);
  }
}

void main() {
  for (final style in DashboardThemeStyle.values) {
    testWidgets(
      'live form keeps secret and layout through zh/en ${style.name} at320px',
      (tester) async {
        final errors = <FlutterErrorDetails>[];
        final original = FlutterError.onError;
        FlutterError.onError = (details) {
          errors.add(details);
          original?.call(details);
        };
        addTearDown(() => FlutterError.onError = original);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final b = LivePanelBackend(), language = ValueNotifier(AppLanguage.zh);
        final c = BenchmarkController(
          BenchmarkService(b),
          pollInterval: const Duration(days: 1),
        );
        addTearDown(c.dispose);
        addTearDown(language.dispose);
        await c.initialize();
        await c.selectMode('live');
        await tester.pumpWidget(
          host(IndependentBenchmarkPanel(controller: c), language, style),
        );
        await tester.pumpAndSettle();
        Future<void> enter(String key, String value) async {
          final field = find.descendant(
            of: find.byKey(ValueKey('benchmark-live-$key')),
            matching: find.byType(EditableText),
          );
          await tester.ensureVisible(field);
          await tester.enterText(field, value);
          await tester.pump();
        }

        await enter('base-url', 'http://127.0.0.1:12345/v1');
        await enter('model', 'synthetic-model');
        await enter('prompt', 'synthetic prompt');
        await enter('key', 'synthetic-key');
        c.updateLiveConfig(c.liveConfig.copy(route: 'direct'));
        language.value = AppLanguage.en;
        await tester.pumpAndSettle();
        expect(c.apiKey, 'synthetic-key');
        expect(c.liveConfig.prompt, 'synthetic prompt');
        expect(b.calls.where((v) => v == 'benchmark_start'), isEmpty);
        final edit = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const ValueKey('benchmark-live-key')),
            matching: find.byType(EditableText),
          ),
        );
        expect(edit.obscureText, true);
        await tester.ensureVisible(
          find.byKey(const ValueKey('benchmark-start')),
        );
        await tester.tap(find.byKey(const ValueKey('benchmark-start')));
        await tester.pumpAndSettle();
        expect(b.calls.where((v) => v == 'benchmark_start'), hasLength(1));
        expect(c.snapshot?.executionMode, 'live');
        expect(
          tester.takeException(),
          isNull,
          reason: errors.map((e) => e.toString()).join('\n'),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
