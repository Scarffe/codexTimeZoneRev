/// Metadata-only views of the native global index. Unknown measurements stay null.
class GlobalTokens {
  const GlobalTokens({
    this.inputTokens,
    this.cachedInputTokens,
    this.cacheWriteInputTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.totalTokens,
  });
  final int? inputTokens,
      cachedInputTokens,
      cacheWriteInputTokens,
      outputTokens,
      reasoningTokens,
      totalTokens;
  factory GlobalTokens.fromJson(Object? value) {
    final json = _map(value);
    return GlobalTokens(
      inputTokens: _optionalInt(json['inputTokens']),
      cachedInputTokens: _optionalInt(json['cachedInputTokens']),
      cacheWriteInputTokens: _optionalInt(json['cacheWriteInputTokens']),
      outputTokens: _optionalInt(json['outputTokens']),
      reasoningTokens: _optionalInt(json['reasoningTokens']),
      totalTokens: _optionalInt(json['totalTokens']),
    );
  }
  int? metric(String name) => switch (name) {
    'inputTokens' => inputTokens,
    'cachedInputTokens' => cachedInputTokens,
    'outputTokens' => outputTokens,
    _ => totalTokens,
  };
}

class GlobalCoverage {
  const GlobalCoverage({
    this.discovered = 0,
    this.indexed = 0,
    this.pending = 0,
    this.unreadable = 0,
    this.unsupported = 0,
    this.missing = 0,
  });
  final int discovered, indexed, pending, unreadable, unsupported, missing;
  factory GlobalCoverage.fromJson(Object? value) {
    final json = _map(value);
    return GlobalCoverage(
      discovered: _count(json['discovered']),
      indexed: _count(json['indexed']),
      pending: _count(json['pending']),
      unreadable: _count(json['unreadable']),
      unsupported: _count(json['unsupported']),
      missing: _count(json['missing']),
    );
  }
  bool get partial =>
      pending > 0 || unreadable > 0 || unsupported > 0 || missing > 0;
}

class GlobalTotals {
  GlobalTotals({
    required this.tokens,
    required this.sessions,
    required Map<String, int> states,
    required Map<String, int?> attention,
    required this.staleRunning,
    this.quality = 'unavailable',
    this.excludedConflicts = 0,
    this.unknownTime = 0,
  }) : states = Map.unmodifiable(states),
       attention = Map.unmodifiable(attention);
  final GlobalTokens tokens;
  final int sessions, staleRunning;
  final String quality;
  final int excludedConflicts, unknownTime;
  bool get partial =>
      quality == 'partial' || quality == 'conflict' || excludedConflicts > 0;
  final Map<String, int> states;
  final Map<String, int?> attention;
  int? get attentionCount {
    final known = [
      'input',
      'approval',
      'tool_pending',
    ].map((k) => attention[k]).toList();
    return known.any((v) => v == null)
        ? null
        : known.fold<int>(0, (a, b) => a + b!);
  }

  factory GlobalTotals.fromJson(Object? value) {
    final json = _map(value),
        states = _map(_map(value)['states']),
        attention = _map(_map(value)['attention']);
    return GlobalTotals(
      tokens: GlobalTokens.fromJson(json['tokens']),
      sessions: _count(json['sessions']),
      states: {
        for (final key in [
          'running',
          'completed',
          'cancelled',
          'failed',
          'unknown',
        ])
          key: _count(states[key]),
      },
      attention: {
        for (final key in ['input', 'approval', 'tool_pending', 'unknown'])
          key: _optionalInt(attention[key]),
      },
      staleRunning: _count(json['staleRunning']),
      quality: _text(json['quality']),
      excludedConflicts: _count(json['excludedConflicts']),
      unknownTime: _count(json['unknownTime']),
    );
  }
}

class GlobalBucket {
  const GlobalBucket({
    required this.key,
    required this.tokens,
    required this.sessions,
    this.fromMs,
    this.toMs,
  });
  final String key;
  final GlobalTokens tokens;
  final int sessions;
  final int? fromMs, toMs;
  factory GlobalBucket.fromJson(Object? value) {
    final json = _map(value);
    return GlobalBucket(
      key: _text(json['key']),
      tokens: GlobalTokens.fromJson(json['tokens']),
      sessions: _count(json['sessions']),
      fromMs: _optionalInt(json['fromMs']),
      toMs: _optionalInt(json['toMs']),
    );
  }
}

