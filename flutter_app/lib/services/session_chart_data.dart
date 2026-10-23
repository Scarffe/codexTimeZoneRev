import 'session_activity_timeline.dart';
import 'session_measurement_quality.dart';

int? _safeInteger(Object? value) =>
    SessionActivityTimelineData.isSafeMilliseconds(value) ? value as int : null;

bool _hasText(Object? value) => value is String && value.trim().isNotEmpty;

Map<String, dynamic>? _stringMap(Object? value) =>
    value is Map && value.keys.every((key) => key is String)
    ? Map<String, dynamic>.from(value)
    : null;

bool _sameFields(List<Object?> a, List<Object?> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Keeps raw window positions so invalid records cannot pull in older samples.
/// Conflicting identities never publish a preferred version of the evidence.
List<T?> _window<T>(
  Object? value, {
  required int limit,
  required String identityKey,
  required List<Object?> Function(Map<String, dynamic>) fields,
  required T? Function(Map<String, dynamic>) parse,
}) {
  if (value is! List) return const [];
  final samples = <T?>[];
  final identities = <String, int>{};
  final evidence = <String, List<Object?>>{};
  final conflicts = <String>{};
  for (final raw in value.take(limit)) {
    final row = _stringMap(raw);
    final id = row?[identityKey];
    if (row == null || !_hasText(id)) {
      samples.add(null);
      continue;
    }
    final identity = id as String;
    final previous = identities[identity];
    final currentFields = fields(row);
    if (previous != null) {
      if (!_sameFields(evidence[identity]!, currentFields)) {
        conflicts.add(identity);
        samples[previous] = null;
      }
      samples.add(null);
      continue;
    }
    identities[identity] = samples.length;
    evidence[identity] = currentFields;
    samples.add(conflicts.contains(identity) ? null : parse(row));
  }
  return List.unmodifiable(samples);
}

/// Content-free display facts from one controller snapshot, with no cache.
class SessionChartData {
  const SessionChartData._({
    required this.catchingUp,
    required List<TerminalChartSample?> terminals,
    required this.responses,
    required this.activities,
    required this.coverage,
    required this.usageMatchesTurn,
    required this.timeline,
  }) : _terminals = terminals;

  factory SessionChartData.fromData(Map<String, dynamic>? data) {
    final catchingUp = data?['catchingUp'] == true;
    final last = catchingUp ? null : _stringMap(data?['last']);
    final analysis = _stringMap(last?['analysis']);
    final timeline = SessionActivityTimelineData.fromAnalysis(analysis);
    final terminals = _window<TerminalChartSample>(
      catchingUp ? null : data?['terminals'],
      limit: 64,
      identityKey: 'turnId',
      fields: (row) => [row['status'], row['durationMs']],
      parse: (row) => const ['completed', 'cancelled'].contains(row['status'])
          ? TerminalChartSample(
              id: row['turnId'] as String,
              status: row['status'] as String,
              durationMs: _safeInteger(row['durationMs']),
            )
          : null,
    );
    final responses = _window<ResponseChartSample>(
      analysis?['recentResponses'],
      limit: 12,
      identityKey: 'responseId',
      fields: (row) => [row['outputTokens'], row['reasoningTokens']],
      parse: (row) {
        final output = _safeInteger(row['outputTokens']);
        final reasoning = _safeInteger(row['reasoningTokens']);
        return ResponseChartSample(
          id: row['responseId'] as String,
          outputTokens: output,
          reasoningTokens:
              output != null && reasoning != null && reasoning > output
              ? null
              : reasoning,
        );
      },
    );
    final activities = <ActivityDurationSample>[
      if (analysis != null)
        for (final category in const {
          'message': '消息',
          'reasoning': '推理',
          'tool': '工具',
          'other': '其他',
        }.entries)
          ActivityDurationSample(
            category: category.key,
            label: category.value,
            milliseconds: _safeInteger(analysis['${category.key}Ms']),
          ),
    ];
    final observed = _safeInteger(analysis?['observedMs']);
    final unclassified = _safeInteger(analysis?['unclassifiedMs']);
    final duration = _safeInteger(last?['durationMs']);
    final canPublishCoverage =
        timeline.available &&
        timeline.coverageInterpretation == 'approximate' &&
        !timeline.sourcePartial &&
        timeline.omittedItems == 0 &&
        analysis?['coverageValid'] == true &&
        analysis?['partial'] != true &&
        observed != null &&
        unclassified != null &&
        duration != null &&
        observed <= duration &&
        // Subtraction also avoids overflow in an intermediate integer sum.
        unclassified == duration - observed;
    return SessionChartData._(
      catchingUp: catchingUp,
      terminals: terminals,
      responses: List.unmodifiable(
        responses.reversed.whereType<ResponseChartSample>(),
      ),
      activities: List.unmodifiable(activities),
      coverage: canPublishCoverage
          ? CoverageChartSample(
              observedMs: observed,
              unclassifiedMs: unclassified,
              durationMs: duration,
            )
          : null,
      usageMatchesTurn: analysis?['usageMatchesTurn'] is bool
          ? analysis!['usageMatchesTurn'] as bool
          : null,
      timeline: timeline,
    );
  }

  final bool catchingUp;
  final List<TerminalChartSample?> _terminals;
  final List<ResponseChartSample> responses;
  final List<ActivityDurationSample> activities;
  final CoverageChartSample? coverage;
  final bool? usageMatchesTurn;
  final SessionActivityTimelineData timeline;

  List<TerminalChartSample> recentTerminals(int limit) => limit <= 0
      ? const []
      : List.unmodifiable(
          _terminals
              .take(limit)
              .toList()
              .reversed
              .whereType<TerminalChartSample>(),
        );
}

class TerminalChartSample {
  const TerminalChartSample({
    required this.id,
    required this.status,
    required this.durationMs,
  });
  final String id, status;
  final int? durationMs;
  bool get cancelled => status == 'cancelled';
}

class ResponseChartSample {
  const ResponseChartSample({
    required this.id,
    required this.outputTokens,
    required this.reasoningTokens,
  });
  final String id;
  final int? outputTokens, reasoningTokens;
  int? get nonReasoningTokens =>
      outputTokens != null &&
          reasoningTokens != null &&
          reasoningTokens! <= outputTokens!
      ? outputTokens! - reasoningTokens!
      : null;
}

class ActivityDurationSample {
  const ActivityDurationSample({
    required this.category,
    required this.label,
    required this.milliseconds,
  });
  final String category, label;
  final int? milliseconds;
}

class CoverageChartSample {
  const CoverageChartSample({
    required this.observedMs,
    required this.unclassifiedMs,
    required this.durationMs,
  });
  final int observedMs, unclassifiedMs, durationMs;
}

class ConfigurationChartSample {
  const ConfigurationChartSample({
    required this.model,
    required this.effort,
    required this.serviceTier,
    required this.turnCount,
    required this.outputTokens,
    required this.durationMs,
    required this.tokensPerSecond,
  });
  final String model, effort, serviceTier;
  final int turnCount, outputTokens, durationMs;
  final double tokensPerSecond;
  String get label => '$model · $effort · $serviceTier';

  /// Historical groups remain independent from the latest turn's quality.
  static List<ConfigurationChartSample> fromQuality(
    SessionMeasurementQuality quality,
  ) {
    final samples = <ConfigurationChartSample?>[];
    final identities = <(String, String, String, String), int>{};
    final evidence = <(String, String, String, String), List<Object?>>{};
    for (final row in quality.verifiedGroups) {
      final output = _safeInteger(row['outputTokens']);
      final duration = _safeInteger(row['durationMs']);
      final count = _safeInteger(row['turnCount']);
      final rate = row['tokensPerSecond'];
      if (![
            'sessionId',
            'model',
            'effort',
            'serviceTier',
          ].every((key) => _hasText(row[key])) ||
          output == null ||
          duration == null ||
          duration == 0 ||
          count == null ||
          count == 0 ||
          rate is! num ||
          !rate.isFinite ||
          rate < 0) {
        continue;
      }
      final expected = output / duration * 1000;
      if (!expected.isFinite ||
          (rate - expected).abs() > .000001 * (expected.abs() + 1)) {
        continue;
      }
      final identity = (
        row['sessionId'] as String,
        row['model'] as String,
        row['effort'] as String,
        row['serviceTier'] as String,
      );
      final fields = <Object?>[count, output, duration];
      final previous = identities[identity];
      if (previous != null) {
        if (!_sameFields(evidence[identity]!, fields)) samples[previous] = null;
        continue;
      }
      identities[identity] = samples.length;
      evidence[identity] = fields;
      samples.add(
        ConfigurationChartSample(
          model: identity.$2,
          effort: identity.$3,
          serviceTier: identity.$4,
          turnCount: count,
          outputTokens: output,
          durationMs: duration,
          tokensPerSecond: expected,
        ),
      );
    }
    return List.unmodifiable(samples.whereType<ConfigurationChartSample>());
  }
}
