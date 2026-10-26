import 'dart:async';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/global_live.dart';
import 'package:codex_timezone/state/global_live_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> liveSnapshot({
  int generation = 3,
  bool connected = true,
}) => {
  'liveVersion': 1,
  'connected': connected,
  'coverage': connected ? 'partial' : 'unavailable',
  'initialGap': true,
  'dropped': 0,
  'generation': generation,
  'items': connected
      ? [
          {
            'threadId': 'thread-a',
            'turnId': 'turn-a',
            'state': 'running',
            'attention': 'approval_and_input',
            'observedAtMs': 100,
            'sequence': 9,
          },
          {
            'threadId': 'thread-b',
            'turnId': null,
            'state': 'failed',
            'attention': 'unknown',
            'observedAtMs': 90,
            'sequence': 8,
          },
        ]
      : [],
};

class RecordingLiveBackend implements LauncherBackend {
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> result = liveSnapshot();
  Completer<Map<String, dynamic>>? gate;
  bool fails = false;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add({'command': command, ...payload});
    if (fails) throw StateError('private raw transport failure');
    final pending = gate;
    if (pending != null) return pending.future;
    return result;
  }
}

void main() {
  test(
    'live service observes existing helper only and parses partial evidence',
    () async {
      final backend = RecordingLiveBackend();
      final data = await NativeGlobalLiveService(backend).status();
      expect(backend.calls, [
        {'command': 'global_live', 'action': 'status'},
      ]);
      expect(data.connected, isTrue);
      expect(data.initialGap, isTrue);
      expect(data.items.first.attention, 'approval_and_input');
      expect(data.items[1].attention, 'unknown');
    },
  );
  test('invalid live protocol cannot invent a completed thread', () {
    expect(
      () => GlobalLiveSnapshot.fromJson({...liveSnapshot(), 'liveVersion': 9}),
      throwsFormatException,
    );
    expect(
      () => GlobalLiveSnapshot.fromJson({
        ...liveSnapshot(),
        'items': [
          {
            'threadId': 'bad',
            'state': 'complete_guess',
            'attention': 'none',
            'sequence': 4,
            'observedAtMs': 12,
          },
        ],
      }),
      throwsFormatException,
    );
  });
  testWidgets(
    'live refresh follows visibility and explicit background policy',
    (tester) async {
      final backend = RecordingLiveBackend();
      final controller = GlobalLiveController(
        NativeGlobalLiveService(backend),
        pollInterval: const Duration(milliseconds: 10),
      );
      await controller.initialize();
      expect(controller.snapshot.items, hasLength(2));
      controller.setMainWindowVisible(false);
      await tester.pump(const Duration(milliseconds: 25));
      expect(backend.calls, hasLength(1));
      controller.setBackgroundObservation(true);
      await tester.pump(const Duration(milliseconds: 10));
      expect(backend.calls.length, greaterThan(1));
      await controller.shutdown();
      final count = backend.calls.length;
      await tester.pump(const Duration(milliseconds: 30));
      expect(backend.calls, hasLength(count));
      expect(backend.calls.every((c) => c['action'] == 'status'), isTrue);
      controller.dispose();
    },
  );
  test('disconnect clears observed rows and transport failure marks stale without fake completion', () async {
    final backend = RecordingLiveBackend();
    final controller = GlobalLiveController(NativeGlobalLiveService(backend));
    addTearDown(controller.dispose);
    await controller.refresh();
    backend.fails = true;
    await controller.refresh();
    expect(controller.stale, isTrue);
    expect(controller.snapshot.items.first.state, 'running');
    backend.fails = false;
    backend.result = liveSnapshot(generation: 4, connected: false);
    await controller.refresh();
    expect(controller.stale, isFalse);
    expect(controller.snapshot.generation, 4);
    expect(controller.snapshot.items, isEmpty);
    expect(controller.snapshot.coverage, 'unavailable');
  });
  test('dispose ignores a late live snapshot', () async {
    final backend = RecordingLiveBackend()
      ..gate = Completer<Map<String, dynamic>>();
    final controller = GlobalLiveController(NativeGlobalLiveService(backend));
    final pending = controller.refresh();
    controller.dispose();
    backend.gate!.complete(liveSnapshot());
    await pending;
    expect(backend.calls, hasLength(1));
    expect(controller.snapshot.items, isEmpty);
  });
}
