import 'dart:async';

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'benchmark_fixtures.dart';
import 'benchmark_live_frontend_test.dart' show liveObservation;

class _DisposalBackend extends BenchmarkBackend {
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command == 'benchmark_catalog') {
      return {
        ...await super.call(command, payload),
        'offlineOnly': false,
        'liveExecutionEnabled': true,
      };
    }
    if (command == 'benchmark_start') {
      calls.add(command);
      payloads.add(Map.of(payload));
      sequence++;
      return pendingStart?.future ??
          (liveObservation()
            ..['state'] = 'streaming'
            ..['cleanupPending'] = true
            ..['successfulSample'] = false);
    }
    if (command == 'benchmark_status') {
      calls.add(command);
      payloads.add(Map.of(payload));
      return liveObservation()
        ..['state'] = state
        ..['cleanupPending'] = cleaning
        ..['successfulSample'] = state == 'completed';
    }
    return super.call(command, payload);
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  for (final delayed in [false, true]) {
    testWidgets(
      'app disposal cleans owned live request including delayed acknowledgement=$delayed',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final b = _DisposalBackend();
        if (delayed) b.pendingStart = Completer();
        final c = BenchmarkController(
          BenchmarkService(b),
          pollInterval: const Duration(days: 1),
        );
        await c.initialize();
        await c.selectMode('live');
        c.updateLiveConfig(
          const BenchmarkLiveConfig(
            baseUrl: 'https://synthetic.invalid/v1',
            model: 'fixture-model',
            prompt: 'synthetic prompt',
            route: 'direct',
          ),
        );
        c.updateApiKey('synthetic-key');
        await tester.pumpWidget(
          LauncherApplication(
            backend: b,
            benchmarkController: c,
            networkFactory: () => NetworkController(preview: true),
          ),
        );
        await tester.pumpAndSettle();
        final start = c.start();
        await tester.pump();
        expect(b.calls.where((v) => v == 'benchmark_start'), hasLength(1));
        await tester.pumpWidget(const SizedBox());
        b.pendingStart?.complete(
          liveObservation()
            ..['state'] = 'streaming'
            ..['cleanupPending'] = true
            ..['successfulSample'] = false,
        );
        await start;
        await tester.pumpAndSettle();
        expect(b.calls.where((v) => v == 'benchmark_shutdown'), hasLength(1));
        expect(
          b.payloads[b.calls.indexOf('benchmark_shutdown')]['runId'],
          'run-1',
        );
        expect(c.cleanupComplete, true);
      },
    );
  }
}
