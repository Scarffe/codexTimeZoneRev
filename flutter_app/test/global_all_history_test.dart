import 'dart:async';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/global_workbench_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all history uses a revision-bound local query and keeps unknown-time totals', () async {
    // Omitting the second query is the regression: all history remains UTC.
    final backend = _AllHistoryBackend();
    final controller = GlobalWorkbenchController(
      service: GlobalWorkbenchService(backend),
    );
    try {
      await controller.initialize();
      backend.queries.clear();
      await controller.setRange(GlobalRange.all);
      expect(backend.queries, hasLength(2));
      final grouped = backend.queries.last;
      expect(grouped['expectedRevision'], 7);
      expect(grouped.containsKey('fromMs'), isFalse);
      expect(grouped.containsKey('toMs'), isFalse);
      final edges = (grouped['dayEdgesMs'] as List).cast<int>();
      expect(edges.length, inInclusiveRange(2, 91));
      for (final edge in edges) {
        final local = DateTime.fromMillisecondsSinceEpoch(edge);
        expect([local.hour, local.minute, local.second], [0, 0, 0]);
      }
      expect(controller.snapshot!.dailyBasis, 'local');
      expect(controller.snapshot!.totals.tokens.totalTokens, 1500);
      expect(controller.snapshot!.totals.unknownTime, 17);
      expect(controller.snapshot!.coverage.unsupported, 1);
      expect(controller.snapshot!.quality, 'partial');
      expect(controller.snapshot!.reasons, ['test-retained-quality']);
    } finally {
      await controller.shutdown();
      controller.dispose();
    }
  });

  test(
    'all history rediscovery expands edges and preserves filters on refresh',
    () async {
      final backend = _AllHistoryBackend();
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
        calendar: _utcCalendar,
      );
      try {
        await controller.initialize();
        await controller.setRange(GlobalRange.all);
        await controller.setProject('retained-project');
        await controller.setModel('retained-model');
        final before = List.of(controller.query.dayEdgesMs);
        backend.from = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
        backend.to = DateTime.utc(2027, 1, 1).millisecondsSinceEpoch;
        backend.revision = 8;
        backend.queries.clear();
        await controller.refresh();
        expect(backend.queries, hasLength(2));
        expect(backend.queries.first.containsKey('dayEdgesMs'), isFalse);
        expect(controller.query.dayEdgesMs.first, lessThan(before.first));
        expect(controller.query.dayEdgesMs.last, greaterThan(before.last));
        expect(controller.query.dayEdgesMs.length, lessThanOrEqualTo(91));
        expect(controller.snapshot!.dailyBucketDays, 5);
        expect(controller.query.project, 'retained-project');
        expect(controller.query.model, 'retained-model');
        expect(controller.query.fromMs, isNull);
        expect(controller.query.toMs, isNull);
      } finally {
        await controller.shutdown();
        controller.dispose();
      }
    },
  );

  test('unknown-time-only data keeps totals and a local empty chart without a second query', () async {
    final backend = _AllHistoryBackend()..emptyDays = true;
    final controller = GlobalWorkbenchController(
      service: GlobalWorkbenchService(backend),
    );
    try {
      await controller.initialize();
      backend.queries.clear();
      await controller.setRange(GlobalRange.all);
      expect(backend.queries, hasLength(1));
      expect(controller.snapshot!.daily, isEmpty);
      expect(controller.snapshot!.dailyBasis, 'local');
      expect(controller.snapshot!.totals.tokens.totalTokens, 1500);
      expect(controller.snapshot!.totals.unknownTime, 17);
      expect(controller.snapshot!.projects, isNotEmpty);
    } finally {
      await controller.shutdown();
      controller.dispose();
    }
  });

  for (final holdProbe in [true, false]) {
    test(
      'late ${holdProbe ? "extent" : "local"} response never replaces a newer filter or edges',
      () async {
        final backend = _AllHistoryBackend();
        final controller = GlobalWorkbenchController(
          service: GlobalWorkbenchService(backend),
          calendar: _utcCalendar,
        );
        try {
          await controller.initialize();
          await controller.setRange(GlobalRange.all);
          final gate = Completer<Map<String, dynamic>>();
          Map<String, dynamic>? held;
          backend.onQuery = (query, result) async {
            final extent = query['dayEdgesMs'] == null;
            if (query['project'] == 'old' && extent == holdProbe) {
              held = result;
              return gate.future;
            }
            if (query['project'] == 'new') {
              (result['totals'] as Map)['tokens'] = globalTokensFixture(
                1200,
                333,
              );
            }
            return result;
          };
          // A refresh clears all-history boundaries and exercises the probe gate.
          if (holdProbe) {
            await controller.setProject('old');
          }
          final old = holdProbe
              ? controller.refresh()
              : controller.setProject('old');
          await Future<void>.delayed(Duration.zero);
          expect(held, isNotNull);
          final utcPublications = <String>[];
          controller.addListener(
            () => utcPublications.add(controller.snapshot!.dailyBasis),
          );
          await controller.setProject('new');
          final expectedEdges = List.of(controller.query.dayEdgesMs);
          gate.complete(held!);
          await old;
          expect(controller.query.project, 'new');
          expect(controller.query.dayEdgesMs, expectedEdges);
          expect(controller.snapshot!.totals.tokens.outputTokens, 333);
          expect(utcPublications, isNot(contains('utc')));
        } finally {
          await controller.shutdown();
          controller.dispose();
        }
      },
    );
  }

  test(
    'changed local-page revision resets pagination and rediscovers extent',
    () async {
      final backend = _AllHistoryBackend()..hasMore = true;
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
        calendar: _utcCalendar,
      );
      try {
        await controller.initialize();
        await controller.setRange(GlobalRange.all);
        backend.queries.clear();
        backend.onQuery = (query, result) async {
          if (query['offset'] == 50) {
            backend.revision = 8;
            backend.to = DateTime.utc(2027, 1, 1).millisecondsSinceEpoch;
            return {
              ...result,
              'revision': 8,
              'changed': true,
              'daily': [],
              'sessions': [],
            };
          }
          return result;
        };
        await controller.nextPage();
        expect(backend.queries, hasLength(3));
        expect(backend.queries[1].containsKey('dayEdgesMs'), isFalse);
        expect(backend.queries.last['expectedRevision'], 8);
        expect(controller.query.offset, 0);
        expect(controller.snapshot!.revision, 8);
        expect(
          controller.query.dayEdgesMs.last,
          DateTime.utc(2027, 1, 1).millisecondsSinceEpoch,
        );
      } finally {
        await controller.shutdown();
        controller.dispose();
      }
    },
  );

  test('repeated revision changes retain the previous observation and stop retrying', () async {
    final backend = _AllHistoryBackend();
    final controller = GlobalWorkbenchController(
      service: GlobalWorkbenchService(backend),
    );
    try {
      await controller.initialize();
      final previous = controller.snapshot;
      backend.queries.clear();
      backend.onQuery = (query, result) async {
        if (query['expectedRevision'] != null) {
          backend.revision++;
          return {
            ...result,
            'revision': backend.revision,
            'changed': true,
            'daily': [],
            'sessions': [],
          };
        }
        return result;
      };
      await controller.setRange(GlobalRange.all);
      expect(backend.queries, hasLength(6));
      expect(controller.snapshot, same(previous));
      expect(controller.error, isNotNull);
    } finally {
      await controller.shutdown();
      controller.dispose();
    }
  });
  test(
    'scan success does not hide a failed all-history query during refresh',
    () async {
      final backend = _AllHistoryBackend();
      final controller = GlobalWorkbenchController(
        service: GlobalWorkbenchService(backend),
      );
      try {
        await controller.initialize();
        await controller.setRange(GlobalRange.all);
        final previous = controller.snapshot;
        backend.onQuery = (query, result) async {
          if (query['expectedRevision'] != null) {
            backend.revision++;
            return {
              ...result,
              'revision': backend.revision,
              'changed': true,
              'daily': [],
              'sessions': [],
            };
          }
          return result;
        };
        await controller.refresh();
        expect(controller.snapshot, same(previous));
        expect(
          controller.error,
          isNotNull,
          reason: 'a successful scan cannot erase the failed coherent query',
        );
      } finally {
        await controller.shutdown();
        controller.dispose();
      }
    },
  );
}

