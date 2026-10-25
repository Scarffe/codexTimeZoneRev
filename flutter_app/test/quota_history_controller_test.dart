import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_store.dart';
import 'package:codex_timezone/state/quota_history_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'quota_history_projection_test.dart' as fixture;

void main() {
  test(
    'late projector errors are discarded and current errors recover on reload',
    () async {
      final projects = <Completer<QuotaHistoryProjection>>[];
      final controller = QuotaHistoryController(
        QuotaHistoryStore.memory(),
        read: (_) async => QuotaHistoryReadResult(records: []),
        projector: (_, _) {
          final pending = Completer<QuotaHistoryProjection>();
          projects.add(pending);
          return pending.future;
        },
      );
      final first = controller.load(fixture.filter());
      await Future<void>.delayed(Duration.zero);
      final second = controller.load(fixture.filter(duration: null));
      await Future<void>.delayed(Duration.zero);
      projects[1].complete(
        QuotaHistoryProjection(requiresSelection: false, sampleCount: 2),
      );
      await second;
      projects[0].completeError(StateError('late worker error'));
      await first;
      expect(controller.projection!.sampleCount, 2);
      expect(controller.error, isNull);
      final failed = controller.load(fixture.filter());
      await Future<void>.delayed(Duration.zero);
      projects[2].completeError(StateError('current worker error'));
      await failed;
      expect(controller.error, isNotNull);
      expect(controller.projection, isNull);
      expect(controller.isLoading, isFalse);
      final recovered = controller.load(fixture.filter());
      await Future<void>.delayed(Duration.zero);
      projects[3].complete(QuotaHistoryProjection(requiresSelection: false));
      await recovered;
      expect(controller.error, isNull);
      expect(controller.projection, isNotNull);
      controller.dispose();
    },
  );
  test(
    'late successful and failed reads cannot overwrite latest filter',
    () async {
      final reads = <Completer<QuotaHistoryReadResult>>[];
      final controller = QuotaHistoryController(
        QuotaHistoryStore.memory(),
        read: (_) {
          final pending = Completer<QuotaHistoryReadResult>();
          reads.add(pending);
          return pending.future;
        },
      );
      final first = controller.load(fixture.filter());
      final secondFilter = fixture.filter(duration: null);
      final second = controller.load(secondFilter);
      reads[1].complete(
        QuotaHistoryReadResult(records: [fixture.row(1, 0, duration: null)]),
      );
      await second;
      expect(controller.projection!.sampleCount, 1);
      expect(controller.filter, same(secondFilter));
      reads[0].completeError(StateError('old failure'));
      await first;
      expect(controller.error, isNull);
      final third = controller.load(fixture.filter());
      final fourth = controller.load(secondFilter);
      reads[3].complete(QuotaHistoryReadResult(records: []));
      await fourth;
      reads[2].complete(QuotaHistoryReadResult(records: [fixture.row(2, 120)]));
      await third;
      expect(controller.projection!.sampleCount, 0);
      controller.dispose();
    },
  );

  test(
    'file-backed projection runs without capturing unsendable listener state',
    () async {
      final dir = await Directory.systemTemp.createTemp('task3-history-');
      final port = RawReceivePort();
      final store = QuotaHistoryStore(dir, now: () => fixture.start);
      final controller = QuotaHistoryController(store);
      controller.addListener(() {
        port.hashCode;
      });
      try {
        await store.append(fixture.row(1, 0));
        await controller.load(fixture.filter());
        expect(controller.error, isNull);
        expect(controller.projection!.sampleCount, 1);
        expect(controller.isLoading, isFalse);
      } finally {
        controller.dispose();
        port.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'storage tail warning is retained and disposal discards a pending load',
    () async {
      final pending = Completer<QuotaHistoryReadResult>();
      final controller = QuotaHistoryController(
        QuotaHistoryStore.memory(),
        read: (_) => pending.future,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final load = controller.load(fixture.filter());
      expect(controller.isLoading, isTrue);
      controller.dispose();
      pending.complete(
        QuotaHistoryReadResult(records: [], hasStorageGaps: true),
      );
      await load;
      expect(notifications, 1);
      final warning = QuotaHistoryController(
        QuotaHistoryStore.memory(),
        read: (_) async =>
            QuotaHistoryReadResult(records: [], hasStorageGaps: true),
      );
      await warning.load(fixture.filter());
      expect(warning.hasStorageGaps, isTrue);
      expect(warning.error, isNull);
      warning.dispose();
    },
  );
}
