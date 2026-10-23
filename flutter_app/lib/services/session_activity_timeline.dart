/// A fail-closed, content-free projection of persisted activity intervals.
class SessionActivityTimelineData {
  const SessionActivityTimelineData._({
    required this.available,
    this.rows = const [],
    this.spanMs,
    this.sourcePartial = false,
    this.omittedItems = 0,
    this.coverageInterpretation = 'unavailable',
  });

  factory SessionActivityTimelineData.fromAnalysis(
    Map<String, dynamic>? analysis,
  ) {
    const unavailable = SessionActivityTimelineData._(available: false);
    final t = analysis?['timeline'];
    if (t is! Map ||
        t['version'] is! int ||
        t['version'] != 1 ||
        t['coordinateKind'] != 'logged_turn_window' ||
        t['boundsResolutionMs'] is! int ||
        t['boundsResolutionMs'] != 1000 ||
        t['limit'] is! int ||
        t['limit'] != 200 ||
        t['order'] != 'start_end_id' ||
        t['sourcePartial'] is! bool ||
        !const [
          'approximate',
          'unavailable',
        ].contains(t['coverageInterpretation'])) {
      return unavailable;
    }
    for (final key in ['startEpochMs', 'endEpochMsExclusive', 'spanMs']) {
      if (!t.containsKey(key) ||
          (t[key] != null && !isSafeMilliseconds(t[key]))) {
        return unavailable;
      }
    }
    final start = t['startEpochMs'] as int?;
    final end = t['endEpochMsExclusive'] as int?;
    final span = t['spanMs'] as int?;
    final hasBounds =
        start != null &&
        end != null &&
        span != null &&
        end > start &&
        end - start == span;
    if (!hasBounds && (start != null || end != null || span != null)) {
      return unavailable;
    }
    for (final key in ['totalItems', 'shownItems', 'omittedItems']) {
      if (!isSafeMilliseconds(t[key])) return unavailable;
    }
    final total = t['totalItems'] as int;
    final shown = t['shownItems'] as int;
    final omitted = t['omittedItems'] as int;
    final items = t['items'];
    if (items is! List ||
        items.length > 200 ||
        shown != items.length ||
        shown != (total > 200 ? 200 : total) ||
        total - shown != omitted ||
        (t['coverageInterpretation'] == 'approximate' &&
            (!hasBounds || t['sourcePartial'] == true || omitted != 0))) {
      return unavailable;
    }
    final rows = <SessionActivityTimelineRow>[];
    int? previousStart, previousEnd;
    var missingStartSeen = false;
    for (final value in items) {
      if (value is! Map ||
          value['ordinal'] is! int ||
          value['ordinal'] != rows.length + 1 ||
          !const [
            'message',
            'reasoning',
            'tool',
            'other',
          ].contains(value['category']) ||
          value['drawable'] is! bool) {
        return unavailable;
      }
      for (final key in [
        'startedAtMs',
        'completedAtMs',
        'offsetStartMs',
        'offsetEndMs',
        'durationMs',
      ]) {
        if (!value.containsKey(key) ||
            (value[key] != null && !isSafeMilliseconds(value[key]))) {
          return unavailable;
        }
      }
      final reasons = value['reasons'];
      if (reasons is! List ||
          reasons.length > 32 ||
          reasons.any((r) => r is! String || r.isEmpty || r.length > 80)) {
        return unavailable;
      }
      final row = SessionActivityTimelineRow._(
        ordinal: value['ordinal'] as int,
        category: value['category'] as String,
        startedAtMs: value['startedAtMs'] as int?,
        completedAtMs: value['completedAtMs'] as int?,
        offsetStartMs: value['offsetStartMs'] as int?,
        offsetEndMs: value['offsetEndMs'] as int?,
        durationMs: value['durationMs'] as int?,
        drawable: value['drawable'] as bool,
        reasons: List<String>.unmodifiable(reasons.cast<String>()),
      );
      final rs = row.startedAtMs, re = row.completedAtMs;
      final recordedDuration = rs != null && re != null && re >= rs
          ? re - rs
          : null;
      if (row.durationMs != recordedDuration) return unavailable;
      if (rs == null) {
        missingStartSeen = true;
      } else {
        if (missingStartSeen ||
            (previousStart != null &&
                (rs < previousStart ||
                    (rs == previousStart &&
                        re != null &&
                        (previousEnd == null || re < previousEnd))))) {
          return unavailable;
        }
        previousStart = rs;
        previousEnd = re;
      }
      // Never repair/clamp offsets or reinterpret a non-drawable record.
      if (row.offsetStartMs != null &&
          (!hasBounds ||
              rs == null ||
              rs < start ||
              rs > end ||
              row.offsetStartMs != rs - start)) {
        return unavailable;
      }
      if (row.offsetEndMs != null &&
          (!hasBounds ||
              re == null ||
              re < start ||
              re > end ||
              row.offsetEndMs != re - start)) {
        return unavailable;
      }
      if (row.drawable &&
          (!hasBounds ||
              rs == null ||
              re == null ||
              re <= rs ||
              rs < start ||
              re > end ||
              row.offsetStartMs == null ||
              row.offsetEndMs == null ||
              row.durationMs != re - rs)) {
        return unavailable;
      }
      rows.add(row);
    }
    return SessionActivityTimelineData._(
      available: true,
      rows: List.unmodifiable(rows),
      spanMs: span,
      sourcePartial: t['sourcePartial'] as bool,
      omittedItems: omitted,
      coverageInterpretation: t['coverageInterpretation'] as String,
    );
  }

  static bool isSafeMilliseconds(Object? value) =>
      value is int && value >= 0 && value <= 9007199254740991;

  final bool available;
  final List<SessionActivityTimelineRow> rows;
  final int? spanMs;
  final int boundsResolutionMs = 1000;
  final bool sourcePartial;
  final int omittedItems;
  final String coverageInterpretation;
  String get reasonText => available
      ? '日志项活动可重叠；时间轴为秒级边界的近似窗口。'
      : '时间线不可用：旧版内核、缺少数据或格式无法核验；上方耗时汇总仍可独立使用。';
}

class SessionActivityTimelineRow {
  const SessionActivityTimelineRow._({
    required this.ordinal,
    required this.category,
    required this.startedAtMs,
    required this.completedAtMs,
    required this.offsetStartMs,
    required this.offsetEndMs,
    required this.durationMs,
    required this.drawable,
    required this.reasons,
  });
  final int ordinal;
  final String category;
  final int? startedAtMs, completedAtMs, offsetStartMs, offsetEndMs, durationMs;
  final bool drawable;
  final List<String> reasons;
  String get categoryLabel => const {
    'message': '消息',
    'reasoning': '推理',
    'tool': '工具',
    'other': '其他',
  }[category]!;
  String get label => '$categoryLabel #$ordinal';
  String get reasonText => reasons
      .map(
        (r) =>
            const {
              'missing_start': '缺少开始时间',
              'missing_end': '缺少结束时间',
              'reversed': '起止倒序',
              'zero_duration': '零时长（不绘制条形）',
              'outside_bounds': '超出回合窗口',
              'missing_turn_bounds': '缺少回合边界',
              'overflow': '时间超出可核验范围',
            }[r] ??
            '其他无法核验的时间信息',
      )
      .toSet()
      .join('；');
}
