import 'dart:async';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/services/global_workbench_store.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/global_workbench_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('refresh advances the time window across local midnight', () async {
    var clock = DateTime(2026, 10, 26, 23, 59, 58);
    final backend = GlobalFixtureBackend();
    final controller = GlobalWorkbenchController(
      service: GlobalWorkbenchService(backend),
      now: () => clock,
    );
    await controller.initialize();
    final previousStart = controller.query.fromMs!;
    clock = clock.add(const Duration(minutes: 2));
    await controller.refresh();
    expect(controller.query.toMs, clock.millisecondsSinceEpoch);
    expect(controller.query.fromMs, greaterThan(previousStart));
    await controller.shutdown();
    controller.dispose();
  });

  test(
    'unknown token counts stay unknown and malformed negatives fail closed',
    () {
      final json = globalSnapshotFixture();
      (json['totals'] as Map)['tokens'] = {
        'inputTokens': null,
        'outputTokens': 7,
      };
      final value = GlobalSnapshot.fromJson(json);
      expect(value.totals.tokens.inputTokens, isNull);
      expect(value.totals.tokens.outputTokens, 7);
      expect(value.totals.tokens.totalTokens, isNull);
      (json['totals'] as Map)['tokens'] = {'inputTokens': -1};
      expect(() => GlobalSnapshot.fromJson(json), throwsFormatException);
    },
  );

  test(
    'latest filter result wins while an older query is still pending',
    () async {
      final backend = GlobalFixtureBackend();
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
      );
      await controller.initialize();
      backend.holdQueries = true;
      final older = controller.setProject('old-project');
      final newer = controller.setProject('new-project');
      await Future<void>.delayed(Duration.zero);
      expect(backend.pendingQueries, hasLength(2));
      backend.pendingQueries[1].complete(globalSnapshotFixture(revision: 3));
      await newer;
      backend.pendingQueries[0].complete(globalSnapshotFixture(revision: 2));
      await older;
      expect(controller.snapshot?.revision, 3);
      expect(controller.query.project, 'new-project');
      await controller.shutdown();
      controller.dispose();
    },
  );

  test(
    'cached or observed running sessions do not keep the process alive',
    () async {
      final backend = GlobalFixtureBackend();
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
      );
      await controller.initialize();
      expect(controller.snapshot!.totals.states['running'], 2);
      expect(controller.keepAlive, isFalse);
      await controller.setBackgroundObservation(true);
      expect(controller.keepAlive, isTrue);
      await controller.setBackgroundObservation(false);
      expect(controller.keepAlive, isFalse);
      await controller.shutdown();
      controller.dispose();
    },
  );

  test('view preferences restore without storing session snapshots or enabling background', () async {
    final store = GlobalWorkbenchStore.memory();
    final first = GlobalWorkbenchController(
      service: GlobalWorkbenchService(GlobalFixtureBackend()),
      store: store,
    );
    await first.initialize();
    await first.setModel('synthetic-model-beta');
    await first.setRange(GlobalRange.days30);
    await first.shutdown();
    first.dispose();
    final second = GlobalWorkbenchController(
      service: GlobalWorkbenchService(GlobalFixtureBackend()),
      store: store,
    );
    await second.initialize();
    expect(second.query.model, 'synthetic-model-beta');
    expect(second.range, GlobalRange.days30);
    expect(second.keepAlive, isFalse);
    await second.shutdown();
    second.dispose();
  });

  test(
    'revision invalidation restarts pagination instead of mixing pages',
    () async {
      final backend = GlobalFixtureBackend();
      backend.snapshot = globalSnapshotFixture(hasMore: true);
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
      );
      await controller.initialize();
      backend.snapshot = {
        ...globalSnapshotFixture(revision: 2),
        'changed': true,
      };
      await controller.nextPage();
      expect(controller.query.offset, 0);
      expect(controller.snapshot!.revision, 2);
      expect(controller.error, isNull);
      await controller.shutdown();
      controller.dispose();
    },
  );

  test(
    'refresh advances the civil date window and preserves filters',
    () async {
      var now = DateTime(2026, 10, 26, 23, 59);
      final backend = GlobalFixtureBackend();
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
        now: () => now,
      );
      await controller.initialize();
      await controller.setProject('retained-project');
      now = DateTime(2026, 10, 27, 0, 1);
      await controller.refresh();
      expect(controller.query.toMs, now.millisecondsSinceEpoch);
      expect(
        controller.query.dayEdgesMs.last,
        DateTime(2026, 10, 28).millisecondsSinceEpoch,
      );
      expect(controller.query.project, 'retained-project');
      await controller.shutdown();
      controller.dispose();
    },
  );

  testWidgets(
    'suspension blocks scans even with explicit background observation',
    (tester) async {
      final backend = GlobalFixtureBackend();
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
        pollInterval: const Duration(seconds: 1),
      );
      await controller.initialize();
      await controller.setBackgroundObservation(true);
      await controller.suspend();
      final scans = backend.calls.where((c) => c['action'] == 'scan').length;
      await tester.pump(const Duration(seconds: 3));
      expect(backend.calls.where((c) => c['action'] == 'scan').length, scans);
      await controller.resume();
      expect(
        backend.calls.where((c) => c['action'] == 'scan').length,
        greaterThan(scans),
      );
      await controller.shutdown();
      controller.dispose();
    },
  );

  test('shutdown still closes the service after cancellation fails', () async {
    final backend = _CancelFailureBackend();
    final controller = GlobalWorkbenchController(
      service: GlobalWorkbenchService(backend),
    );
    await controller.initialize();
    await expectLater(controller.shutdown(), throwsStateError);
    expect(backend.actions, contains('shutdown'));
    controller.dispose();
  });

  test('shutdown drains delayed initialization before completing', () async {
    final backend = _DelayedCapabilitiesBackend();
    final controller = GlobalWorkbenchController(
      service: GlobalWorkbenchService(backend),
    );
    final initialization = controller.initialize();
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final shutdown = controller.shutdown().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    backend.gate.complete({
      'globalVersion': 1,
      'localReadOnly': true,
      'queryScans': false,
    });
    await initialization;
    await shutdown;
    expect(backend.actions, isNot(contains('scan')));
    controller.dispose();
  });
}

class _CancelFailureBackend implements LauncherBackend {
  final actions = <String>[];
  final delegate = GlobalFixtureBackend();
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    actions.add(payload['action'] as String);
    if (payload['action'] == 'cancel') {
      throw StateError('synthetic_cancel_failure');
    }
    return delegate.call(command, payload);
  }
}

class _DelayedCapabilitiesBackend implements LauncherBackend {
  final actions = <String>[];
  final gate = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    actions.add(payload['action'] as String);
    return payload['action'] == 'capabilities'
        ? gate.future
        : globalSnapshotFixture();
  }
}
