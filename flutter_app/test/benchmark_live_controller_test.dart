import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/services/benchmark_store.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_fixtures.dart';

class _IntentGateStore extends BenchmarkStore {
  _IntentGateStore() : super(File('unused-memory-only-benchmark-journal'));
  final gate = Completer<void>();
  final records = <BenchmarkRecord>[];
  @override
  Future<BenchmarkRecord?> read() async => null;
  @override
  Future<void> write(BenchmarkRecord record) async {
    if (record.starting) await gate.future;
    records.add(record);
  }
}

class _MemoryStore extends BenchmarkStore {
  _MemoryStore({this.initial}) : super(File('unused-memory-only-live-journal'));
  final BenchmarkRecord? initial;
  final records = <BenchmarkRecord>[];
  @override
  Future<BenchmarkRecord?> read() async => initial;
  @override
  Future<void> write(BenchmarkRecord record) async => records.add(record);
}

Map<String, dynamic> _liveSnapshot({
  String id = 'run-1',
  String state = 'streaming',
  bool cleaning = true,
  String protocol = 'chat_completions',
}) =>
    benchmarkFixture(
        id: id,
        state: state,
        cleaning: cleaning,
        protocol: protocol,
        success: state == 'completed',
      )
      ..['executionMode'] = 'live'
      ..['engineVersion'] = 'm4-rust-v1+aiperf-b1746a84'
      ..['requestedModel'] = 'vendor/model:preview'
      ..['responseModel'] = 'vendor/response:preview'
      ..['source'] = <String, dynamic>{
        'kind': 'user_endpoint',
        'scenarioId': null,
        'networkScope': 'user_configured_endpoint',
      };

class _LiveBackend extends BenchmarkBackend {
  Completer<String>? proxyGate;
  final proxyStarted = Completer<void>();
  final startEntered = Completer<void>();
  bool live = false;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command == 'benchmark_catalog') {
      final value = await super.call(command, payload);
      return {...value, 'offlineOnly': false, 'liveExecutionEnabled': true};
    }
    if (command == 'proxy_for_url') {
      calls.add(command);
      payloads.add(Map.of(payload));
      if (!proxyStarted.isCompleted) proxyStarted.complete();
      return {'proxy': await (proxyGate?.future ?? Future.value('DIRECT'))};
    }
    if (command == 'benchmark_start' && payload['mode'] == 'live') {
      calls.add(command);
      payloads.add(Map.of(payload));
      live = true;
      protocol = payload['protocol'] as String;
      sequence++;
      if (!startEntered.isCompleted) startEntered.complete();
      return pendingStart?.future ??
          _liveSnapshot(id: 'run-$sequence', protocol: protocol);
    }
    if (live &&
        [
          'benchmark_cancel',
          'benchmark_interrupt',
          'benchmark_status',
        ].contains(command)) {
      calls.add(command);
      payloads.add(Map.of(payload));
      if (command != 'benchmark_status') {
        state = command == 'benchmark_cancel' ? 'cancelled' : 'interrupted';
        cleaning = false;
      }
      return _liveSnapshot(
        id: 'run-$sequence',
        state: state,
        cleaning: cleaning,
        protocol: protocol,
      );
    }
    return super.call(command, payload);
  }
}

const _key = 'synthetic-live-controller-key';
const _base = 'https://provider.invalid/v1';
const _prompt = 'synthetic live controller prompt';
const _config = BenchmarkLiveConfig(
  baseUrl: _base,
  model: 'vendor/model:preview',
  prompt: _prompt,
  route: 'direct',
);
Future<void> _configure(
  BenchmarkController controller, {
  String route = 'direct',
}) async {
  await controller.initialize();
  await controller.selectMode('live');
  controller.updateLiveConfig(_config.copy(route: route));
  controller.updateApiKey(_key);
}