final _utcCalendar = RhythmCalendar(
  toLocal: (t) => t.toUtc(),
  localDate: DateTime.utc,
);

class _AllHistoryBackend implements LauncherBackend {
  final delegate = GlobalFixtureBackend();
  final queries = <Map<String, dynamic>>[];
  int from = DateTime.utc(2026, 10, 26).millisecondsSinceEpoch;
  int to = DateTime.utc(2026, 10, 28).millisecondsSinceEpoch;
  int revision = 7;
  bool emptyDays = false, hasMore = false;
  Future<Map<String, dynamic>> Function(
    Map<String, dynamic>,
    Map<String, dynamic>,
  )?
  onQuery;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (payload['action'] != 'query') return delegate.call(command, payload);
    queries.add(Map.of(payload));
    final edges = (payload['dayEdgesMs'] as List?)?.cast<int>() ?? [];
    final result = globalSnapshotFixture(
      revision: revision,
      hasMore: hasMore,
      offset: payload['offset'] as int? ?? 0,
    );
    result['dailyBasis'] = edges.isEmpty ? 'utc' : 'civil';
    result['dailyBucketDays'] = 1;
    result['quality'] = 'partial';
    result['reasons'] = ['test-retained-quality'];
    (result['totals'] as Map)['unknownTime'] = 17;
    result['daily'] = [
      {
        'key': 'extent',
        'fromMs': edges.isEmpty ? from : edges.first,
        'toMs': edges.isEmpty ? to : edges.last,
        'tokens': globalTokensFixture(1200, 300),
        'sessions': 203,
      },
    ];
    if (emptyDays) result['daily'] = [];
    return onQuery == null ? result : onQuery!(payload, result);
  }
}
