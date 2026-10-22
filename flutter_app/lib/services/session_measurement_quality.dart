/// Evidence supplied by the read-only local collector, never a decoding speed.
class SessionMeasurementQuality {
  SessionMeasurementQuality._({
    required this.status,
    required this.reasons,
    required this.verifiedTokensPerSecond,
    required this.reportedTokensPerSecond,
    required this.sourceLabel,
    required this.verifiedGroups,
  });

  final String status;
  final List<String> reasons;
  final double? verifiedTokensPerSecond, reportedTokensPerSecond;
  final String sourceLabel;
  final List<Map<String, dynamic>> verifiedGroups;

  String get label => switch (status) {
    'verified' => '已核验',
    'reported_only' => '日志报告值 · 未充分核验',
    'conflict' => '证据冲突',
    'unsupported' => '暂不支持核验',
    _ => '核验信息不完整',
  };

  static const _statuses = {
    'verified',
    'reported_only',
    'incomplete',
    'conflict',
    'unsupported',
  };
  static const _explanations = {
    'missing_usage': '缺少回合用量',
    'invalid_usage': '回合用量格式无效',
    'missing_duration': '缺少完整回合耗时',
    'invalid_duration': '完整回合耗时无效',
    'missing_identity': '缺少可核对的会话或回合标识',
    'missing_request_evidence': '缺少逐请求用量证据',
    'usage_mismatch': '请求用量与回合用量不一致',
    'invalid_bounds': '计时范围无法核对',
    'conflicting_terminal': '回合结束记录存在冲突',
    'conflicting_usage': '重复用量记录存在冲突',
    'conflicting_item': '重复响应内容存在冲突',
    'unsupported_token_schema': '当前日志用量格式暂不支持核验',
    'no_completed_turn': '尚无已结束回合',
    'incomplete_history': '会话历史尚未完整读取',
  };
  static const _unknown = '核验信息不完整，暂无法核验';

  static Map? _map(Object? value) => value is Map ? value : null;
  static double? _rate(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;
  static bool _text(Object? value) =>
      value is String && value.trim().isNotEmpty;
  static bool _quality(Map? value) =>
      value != null &&
      _statuses.contains(value['status']) &&
      value['reasons'] is List &&
      (value['reasons'] as List).every((reason) => reason is String);
  static bool _ratio(Map value, String key) {
    final output = value['outputTokens'], duration = value['durationMs'];
    final rate = _rate(value[key]);
    if (output is! int ||
        output < 0 ||
        duration is! int ||
        duration <= 0 ||
        rate == null) {
      return false;
    }
    final expected = output / duration * 1000;
    return expected.isFinite &&
        (rate - expected).abs() <= .000001 * (expected.abs() + 1);
  }

  factory SessionMeasurementQuality.fromData(Map<String, dynamic>? data) {
    final last = _map(data?['last']);
    final raw = _rate(last?['tokensPerSecond']);
    final overall = _map(data?['quality']);
    final sample = _map(last?['quality']);
    final measurement = _map(data?['measurement']);
    final validQuality = _quality(overall) && _quality(sample);
    var status = _quality(overall)
        ? overall!['status'] as String
        : raw != null
        ? 'reported_only'
        : 'incomplete';
    final codes = <String>{
      if (_quality(overall)) ...(overall!['reasons'] as List).cast<String>(),
      if (_quality(sample)) ...(sample!['reasons'] as List).cast<String>(),
    };
    // A conflict in either scope always prevents numeric publication.
    for (final candidate in [
      'conflict',
      'unsupported',
      'incomplete',
      'reported_only',
    ]) {
      if (overall?['status'] == candidate || sample?['status'] == candidate) {
        status = candidate;
        break;
      }
    }
    final recognized =
        measurement?['kind'] == 'observed_turn' &&
        measurement?['tokenSource'] == 'turn_token_usage.output_tokens' &&
        measurement?['durationSource'] == 'task_complete.duration_ms' &&
        measurement?['outputIncludesReasoning'] == true &&
        _text(measurement?['sessionId']) &&
        _text(measurement?['sourceLabel']);
    final verified =
        validQuality &&
        status == 'verified' &&
        sample!['status'] == 'verified' &&
        codes.isEmpty &&
        recognized &&
        data?['catchingUp'] != true &&
        last != null &&
        _ratio(last, 'verifiedTokensPerSecond');
    if (status == 'verified' && !verified) status = 'incomplete';
    final groups = <Map<String, dynamic>>[];
    final values = data?['verifiedGroups'];
    if (recognized && validQuality && values is List) {
      for (final value in values) {
        if (value is! Map || value.keys.any((key) => key is! String)) continue;
        if (value['sessionId'] != measurement!['sessionId'] ||
            ![
              'sessionId',
              'model',
              'effort',
              'serviceTier',
            ].every((key) => _text(value[key])) ||
            value['turnCount'] is! int ||
            (value['turnCount'] as int) <= 0 ||
            !_ratio(value, 'tokensPerSecond')) {
          continue;
        }
        groups.add(
          Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(value)),
        );
      }
    }
    return SessionMeasurementQuality._(
      status: status,
      reasons: List.unmodifiable({
        for (final code in codes) _explanations[code] ?? _unknown,
        if (!verified && codes.isEmpty) _unknown,
      }),
      verifiedTokensPerSecond: verified
          ? _rate(last['verifiedTokensPerSecond'])
          : null,
      reportedTokensPerSecond: raw,
      sourceLabel: _text(measurement?['sourceLabel'])
          ? measurement!['sourceLabel'] as String
          : '所选 Codex 会话 · 本地只读日志',
      verifiedGroups: List.unmodifiable(groups),
    );
  }
}
