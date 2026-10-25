import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/quota_history.dart';
import 'package:codex_timezone/services/quota_history_projection.dart';
import 'package:codex_timezone/services/quota_history_store.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/quota_history_controller.dart';

import 'multi_account_fixture.dart';

final historyNow = DateTime.utc(2026, 10, 25, 12);
QueryHistoryRecord historyRecord(
  int n, {
  String segment = 'current-segment',
  String source = 'profile-primary',
  double? used = 25,
  int? minutesAgo,
  bool failed = false,
}) {
  final time = historyNow.subtract(
    Duration(minutes: minutesAgo ?? 120 - n * 2),
  );
  return QueryHistoryRecord(
    attemptId: 'synthetic:$n',
    sourceId: source,
    segmentId: segment,
    startedAtMs: time.millisecondsSinceEpoch - 100,
    completedAtMs: time.millisecondsSinceEpoch,
    timeQuality: UsageObservationTimeQuality.nativeCompletion,
    expectedIntervalSec: 120,
    outcome: failed ? QueryHistoryOutcome.failure : QueryHistoryOutcome.success,
    errorKind: failed ? 'network' : null,
    windows: failed
        ? []
        : [
            QuotaHistoryWindow(
              bucketId: 'Codex',
              role: UsageWindowRole.primary,
              durationMinutes: 300,
              usedPercent: used,
              resetsAtMs: historyNow
                  .add(const Duration(hours: 3))
                  .millisecondsSinceEpoch,
              quality: QuotaHistoryWindowQuality.valid,
            ),
            QuotaHistoryWindow(
              bucketId: 'Codex',
              role: UsageWindowRole.secondary,
              durationMinutes: 10080,
              usedPercent: 60,
              quality: QuotaHistoryWindowQuality.valid,
            ),
          ],
  );
}

class HistoryFixture {
  HistoryFixture._(this.owner, this.service, this.controller, this.records);
  final AccountSourcesController owner;
  final SyntheticMultiSources service;
  final QuotaHistoryController controller;
  final List<QueryHistoryRecord> records;
  static Future<HistoryFixture> create({
    List<QueryHistoryRecord>? records,
    bool emptyOwner = false,
    bool storageGaps = false,
    bool readError = false,
    String current = 'current-segment',
    DateTime Function()? now,
    SyntheticMultiSources? sourceService,
  }) async {
    final service = sourceService ?? SyntheticMultiSources();
    final store = AccountSourceStore.memory();
    await store.write({
      'selectedId': 'profile-primary',
      'pinnedId': 'profile-primary',
      'sources': emptyOwner
          ? []
          : [
              for (final id in ['profile-primary', 'profile-second'])
                {
                  'id': id,
                  'alias': id == 'profile-primary' ? '主账号' : '研究来源',
                  'generation': 0,
                  'historySegmentId': current,
                  'usage': service.sample(id).toCacheJson(),
                },
            ],
    });
    final owner = AccountSourcesController(
      service,
      store,
      offlineTrial: true,
      now: now ?? () => historyNow,
    );
    await owner.initialize(() => '');
    for (final state in owner.states) {
      state.historySegmentId = current;
      state.historyNeedsNewSegment = false;
    }
    final rows =
        records ??
        [
          historyRecord(0, segment: 'old-segment', minutesAgo: 360, used: 80),
          for (var i = 1; i < 20; i++)
            historyRecord(i, used: i == 10 ? 12 : 30 + i * .75, failed: i == 8),
          historyRecord(20, minutesAgo: 1, used: 48.1234),
        ];
    final controller = QuotaHistoryController(
      QuotaHistoryStore.memory(now: () => historyNow),
      read: (filter) async {
        if (readError) throw StateError('synthetic denied');
        return QuotaHistoryReadResult(
          records: rows
              .where(
                (r) =>
                    r.sourceId == filter.sourceId &&
                    r.completedAtMs >= filter.fromUtc.millisecondsSinceEpoch &&
                    r.completedAtMs <= filter.toUtc.millisecondsSinceEpoch,
              )
              .toList(),
          hasStorageGaps: storageGaps,
        );
      },
      projector: (result, filter) =>
          projectQuotaHistory(result.records, filter, toDisplayTime: (t) => t),
    );
    return HistoryFixture._(owner, service, controller, rows);
  }

  void dispose() {
    controller.dispose();
    owner.dispose();
  }
}