class GlobalSessionRow {
  GlobalSessionRow({
    required this.path,
    required this.threadId,
    required this.sessionId,
    required this.project,
    required this.model,
    required this.lifecycleState,
    required this.attentionState,
    required this.freshness,
    required this.tokens,
    required this.basis,
    required this.quality,
    required this.canOpenDetail,
    this.title,
    this.lastEventMs,
    List<String> reasons = const [],
  }) : reasons = List.unmodifiable(reasons);
  final String path,
      threadId,
      sessionId,
      project,
      model,
      lifecycleState,
      attentionState,
      freshness,
      basis,
      quality;
  final GlobalTokens tokens;
  final int? lastEventMs;
  final List<String> reasons;
  final bool canOpenDetail;
  final String? title;
  String get key => '$path\u0000$threadId\u0000$sessionId';
  String get shortId =>
      threadId.length > 20 ? '${threadId.substring(0, 17)}…' : threadId;
  factory GlobalSessionRow.fromJson(Object? value) {
    final json = _map(value);
    final lifecycle = _text(json['lifecycleState']),
        attention = _text(json['attentionState']),
        freshness = _text(json['freshness']);
    if (!{
          'running',
          'completed',
          'cancelled',
          'failed',
          'unknown',
        }.contains(lifecycle) ||
        !{
          'none',
          'tool_pending',
          'input',
          'approval',
          'unknown',
        }.contains(attention) ||
        !{'fresh', 'stale', 'missing', 'unreadable'}.contains(freshness) ||
        json['canOpenDetail'] is! bool) {
      throw const FormatException('invalid_global_session_state');
    }
    return GlobalSessionRow(
      path: _text(json['path']),
      threadId: _text(json['threadId']),
      title: json['title'] is String ? (json['title'] as String).trim() : null,
      sessionId: _text(json['sessionId']),
      project: _text(json['project']),
      model: _text(json['model']),
      lifecycleState: lifecycle,
      attentionState: attention,
      freshness: freshness,
      lastEventMs: _optionalInt(json['lastEventMs']),
      tokens: GlobalTokens.fromJson(json['tokens']),
      basis: _description(json['basis']),
      quality: _description(json['quality']),
      reasons: _strings(json['reasons']),
      canOpenDetail: json['canOpenDetail'] as bool,
    );
  }
}

class GlobalSnapshot {
  GlobalSnapshot({
    required this.revision,
    required this.indexEpoch,
    required this.phase,
    required this.observedAtMs,
    required this.restored,
    required this.coverage,
    required this.totals,
    required this.filteredCount,
    required this.offset,
    required this.hasMore,
    this.changed = false,
    this.dailyBasis = 'local',
    this.dailyBucketDays = 1,
    this.quality = 'unavailable',
    this.conflicts = 0,
    List<String> roots = const [],
    List<GlobalBucket> daily = const [],
    List<GlobalBucket> projects = const [],
    List<GlobalBucket> models = const [],
    List<GlobalSessionRow> sessions = const [],
    List<String> warnings = const [],
    List<String> reasons = const [],
  }) : roots = List.unmodifiable(roots),
       daily = List.unmodifiable(daily),
       projects = List.unmodifiable(projects),
       models = List.unmodifiable(models),
       sessions = List.unmodifiable(sessions),
       warnings = List.unmodifiable(warnings),
       reasons = List.unmodifiable(reasons);
  final int revision, indexEpoch, observedAtMs, filteredCount, offset;
  final String phase;
  final bool restored, hasMore, changed;
  final String dailyBasis;
  final String quality;
  final int conflicts;
  final int dailyBucketDays;
  final List<String> roots, warnings, reasons;
  final GlobalCoverage coverage;
  final GlobalTotals totals;
  final List<GlobalBucket> daily, projects, models;
  final List<GlobalSessionRow> sessions;
  bool get partial =>
      phase == 'partial' ||
      coverage.partial ||
      totals.partial ||
      quality == 'partial' ||
      conflicts > 0 ||
      warnings.isNotEmpty;

