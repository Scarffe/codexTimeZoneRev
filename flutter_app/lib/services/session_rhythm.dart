import 'package:path/path.dart' as p;

class RhythmSource {
  const RhythmSource({
    required this.path,
    required this.sessionId,
    required this.title,
  });
  final String path, sessionId, title;
  String get key =>
      '${p.windows.normalize(path).toLowerCase()}\u0000$sessionId';
  Map<String, dynamic> toJson() => {
    'path': path,
    'sessionId': sessionId,
    'title': title,
  };
  factory RhythmSource.fromJson(Map<String, dynamic> json) => RhythmSource(
    path: json['path'] as String,
    sessionId: json['sessionId'] as String,
    title: json['title'] as String,
  );
}

enum RhythmRange { hours24, days7, days30 }

enum RhythmStatus { completed, cancelled, running, unknown }

class RhythmInterval {
  const RhythmInterval(this.startMs, this.endMs);
  final int startMs, endMs;
  int get durationMs => endMs - startMs;
  List<int> toJson() => [startMs, endMs];
}

class RhythmTurn {
  RhythmTurn({
    required this.sourceKey,
    required this.order,
    required this.turnId,
    required this.status,
    this.startedAtMs,
    this.completedAtMs,
    this.timeResolutionMs,
    this.durationMs,
    this.firstTokenMs,
    List<RhythmInterval> activityIntervals = const [],
    this.activityAvailable = false,
    this.partial = false,
    List<String> reasons = const [],
  }) : activityIntervals = List.unmodifiable(activityIntervals),
       reasons = List.unmodifiable(reasons);
  final String sourceKey, turnId;
  final int order;
  final RhythmStatus status;
  final int? startedAtMs,
      completedAtMs,
      timeResolutionMs,
      durationMs,
      firstTokenMs;
  final List<RhythmInterval> activityIntervals;
  final bool activityAvailable, partial;
  final List<String> reasons;
  factory RhythmTurn.fromJson(Map<String, dynamic> json, {String? sourceKey}) {
    final intervals = (json['activityIntervals'] as List).map((value) {
      if (value is! List || value.length != 2) {
        throw const FormatException('Invalid activity interval');
      }
      final a = _number(value[0]), b = _number(value[1]);
      if (b <= a) throw const FormatException('Invalid activity interval');
      return RhythmInterval(a, b);
    }).toList();
    final status = RhythmStatus.values
        .where((s) => s.name == json['status'])
        .firstOrNull;
    if (status == null ||
        json['activityAvailable'] is! bool ||
        json['partial'] is! bool) {
      throw const FormatException('Invalid rhythm fact');
    }
    return RhythmTurn(
      sourceKey: _string(sourceKey ?? json['sourceKey']),
      order: _number(json['order']),
      turnId: _string(json['turnId']),
      status: status,
      startedAtMs: _optionalNumber(json['startedAtMs']),
      completedAtMs: _optionalNumber(json['completedAtMs']),
      timeResolutionMs: _optionalNumber(json['timeResolutionMs']),
      durationMs: _optionalNumber(json['durationMs']),
      firstTokenMs: _optionalNumber(json['firstTokenMs']),
      activityIntervals: intervals,
      activityAvailable: json['activityAvailable'] as bool,
      partial: json['partial'] as bool,
      reasons: (json['reasons'] as List).map(_string).toList(),
    );
  }
  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'order': order,
    'turnId': turnId,
    'status': status.name,
    'startedAtMs': startedAtMs,
    'completedAtMs': completedAtMs,
    'timeResolutionMs': timeResolutionMs,
    'durationMs': durationMs,
    'firstTokenMs': firstTokenMs,
    'activityIntervals': activityIntervals.map((i) => i.toJson()).toList(),
    'activityAvailable': activityAvailable,
    'partial': partial,
    'reasons': reasons,
  };
}

class RhythmCache {
  RhythmCache({
    List<RhythmSource> sources = const [],
    List<RhythmTurn> turns = const [],
    Map<String, int> lastReadMs = const {},
    Set<String> truncatedSources = const {},
  }) : sources = List.unmodifiable(sources),
       turns = List.unmodifiable(turns),
       lastReadMs = Map.unmodifiable(lastReadMs),
       truncatedSources = Set.unmodifiable(truncatedSources);
  final List<RhythmSource> sources;
  final List<RhythmTurn> turns;
  final Map<String, int> lastReadMs;
  final Set<String> truncatedSources;
  factory RhythmCache.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported rhythm cache schema');
    }
    try {
      final sources = <String, RhythmSource>{};
      for (final source in json['sources'] as List) {
        final value = RhythmSource.fromJson(
          Map<String, dynamic>.from(source as Map),
        );
        if (value.path.isEmpty || value.sessionId.isEmpty) {
          throw const FormatException('Invalid rhythm source');
        }
        sources[value.key] = value;
      }
      if (sources.length > 8) {
        throw const FormatException('Too many rhythm sources');
      }
      final turns = <String, RhythmTurn>{};
      for (final fact in json['turns'] as List) {
        final value = RhythmTurn.fromJson(
          Map<String, dynamic>.from(fact as Map),
        );
        if (!sources.containsKey(value.sourceKey)) {
          throw const FormatException('Orphan rhythm fact');
        }
        turns['${value.sourceKey}\u0000${value.turnId}'] = value;
      }
      final read = Map<String, dynamic>.from(json['lastReadMs'] as Map);
      final lastRead = {for (final e in read.entries) e.key: _number(e.value)};
      final truncated = (json['truncatedSources'] as List).map(_string).toSet();
      if (!sources.keys.toSet().containsAll({...lastRead.keys, ...truncated})) {
        throw const FormatException('Orphan rhythm metadata');
      }
      return RhythmCache(
        sources: sources.values.toList(),
        turns: turns.values.toList(),
        lastReadMs: lastRead,
        truncatedSources: truncated,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid rhythm cache');
    }
  }
  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'sources': sources.map((s) => s.toJson()).toList(),
    'turns': turns.map((t) => t.toJson()).toList(),
    'lastReadMs': lastReadMs,
    'truncatedSources': truncatedSources.toList(),
  };
}

int _number(Object? value) {
  if (value is! int || value < 0 || value > 8640000000000000) {
    throw const FormatException('Invalid rhythm integer');
  }
  return value;
}

int? _optionalNumber(Object? value) => value == null ? null : _number(value);
String _string(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const FormatException('Invalid rhythm string');
  }
  return value;
}
