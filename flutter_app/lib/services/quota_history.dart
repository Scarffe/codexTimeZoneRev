import 'account_usage.dart';

enum QueryHistoryOutcome { success, noLimits, failure }

enum QuotaHistoryWindowQuality { valid, unknown }

enum QuotaHistoryHeatmapMetric { minimumRemaining, lastRemaining }

const quotaHistoryErrorKinds = {
  'invalid_source',
  'protected_source',
  'unavailable',
  'unsupported',
  'isolation_failed',
  'busy',
  'auth_required',
  'auth_failed',
  'timeout',
  'rate_limited',
  'network',
  'identity_changed',
  'cancelled',
  'not_found',
  'shutdown',
};

/// Immutable observation only: no account identity, display label or raw error.
class QuotaHistoryWindow {
  const QuotaHistoryWindow({
    required this.bucketId,
    required this.role,
    this.durationMinutes,
    this.usedPercent,
    this.resetsAtMs,
    required this.quality,
  });
  final String bucketId;
  final UsageWindowRole role;
  final int? durationMinutes, resetsAtMs;
  final double? usedPercent;
  final QuotaHistoryWindowQuality quality;
  Map<String, Object?> toJson() => {
    'bucketId': bucketId,
    'role': role.name,
    'durationMinutes': durationMinutes,
    'usedPercent': usedPercent,
    'resetsAtMs': resetsAtMs,
    'quality': quality.name,
  };
  factory QuotaHistoryWindow.fromJson(Map<String, dynamic> value) {
    final percent = value['usedPercent'];
    final duration = value['durationMinutes'];
    return QuotaHistoryWindow(
      bucketId: value['bucketId'] as String,
      role: UsageWindowRole.values.byName(value['role'] as String),
      durationMinutes: duration is int && duration > 0 ? duration : null,
      usedPercent:
          percent is num && percent.isFinite && percent >= 0 && percent <= 100
          ? percent.toDouble()
          : null,
      resetsAtMs: value['resetsAtMs'] as int?,
      quality: QuotaHistoryWindowQuality.values.byName(
        value['quality'] as String,
      ),
    );
  }
}

class QueryHistoryRecord {
  QueryHistoryRecord({
    this.schemaVersion = 1,
    required this.attemptId,
    required this.sourceId,
    required this.segmentId,
    required this.startedAtMs,
    required this.completedAtMs,
    required this.timeQuality,
    required this.expectedIntervalSec,
    required this.outcome,
    String? errorKind,
    required List<QuotaHistoryWindow> windows,
    this.storageGapBefore = false,
  }) : errorKind = errorKind == null
           ? null
           : (quotaHistoryErrorKinds.contains(errorKind)
                 ? errorKind
                 : 'unavailable'),
       windows = List.unmodifiable(windows);
  final int schemaVersion, startedAtMs, completedAtMs, expectedIntervalSec;
  final String attemptId, sourceId, segmentId;
  final UsageObservationTimeQuality timeQuality;
  final QueryHistoryOutcome outcome;
  final String? errorKind;
  final List<QuotaHistoryWindow> windows;

  /// Read-only corruption barrier; never serialized as a fabricated query.
  final bool storageGapBefore;
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'attemptId': attemptId,
    'sourceId': sourceId,
    'segmentId': segmentId,
    'startedAtMs': startedAtMs,
    'completedAtMs': completedAtMs,
    'timeQuality': timeQuality.name,
    'expectedIntervalSec': expectedIntervalSec,
    'outcome': outcome == QueryHistoryOutcome.noLimits
        ? 'no_limits'
        : outcome.name,
    if (errorKind != null) 'errorKind': errorKind,
    'windows': windows.map((w) => w.toJson()).toList(),
  };
  factory QueryHistoryRecord.fromJson(
    Map<String, dynamic> value, {
    bool storageGapBefore = false,
  }) {
    if (value['schemaVersion'] != 1 ||
        (value['expectedIntervalSec'] as int) <= 0 ||
        (value['attemptId'] as String).isEmpty ||
        (value['segmentId'] as String).isEmpty) {
      throw const FormatException('Invalid history record');
    }
    return QueryHistoryRecord(
      attemptId: value['attemptId'] as String,
      sourceId: value['sourceId'] as String,
      segmentId: value['segmentId'] as String,
      startedAtMs: value['startedAtMs'] as int,
      completedAtMs: value['completedAtMs'] as int,
      timeQuality: UsageObservationTimeQuality.values.byName(
        value['timeQuality'] as String,
      ),
      expectedIntervalSec: value['expectedIntervalSec'] as int,
      outcome: value['outcome'] == 'no_limits'
          ? QueryHistoryOutcome.noLimits
          : QueryHistoryOutcome.values.byName(value['outcome'] as String),
      errorKind: value['errorKind'] as String?,
      windows: [
        for (final w in value['windows'] as List)
          QuotaHistoryWindow.fromJson(w as Map<String, dynamic>),
      ],
      storageGapBefore: storageGapBefore,
    );
  }
}

/// Null duration is the unknown duration, not a cross-duration wildcard.
/// Unselected segment/bucket/role permits discovery, never merged plotting.
class QuotaHistoryFilter {
  const QuotaHistoryFilter({
    required this.sourceId,
    required this.fromUtc,
    required this.toUtc,
    this.segmentId,
    this.bucketId,
    this.role,
    this.durationMinutes,
    this.heatmapMetric = QuotaHistoryHeatmapMetric.minimumRemaining,
  });
  final String sourceId;
  final String? segmentId, bucketId;
  final UsageWindowRole? role;
  final int? durationMinutes;
  final DateTime fromUtc, toUtc;
  final QuotaHistoryHeatmapMetric heatmapMetric;
}

class QuotaHistoryReadResult {
  QuotaHistoryReadResult({
    required List<QueryHistoryRecord> records,
    this.hasStorageGaps = false,
  }) : records = List.unmodifiable(records);
  final List<QueryHistoryRecord> records;
  final bool hasStorageGaps;
}

abstract interface class QuotaHistorySink {
  Future<void> append(QueryHistoryRecord record);
  Future<void> removeSource(String sourceId);
  Future<void> flush();
}
