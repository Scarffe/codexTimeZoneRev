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

enum QuotaHistoryGapReason {
  unobserved,
  failure,
  noLimits,
  missingWindow,
  segmentChanged,
  clockReversal,
  runChanged,
  storage,
}

enum QuotaHistoryEventKind {
  usedIncrease,
  usedDecrease,
  reportedResetChanged,
  crossedReportedReset,
  queryFailure,
  noLimits,
  missingWindow,
  clockReversal,
}

/// Exact selector discovery, including the explicit unknown duration.
class QuotaHistorySeries {
  const QuotaHistorySeries(
    this.segmentId,
    this.bucketId,
    this.role,
    this.durationMinutes,
  );
  final String segmentId, bucketId;
  final UsageWindowRole role;
  final int? durationMinutes;
}

class QuotaHistoryPoint {
  const QuotaHistoryPoint({
    required this.attemptId,
    required this.completedAtUtc,
    required this.usedPercent,
    required this.spanId,
    required this.timeQuality,
    required this.expectedIntervalSec,
    this.resetsAtUtc,
  });
  final String attemptId;
  final DateTime completedAtUtc;
  final double usedPercent;
  double get remainingPercent => 100 - usedPercent;
  final int spanId, expectedIntervalSec;
  final UsageObservationTimeQuality timeQuality;
  final DateTime? resetsAtUtc;
}

/// One screen column, at most four actual observations (first/min/max/last).
/// If hasInternalGaps is true, render isolated observations plus a gap marker;
/// do not join these points. spanCount summarizes arbitrarily many raw spans.
class QuotaHistoryTrendSegment {
  QuotaHistoryTrendSegment({
    required this.column,
    required List<QuotaHistoryPoint> points,
    required this.spanCount,
    required this.hasInternalGaps,
    required this.connectToPrevious,
  }) : points = List.unmodifiable(points);
  final int column, spanCount;
  final List<QuotaHistoryPoint> points;
  final bool hasInternalGaps, connectToPrevious;
}

class QuotaHistoryGap {
  const QuotaHistoryGap(this.fromUtc, this.toUtc, this.reason);

  /// Always nonnegative interval. A zero-duration barrier is still a fact.
  final DateTime fromUtc, toUtc;
  final QuotaHistoryGapReason reason;
}

class QuotaHistoryEvent {
  const QuotaHistoryEvent({
    required this.kind,
    required this.fromUtc,
    required this.toUtc,
    this.deltaPercentagePoints,
    this.previousReportedResetUtc,
    this.reportedResetUtc,
    this.errorKind,
  });
  final QuotaHistoryEventKind kind;
  final DateTime fromUtc, toUtc;
  final double? deltaPercentagePoints;
  final DateTime? previousReportedResetUtc, reportedResetUtc;
  final String? errorKind;
}

class QuotaHistoryHourCell {
  const QuotaHistoryHourCell({
    required this.localDate,
    required this.localHour,
    required this.utcOffsetMinutes,
    required this.fromUtc,
    required this.toUtc,
    required this.sampleCount,
    required this.failureCount,
    required this.hasGap,
    this.observedRemaining,
    this.firstObservedUtc,
    this.lastObservedUtc,
  });
  final String localDate;
  final int localHour, utcOffsetMinutes, sampleCount, failureCount;
  final DateTime fromUtc, toUtc;
  final bool hasGap;

  /// Null means no valid observation, including hours containing only failures.
  final double? observedRemaining;
  final DateTime? firstObservedUtc, lastObservedUtc;
}

class QuotaHistoryProjection {
  QuotaHistoryProjection({
    required this.requiresSelection,
    List<String> availableSegmentIds = const [],
    List<QuotaHistorySeries> availableSeries = const [],
    List<QuotaHistoryTrendSegment> trendSegments = const [],
    List<QuotaHistoryHourCell> hourCells = const [],
    List<QuotaHistoryEvent> events = const [],
    List<QuotaHistoryGap> gaps = const [],
    this.sampleCount = 0,
    this.failureCount = 0,
    this.actualFromUtc,
    this.actualToUtc,
    this.firstObservedUtc,
    this.lastObservedUtc,
    this.minimumRemaining,
    this.maximumRemaining,
    this.latestPoint,
  }) : availableSegmentIds = List.unmodifiable(availableSegmentIds),
       availableSeries = List.unmodifiable(availableSeries),
       trendSegments = List.unmodifiable(trendSegments),
       hourCells = List.unmodifiable(hourCells),
       events = List.unmodifiable(events),
       gaps = List.unmodifiable(gaps);
  final bool requiresSelection;
  final List<String> availableSegmentIds;
  final List<QuotaHistorySeries> availableSeries;
  final List<QuotaHistoryTrendSegment> trendSegments;
  final List<QuotaHistoryHourCell> hourCells;
  final List<QuotaHistoryEvent> events;
  final List<QuotaHistoryGap> gaps;
  final int sampleCount, failureCount;

  /// Actual source completion range returned by the local reader.
  final DateTime? actualFromUtc, actualToUtc;
  final DateTime? firstObservedUtc, lastObservedUtc;
  final double? minimumRemaining, maximumRemaining;
  final QuotaHistoryPoint? latestPoint;
}
