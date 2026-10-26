import 'dart:async';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/runtime_account.dart';
import 'package:codex_timezone/state/runtime_account_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> snapshot({
  String phase = 'unattached',
  String? sourceId,
  bool preparing = false,
  bool active = false,
  bool pending = false,
}) => {
  'runtimeVersion': 1,
  'supported': true,
  'connected': true,
  'phase': phase,
  'preparing': preparing,
  'sourceId': sourceId,
  'errorKind': null,
  'activeSourceRetained': active,
  'pendingSourceRetained': pending,
  'modelAttributionVerified': false,
  'inFlightMayUsePrevious': true,
};

class RecordingRuntimeBackend implements LauncherBackend {
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> result = snapshot();
  Completer<Map<String, dynamic>>? gate;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add({'command': command, ...payload});
    final pending = gate;
    if (pending != null) return pending.future;
    return Map<String, dynamic>.from(result);
  }
}

void main() {
  test(
    'native adapter forwards explicit switch and keeps identity scope narrow',
    () async {
      final backend = RecordingRuntimeBackend()
        ..result = {
          ...snapshot(phase: 'active', sourceId: 'profile-a', active: true),
          'principal': 'must-not-enter-ui',
          'modelAttributionVerified': true,
        };
      final state = await NativeRuntimeAccountService(backend)
          .request('switch', sourceId: 'profile-a');
      expect(backend.calls, [
        {
          'command': 'desktop_runtime',
          'action': 'switch',
          'sourceId': 'profile-a',
        },
      ]);
      expect(state.sourceId, 'profile-a');
      expect(state.phase, 'active');
      expect(state.modelAttributionVerified, isFalse);
      expect(state.inFlightMayUsePrevious, isTrue);
    },
  );

  test('offline native guard never reaches its delegate', () async {
    final backend = RecordingRuntimeBackend();
    final state = await NativeRuntimeAccountService(
      backend,
      offlineTrial: true,
    ).request('connect');
    expect(backend.calls, isEmpty);
    expect(state.connected, isFalse);
    expect(state.errorKind, 'offline_disabled');
  });

  test(
    'startup restores authoritative status without connect or switch',
    () async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(
          phase: 'active',
          sourceId: 'profile-restored',
          active: true,
        );
      final controller = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.initialize();
      expect(backend.calls, [
        {'command': 'desktop_runtime', 'action': 'status'},
      ]);
      expect(controller.status.sourceId, 'profile-restored');
      expect(controller.status.activeSourceRetained, isTrue);
    },
  );

  test('explicit source request polls pending status only a finite number of times', () async {
    final backend = RecordingRuntimeBackend()
      ..result = snapshot(
        phase: 'awaiting_confirmation',
        sourceId: 'profile-b',
        pending: true,
      );
    final controller = RuntimeAccountController(
      NativeRuntimeAccountService(backend),
      pollInterval: const Duration(milliseconds: 1),
      maxPolls: 2,
    );
    addTearDown(controller.dispose);
    await controller.useSource('profile-b');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(backend.calls.where((c) => c['action'] == 'switch').toList(), [
      {
        'command': 'desktop_runtime',
        'action': 'switch',
        'sourceId': 'profile-b',
      },
    ]);
    expect(backend.calls.where((c) => c['action'] == 'status').length, 2);
    expect(controller.status.phase, 'awaiting_confirmation');
  });

  test('cancel outranks a late pending poll response', () async {
    final backend = RecordingRuntimeBackend();
    final controller = RuntimeAccountController(
      NativeRuntimeAccountService(backend),
    );
    addTearDown(controller.dispose);
    await controller.connect();
    final gate = Completer<Map<String, dynamic>>();
    backend.gate = gate;
    final refresh = controller.refresh();
    backend.gate = null;
    backend.result = snapshot();
    await controller.cancel();
    gate.complete(
      snapshot(
        phase: 'awaiting_confirmation',
        sourceId: 'profile-late',
        pending: true,
      ),
    );
    await refresh;
    expect(backend.calls.map((c) => c['action']), [
      'connect',
      'status',
      'cancel',
    ]);
    expect(controller.status.sourceId, isNull);
    expect(controller.status.pendingSourceRetained, isFalse);
  });

  test(
    'dispose cancels polling without shutting down active token ownership',
    () async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(phase: 'awaiting_confirmation', pending: true);
      final controller = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
        pollInterval: const Duration(milliseconds: 5),
      );
      await controller.connect();
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(backend.calls.map((c) => c['action']), ['connect']);
    },
  );

  test(
    'graceful shutdown preserves retained helper but stops unowned helper once',
    () async {
      final retainedBackend = RecordingRuntimeBackend()
        ..result = snapshot(
          phase: 'active',
          sourceId: 'profile-a',
          active: true,
        );
      final retained = RuntimeAccountController(
        NativeRuntimeAccountService(retainedBackend),
      );
      addTearDown(retained.dispose);
      await retained.initialize();
      await retained.shutdown();
      expect(retainedBackend.calls.map((c) => c['action']), ['status']);
      final unownedBackend = RecordingRuntimeBackend();
      final unowned = RuntimeAccountController(
        NativeRuntimeAccountService(unownedBackend),
      );
      addTearDown(unowned.dispose);
      await unowned.initialize();
      await unowned.shutdown();
      await unowned.shutdown();
      expect(unownedBackend.calls.map((c) => c['action']), [
        'status',
        'stop_unowned',
      ]);
    },
  );

  test('synthetic runtime is self contained and switch requires an explicit action', () async {
    final service = SyntheticRuntimeAccountService();
    expect((await service.request('status')).connected, isFalse);
    expect((await service.request('connect')).phase, 'unattached');
    expect(
      (await service.request('switch', sourceId: 'profile-preview')).sourceId,
      'profile-preview',
    );
    expect((await service.request('status')).phase, 'active');
  });

  test(
    'pending target is local intent while sourceId remains committed account',
    () async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(
          phase: 'awaiting_confirmation',
          sourceId: 'profile-a',
          active: true,
          pending: true,
        );
      final controller = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
        maxPolls: 0,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.status.sourceId, 'profile-a');
      expect(controller.requestedSourceId, isNull);
      await controller.useSource('profile-b');
      expect(controller.status.sourceId, 'profile-a');
      expect(controller.requestedSourceId, 'profile-b');
    },
  );

  test(
    'unknown transport error is fixed and never overwrites retained identity',
    () async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(
          phase: 'active',
          sourceId: 'profile-a',
          active: true,
        );
      final controller = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      backend.result = {
        ...backend.result,
        'errorKind': 'secret-token-or-principal',
      };
      await controller.refresh();
      expect(controller.status.errorKind, 'unavailable');
      expect(controller.status.sourceId, 'profile-a');
      expect(controller.status.activeSourceRetained, isTrue);
    },
  );

  testWidgets(
    'an obsolete in-flight poll cannot create another timer after cancel',
    (tester) async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(phase: 'awaiting_confirmation', pending: true);
      final controller = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
        pollInterval: const Duration(milliseconds: 10),
        maxPolls: 1,
      );
      addTearDown(controller.dispose);
      await controller.connect();
      final gate = Completer<Map<String, dynamic>>();
      backend.gate = gate;
      await tester.pump(const Duration(milliseconds: 10));
      backend.gate = null;
      await controller.cancel();
      await tester.pump(const Duration(milliseconds: 5));
      gate.complete(snapshot(phase: 'awaiting_confirmation', pending: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 5));
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.calls.map((c) => c['action']), [
        'connect',
        'status',
        'cancel',
        'status',
      ]);
    },
  );

  for (final (kind, expectedTarget) in [
    ('busy', null),
    ('delivery_unresolved', 'profile-b'),
  ]) {
    test(
      'switch $kind distinguishes rejected intent from unknown delivery',
      () async {
        final backend = RecordingRuntimeBackend()
          ..result = {
            ...snapshot(
              phase: 'awaiting_confirmation',
              sourceId: 'profile-a',
              active: true,
              pending: true,
            ),
            'errorKind': kind,
          };
        final controller = RuntimeAccountController(
          NativeRuntimeAccountService(backend),
          maxPolls: 0,
        );
        addTearDown(controller.dispose);
        await controller.useSource('profile-b');
        expect(controller.status.sourceId, 'profile-a');
        expect(controller.status.pendingSourceRetained, isTrue);
        expect(controller.requestedSourceId, expectedTarget);
      },
    );
  }

  testWidgets(
    'restored pending preparation receives finite status polling without a write',
    (tester) async {
      final backend = RecordingRuntimeBackend()
        ..result = snapshot(phase: 'unattached', preparing: true);
      final controller = RuntimeAccountController(
        NativeRuntimeAccountService(backend),
        pollInterval: const Duration(milliseconds: 10),
        maxPolls: 2,
      );
      await controller.initialize();
      backend.result = snapshot(
        phase: 'active',
        sourceId: 'profile-restored',
        active: true,
      );
      await tester.pump(const Duration(milliseconds: 10));
      expect(controller.status.phase, 'active');
      expect(controller.status.sourceId, 'profile-restored');
      expect(backend.calls.map((c) => c['action']), ['status', 'status']);
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.calls, hasLength(2));
      controller.dispose();
    },
  );
}
