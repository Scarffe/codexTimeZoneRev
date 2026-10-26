import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/services/benchmark_store.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';

class GateStore extends BenchmarkStore {
  GateStore(super.file);
  final gate = Completer<void>();
  bool fail = false;
  @override
  Future<void> write(BenchmarkRecord record) async {
    await gate.future;
    if (fail) throw FileSystemException('denied');
    await super.write(record);
  }
}

void main() {
  late Directory temp;
  late BenchmarkBackend backend;
  late BenchmarkStore store;
  late BenchmarkController controller;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tz-benchmark-controller-');
    backend = BenchmarkBackend();
    store = BenchmarkStore(File('${temp.path}/state.json'));
    controller = BenchmarkController(
      BenchmarkService(backend),
      store: store,
      pollInterval: const Duration(days: 1),
    );
  });
  tearDown(() async {
    controller.dispose();
    await temp.delete(recursive: true);
  });
  test(
    'catalog and selection never start; explicit double start calls once',
    () async {
      await controller.initialize();
      await controller.selectProtocol('responses');
      await controller.selectScenario('responses_slow');
      expect(backend.calls, ['benchmark_catalog']);
      await Future.wait([controller.start(), controller.start()]);
      expect(backend.calls.where((c) => c == 'benchmark_start'), hasLength(1));
      expect(backend.payloads[backend.calls.indexOf('benchmark_start')], {
        'mode': 'offline_replay',
        'protocol': 'responses',
        'scenarioId': 'responses_slow',
      });
      expect(controller.keepAlive, true);
    },
  );
  test('starting intent flush precedes native admission and failure creates no run', () async {
    controller.dispose();
    final gated = GateStore(store.file)..fail = true;
    controller = BenchmarkController(BenchmarkService(backend), store: gated);
    await controller.initialize();
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(controller.keepAlive, true);
    expect(backend.calls, ['benchmark_catalog']);
    gated.gate.complete();
    await start;
    expect(backend.calls, ['benchmark_catalog']);
    expect(controller.lastError, isNotNull);
  });
  for (final action in ['cancel', 'interrupt', 'shutdown']) {
    test(
      '$action before runId arrives applies to owned ID; shutdown once',
      () async {
        await controller.initialize();
        backend.pendingStart = Completer();
        final admitted = Completer<void>();
        backend.beforeStart = () async => admitted.complete();
        final start = controller.start();
        await admitted.future.timeout(const Duration(seconds: 10));
        final pending = action == 'cancel'
            ? controller.cancel()
            : action == 'interrupt'
            ? controller.interrupt()
            : controller.shutdown();
        backend.pendingStart!.complete(
          benchmarkFixture(state: 'streaming', cleaning: true, success: false),
        );
        await Future.wait([start, pending]);
        final command = 'benchmark_$action';
        expect(backend.calls, contains(command));
        expect(
          backend.payloads[backend.calls.indexOf(command)]['runId'],
          'run-1',
        );
        expect(
          controller.snapshot!.state,
          action == 'shutdown'
              ? 'cancelled'
              : action == 'cancel'
              ? 'cancelled'
              : 'interrupted',
        );
        if (action == 'shutdown') {
          await controller.shutdown();
          await controller.start();
          expect(backend.calls.where((c) => c == command), hasLength(1));
          expect(backend.sequence, 1);
        }
      },
    );
  }
  test(
    'late streaming poll cannot reverse cancellation or replace newer run',
    () async {
      await controller.initialize();
      await controller.start();
      backend.pendingStatus = Completer();
      final poll = controller.poll();
      await Future<void>.delayed(Duration.zero);
      await controller.cancel();
      backend.pendingStatus!.complete(
        benchmarkFixture(state: 'streaming', cleaning: true),
      );
      await poll;
      expect(controller.snapshot!.state, 'cancelled');
      backend.pendingStatus = null;
      await controller.start();
      expect(backend.calls, contains('benchmark_clear'));
      expect(controller.snapshot!.runId, 'run-2');
    },
  );
  test(
    'restore active is interrupted, rates null, historical ID never managed',
    () async {
      await store.write(
        BenchmarkRecord(
          protocol: 'chat_completions',
          scenarioId: 'chat_slow',
          snapshot: BenchmarkSnapshot.fromJson(
            benchmarkFixture(state: 'streaming', cleaning: true),
          ),
        ),
      );
      await controller.initialize();
      expect(controller.snapshot!.state, 'interrupted');
      expect(controller.snapshot!.restored, true);
      expect(controller.snapshot!.reasons, contains('previous_process_ended'));
      expect(controller.snapshot!.metrics['e2eTokensPerSecond']!.value, isNull);
      expect(controller.keepAlive, false);
      await controller.clear();
      await controller.shutdown();
      expect(backend.calls, ['benchmark_catalog', 'benchmark_shutdown']);
      expect(backend.payloads.last, {'runId': null});
    },
  );
  test('restored completed cleanup-pending retains success; new start never clears old ID', () async {
    await store.write(
      BenchmarkRecord(
        protocol: 'chat_completions',
        scenarioId: 'chat_text_complete',
        snapshot: BenchmarkSnapshot.fromJson(benchmarkFixture(cleaning: true)),
      ),
    );
    await controller.initialize();
    expect(controller.snapshot!.successfulSample, true);
    expect(controller.snapshot!.state, 'completed');
    expect(controller.keepAlive, false);
    await controller.start();
    expect(backend.calls.where((c) => c == 'benchmark_clear'), isEmpty);
  });
  test(
    'shutdown terminal slot carries owned ID and incomplete cleanup is honest',
    () async {
      backend.state = 'completed';
      backend.cleaning = false;
      await controller.initialize();
      await controller.start();
      backend.pendingShutdown = Completer()
        ..complete({
          'accepting': false,
          'cleanupComplete': false,
          'runId': 'run-1',
        });
      await controller.shutdown();
      expect(backend.payloads[backend.calls.indexOf('benchmark_shutdown')], {
        'runId': 'run-1',
      });
      expect(controller.cleanupComplete, false);
      expect(controller.lastError, isNotNull);
    },
  );
  test(
    'shutdown waits in-flight owned mutation before final observation',
    () async {
      await controller.initialize();
      await controller.start();
      backend.pendingCancel = Completer();
      final cancel = controller.cancel();
      await Future<void>.delayed(Duration.zero);
      final duplicateCancel = controller.cancel();
      await Future<void>.delayed(Duration.zero);
      final exit = controller.shutdown();
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, isNot(contains('benchmark_shutdown')));
      backend.pendingCancel!.complete(
        benchmarkFixture(state: 'cancelled', cleaning: true, success: false),
      );
      await cancel;
      await duplicateCancel;
      await exit;
      expect(controller.snapshot!.cleanupPending, false);
    },
  );
  test(
    'starting intent restores as interruption without backend ownership',
    () async {
      await store.write(
        const BenchmarkRecord(
          protocol: 'responses',
          scenarioId: 'responses_slow',
          attemptId: 'attempt-1',
          starting: true,
        ),
      );
      await controller.initialize();
      expect(controller.snapshot!.state, 'interrupted');
      expect(controller.snapshot!.runId, isNull);
      expect(
        controller.snapshot!.elapsedNs,
        isNull,
        reason: 'an unobserved starting intent has no measured duration',
      );
      expect(controller.snapshot!.restored, true);
      expect(backend.calls, ['benchmark_catalog']);
    },
  );
  test('persisted attempt exists before start and malformed snapshot retains cleanup ownership', () async {
    backend.beforeStart = () async {
      final intent = jsonDecode(await store.file.readAsString()) as Map;
      expect(intent['starting'], true);
      expect(intent['attemptId'], isNotNull);
      expect(intent['snapshot'], isNull);
    };
    backend.malformedStart = true;
    await controller.initialize();
    await controller.start();
    await controller.shutdown();
    expect(backend.payloads[backend.calls.indexOf('benchmark_shutdown')], {
      'runId': 'run-1',
    });
  });
  test(
    'cancel on a failed intent does not leak to a later explicit attempt',
    () async {
      controller.dispose();
      final gated = GateStore(store.file)..fail = true;
      controller = BenchmarkController(
        BenchmarkService(backend),
        store: gated,
        pollInterval: const Duration(days: 1),
      );
      await controller.initialize();
      final first = controller.start();
      await Future<void>.delayed(Duration.zero);
      final cancel = controller.cancel();
      gated.gate.complete();
      await Future.wait([first, cancel]);
      gated.fail = false;
      await controller.start();
      expect(backend.sequence, 1);
      expect(controller.snapshot!.state, 'streaming');
    },
  );
}