  /// The native explicit-edge path reports measurements unchanged; the client
  /// owns the calendar step used to label those edge-defined groups.
  GlobalSnapshot withCivilBuckets(int bucketDays) => GlobalSnapshot(
    revision: revision,
    indexEpoch: indexEpoch,
    phase: phase,
    observedAtMs: observedAtMs,
    restored: restored,
    coverage: coverage,
    totals: totals,
    filteredCount: filteredCount,
    offset: offset,
    hasMore: hasMore,
    changed: changed,
    dailyBasis: 'local',
    dailyBucketDays: bucketDays,
    quality: quality,
    conflicts: conflicts,
    roots: roots,
    daily: daily,
    projects: projects,
    models: models,
    sessions: sessions,
    warnings: warnings,
    reasons: reasons,
  );
  factory GlobalSnapshot.fromJson(Map<String, dynamic> json) {
    final phase = _text(json['phase']);
    if (!{'empty', 'scanning', 'ready', 'partial'}.contains(phase)) {
      throw const FormatException('invalid_global_phase');
    }
    return GlobalSnapshot(
      revision: _count(json['revision']),
      indexEpoch: _count(json['indexEpoch']),
      phase: phase,
      observedAtMs: _count(json['observedAtMs']),
      restored: json['restored'] == true,
      roots: _strings(json['roots']),
      coverage: GlobalCoverage.fromJson(json['coverage']),
      totals: GlobalTotals.fromJson(json['totals']),
      daily: _list(json['daily']).map(GlobalBucket.fromJson).toList(),
      projects: _list(json['projects']).map(GlobalBucket.fromJson).toList(),
      models: _list(json['models']).map(GlobalBucket.fromJson).toList(),
      sessions: _list(json['sessions']).map(GlobalSessionRow.fromJson).toList(),
      filteredCount: _count(json['filteredCount']),
      offset: _count(json['offset']),
      hasMore: json['hasMore'] == true,
      changed: json['changed'] == true,
      dailyBasis: json['dailyBasis'] == 'utc' ? 'utc' : 'local',
      dailyBucketDays: _optionalInt(json['dailyBucketDays']) ?? 1,
      warnings: _strings(json['warnings']),
      quality: _text(json['quality']),
      conflicts: _count(json['conflicts']),
      reasons: _strings(json['reasons']),
    );
  }
}

enum GlobalRange { today, days7, days30, all }

class GlobalQuery {
  const GlobalQuery({
    this.fromMs,
    this.toMs,
    this.dayEdgesMs = const [],
    this.project,
    this.model,
    this.status,
    this.search = '',
    this.sort = 'recent',
    this.offset = 0,
    this.limit = 50,
  });
  final int? fromMs, toMs;
  final List<int> dayEdgesMs;
  final String? project, model, status;
  final String search, sort;
  final int offset, limit;
  Map<String, dynamic> toJson({int? expectedRevision}) => {
    'action': 'query',
    if (fromMs != null) 'fromMs': fromMs,
    if (toMs != null) 'toMs': toMs,
    if (dayEdgesMs.isNotEmpty) 'dayEdgesMs': dayEdgesMs,
    if (project != null) 'project': project,
    if (model != null) 'model': model,
    if (status != null) 'status': status,
    if (search.isNotEmpty) 'search': search,
    'sort': sort,
    'offset': offset,
    'limit': limit,
    'expectedRevision': ?expectedRevision,
  };
  GlobalQuery copyWith({
    List<int>? dayEdgesMs,
    String? project,
    String? model,
    String? status,
    String? search,
    String? sort,
    int? offset,
    bool clearProject = false,
    bool clearModel = false,
    bool clearStatus = false,
  }) => GlobalQuery(
    fromMs: fromMs,
    toMs: toMs,
    dayEdgesMs: dayEdgesMs ?? this.dayEdgesMs,
    project: clearProject ? null : project ?? this.project,
    model: clearModel ? null : model ?? this.model,
    status: clearStatus ? null : status ?? this.status,
    search: search ?? this.search,
    sort: sort ?? this.sort,
    offset: offset ?? this.offset,
    limit: limit,
  );
}

Map<String, dynamic> _map(Object? value) {
  if (value == null) return const {};
  if (value is! Map) throw const FormatException('invalid_global_object');
  return Map<String, dynamic>.from(value);
}

List<dynamic> _list(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('invalid_global_list');
  return value;
}

List<String> _strings(Object? value) => _list(value).map(_text).toList();
String _text(Object? value) {
  if (value == null) return '';
  if (value is! String) throw const FormatException('invalid_global_text');
  return value;
}

String _description(Object? value) =>
    value is List ? value.map(_text).join(' · ') : _text(value);
int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw const FormatException('invalid_global_count');
  }
  return value;
}

int _count(Object? value) => _optionalInt(value) ?? 0;