void main() {
  // Catches delayed persistence allocating a new request after explicit cancellation.
  test(
    'cancel during start intent persistence prevents native admission',
    () async {
      final backend = BenchmarkBackend();
      final store = _IntentGateStore();
      final controller = BenchmarkController(
        BenchmarkService(backend),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final start = controller.start();
      final cancel = controller.cancel();
      store.gate.complete();
      await Future.wait([start, cancel]);
      expect(backend.calls.where((c) => c == 'benchmark_start'), isEmpty);
      expect(controller.keepAlive, false);
    },
  );

  test('configuration never sends; explicit live Start captures config and memory key once', () async {
    final backend = _LiveBackend();
    final store = _MemoryStore();
    final controller = BenchmarkController(
      BenchmarkService(backend),
      store: store,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await _configure(controller);
    expect(backend.calls, ['benchmark_catalog']);
    expect(controller.canStart, true);
    controller.updateApiKey('synthetic\ninvalid');
    expect(controller.canStart, false);
    controller.updateApiKey(_key);
    await Future.wait([controller.start(), controller.start()]);
    final starts = backend.calls.where((c) => c == 'benchmark_start');
    expect(starts, hasLength(1));
    final payload = backend.payloads[backend.calls.indexOf('benchmark_start')];
    expect(payload['mode'], 'live');
    expect(payload['apiKey'], _key);
    expect(payload['baseUrl'], _base);
    expect(payload['prompt'], _prompt);
    expect(payload['resolvedProxy'], 'DIRECT');
    expect(payload['maxOutputTokens'], 256);
    expect(backend.calls, isNot(contains('proxy_for_url')));
    expect(controller.snapshot!.executionMode, 'live');
    expect(controller.keepAlive, true);
    final journal = jsonEncode(store.records.map((r) => r.toJson()).toList());
    for (final forbidden in [_key, _base, _prompt, 'apiKey', 'resolvedProxy']) {
      expect(journal, isNot(contains(forbidden)));
    }
    await controller.cancel();
    expect(controller.snapshot!.state, 'cancelled');
  });

  for (final action in ['cancel', 'interrupt', 'shutdown', 'restrict']) {
    test(
      '$action during delayed system proxy prevents eventual native Start',
      () async {
        final backend = _LiveBackend()..proxyGate = Completer<String>();
        final controller = BenchmarkController(
          BenchmarkService(backend),
          pollInterval: const Duration(days: 1),
        );
        addTearDown(controller.dispose);
        await _configure(controller, route: 'system');
        final start = controller.start();
        await backend.proxyStarted.future;
        expect(backend.payloads[backend.calls.indexOf('proxy_for_url')], {
          'url': '$_base/chat/completions',
        });
        controller.updateLiveConfig(_config.copy(model: 'changed-model'));
        controller.updateApiKey('changed-key');
        expect(controller.liveConfig.model, _config.model);
        expect(controller.apiKey, _key);
        Future<void> pending;
        if (action == 'restrict') {
          controller.restrictToOffline();
          pending = Future.value();
        } else {
          pending = action == 'cancel'
              ? controller.cancel()
              : action == 'interrupt'
              ? controller.interrupt()
              : controller.shutdown();
        }
        backend.proxyGate!.complete('DIRECT');
        await Future.wait([start, pending]);
        expect(backend.calls.where((c) => c == 'benchmark_start'), isEmpty);
        expect(controller.keepAlive, false);
        if (action == 'shutdown' || action == 'restrict') {
          expect(controller.apiKey, isEmpty);
        }
        if (action == 'restrict') {
          expect(controller.allowLive, false);
          expect(controller.executionMode, 'offline_replay');
          await controller.selectMode('live');
          expect(controller.executionMode, 'offline_replay');
        }
      },
    );
  }

  test('proxy failure is sanitized and does not fall back to direct', () async {
    final backend = _LiveBackend()..proxyGate = Completer<String>();
    final controller = BenchmarkController(BenchmarkService(backend));
    addTearDown(controller.dispose);
    await _configure(controller, route: 'system');
    final start = controller.start();
    await backend.proxyStarted.future;
    backend.proxyGate!.completeError(StateError('$_key $_base $_prompt'));
    await start;
    expect(backend.calls.where((c) => c == 'benchmark_start'), isEmpty);
    expect(controller.lastError, isNotNull);
    for (final forbidden in [_key, _base, _prompt]) {
      expect(controller.lastError, isNot(contains(forbidden)));
    }
  });

  test('late live start response still captures ownership and applies pending cancel', () async {
    final backend = _LiveBackend()
      ..pendingStart = Completer<Map<String, dynamic>>();
    final controller = BenchmarkController(
      BenchmarkService(backend),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await _configure(controller);
    final start = controller.start();
    await backend.startEntered.future;
    final cancel = controller.cancel();
    backend.pendingStart!.complete(_liveSnapshot());
    await Future.wait([start, cancel]);
    expect(controller.snapshot!.state, 'cancelled');
    expect(backend.payloads[backend.calls.indexOf('benchmark_cancel')], {
      'runId': 'run-1',
    });
    expect(controller.keepAlive, false);
  });

  test('invalid live snapshot retains native ownership for shutdown', () async {
    final backend = _LiveBackend()
      ..pendingStart = Completer<Map<String, dynamic>>();
    final controller = BenchmarkController(
      BenchmarkService(backend),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await _configure(controller);
    final start = controller.start();
    backend.pendingStart!.complete(_liveSnapshot()..['elapsedNs'] = -1);
    await start;
    expect(controller.lastError, isNotNull);
    await controller.shutdown();
    expect(backend.payloads[backend.calls.indexOf('benchmark_shutdown')], {
      'runId': 'run-1',
    });
    expect(controller.apiKey, isEmpty);
  });

  test('live starting intent restores interrupted without key config or native ownership', () async {
    final backend = _LiveBackend();
    final store = _MemoryStore(
      initial: const BenchmarkRecord(
        protocol: 'responses',
        scenarioId: '',
        executionMode: 'live',
        starting: true,
        attemptId: 'attempt-100',
      ),
    );
    final controller = BenchmarkController(
      BenchmarkService(backend),
      store: store,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.executionMode, 'live');
    expect(controller.snapshot!.state, 'interrupted');
    expect(controller.snapshot!.requestedModel, 'unknown');
    expect(controller.snapshot!.executionMode, 'live');
    expect(controller.snapshot!.runId, isNull);
    expect(controller.apiKey, isEmpty);
    expect(controller.liveConfig.valid, false);
    expect(controller.canStart, false);
    expect(controller.keepAlive, false);
    await controller.shutdown();
    expect(backend.calls, ['benchmark_catalog', 'benchmark_shutdown']);
    expect(backend.payloads.last, {'runId': null});
  });

  test(
    'offline capability blocks injected live owner and drops memory key',
    () async {
      final backend = _LiveBackend();
      final controller = BenchmarkController(
        BenchmarkService(backend),
        allowLive: false,
      );
      addTearDown(controller.dispose);
      await _configure(controller);
      expect(controller.executionMode, 'offline_replay');
      expect(controller.apiKey, isEmpty);
      expect(controller.liveConfig.valid, false);
      expect(backend.calls, ['benchmark_catalog']);
    },
  );
}
