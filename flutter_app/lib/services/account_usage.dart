import 'dart:math' as math;

import 'backend.dart';

class UsageWindow {
  const UsageWindow({this.usedPercent, this.durationMinutes, this.resetsAt});
  final double? usedPercent;
  final int? durationMinutes;
  final DateTime? resetsAt;

  factory UsageWindow.fromJson(Map<String, dynamic> json) {
    final percent = json['usedPercent'];
    final reset = json['resetsAt'];
    return UsageWindow(
      usedPercent: percent is num && percent.isFinite
          ? percent.toDouble().clamp(0, 100)
          : null,
      durationMinutes: json['windowDurationMins'] as int?,
      resetsAt: reset is int && reset > 0 && reset < 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true)
          : null,
    );
  }

  String get label {
    final minutes = durationMinutes;
    if (minutes == null || minutes <= 0) return '额度';
    if (minutes == 10080) return '周额度';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440} 天额度';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时额度';
    return '$minutes 分钟额度';
  }
}

class UsageBucket {
  const UsageBucket({
    required this.label,
    required this.windows,
    this.id = 'codex',
  });
  final String id;
  final String label;
  final List<UsageWindow> windows;
  factory UsageBucket.fromJson(String id, Map<String, dynamic> json) {
    final name = json['limitName'] as String?;
    return UsageBucket(
      id: id,
      label: name?.isNotEmpty == true ? name! : (id == 'codex' ? 'Codex' : id),
      windows: [
        for (final key in ['primary', 'secondary'])
          if (json[key] is Map<String, dynamic>)
            UsageWindow.fromJson(json[key] as Map<String, dynamic>),
      ],
    );
  }
}

class AccountUsage {
  const AccountUsage({
    required this.email,
    required this.plan,
    required this.buckets,
    required this.fetchedAt,
    this.lifetimeTokens,
    this.latestDailyTokens,
    this.latestDate,
    this.limitsError,
    this.tokensError,
    this.identityKey,
    this.detailsIncluded = true,
    this.tokensFetchedAt,
  });
  final String? email;
  final String? plan;
  final List<UsageBucket> buckets;
  final DateTime fetchedAt;
  final String? identityKey;
  final bool detailsIncluded;
  final DateTime? tokensFetchedAt;
  String get identity => identityKey ?? '$email|$plan';
  final int? lifetimeTokens, latestDailyTokens;
  final String? latestDate, limitsError, tokensError;

  /// Durable cache format, distinct from a fresh native RPC observation.
  Map<String, Object?> toCacheJson() => {
    'email': email, 'plan': plan, 'identityKey': identityKey,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
    'tokensFetchedAt': tokensFetchedAt?.millisecondsSinceEpoch,
    'detailsIncluded': detailsIncluded, 'lifetimeTokens': lifetimeTokens,
    'latestDailyTokens': latestDailyTokens, 'latestDate': latestDate,
    // Raw backend errors are intentionally excluded from durable state.
    'limitsUnavailable': limitsError != null,
    'tokensUnavailable': tokensError != null,
    'buckets': [
      for (final bucket in buckets)
        {
          'id': bucket.id,
          'label': bucket.label,
          'windows': [
            for (final window in bucket.windows)
              {
                'usedPercent': window.usedPercent,
                'durationMinutes': window.durationMinutes,
                'resetsAt': window.resetsAt?.millisecondsSinceEpoch,
              },
          ],
        },
    ],
  };

  factory AccountUsage.fromCacheJson(Map<String, dynamic> json) {
    DateTime? date(Object? value) => value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
    return AccountUsage(
      email: json['email'] as String?,
      plan: json['plan'] as String?,
      identityKey: json['identityKey'] as String?,
      fetchedAt: date(json['fetchedAt'])!,
      tokensFetchedAt: date(json['tokensFetchedAt']),
      detailsIncluded: json['detailsIncluded'] == true,
      lifetimeTokens: json['lifetimeTokens'] as int?,
      latestDailyTokens: json['latestDailyTokens'] as int?,
      latestDate: json['latestDate'] as String?,
      limitsError: json['limitsUnavailable'] == true ? '额度暂不可用' : null,
      tokensError: json['tokensUnavailable'] == true ? '用量暂不可用' : null,
      buckets: [
        for (final value in json['buckets'] as List)
          UsageBucket(
            id: value['id'] as String,
            label: value['label'] as String,
            windows: [
              for (final window in value['windows'] as List)
                UsageWindow(
                  usedPercent: (window['usedPercent'] as num?)?.toDouble(),
                  durationMinutes: window['durationMinutes'] as int?,
                  resetsAt: date(window['resetsAt']),
                ),
            ],
          ),
      ],
    );
  }

  factory AccountUsage.fromJson(Map<String, dynamic> json) {
    final account = json['account'] as Map<String, dynamic>;
    final limits = json['limits'] as Map<String, dynamic>?;
    final byId = limits?['rateLimitsByLimitId'] as Map<String, dynamic>?;
    final single = limits?['rateLimits'] as Map<String, dynamic>?;
    final tokens = json['tokenUsage'] as Map<String, dynamic>?;
    final summary = tokens?['summary'] as Map<String, dynamic>?;
    final daily = tokens?['dailyUsageBuckets'] as List?;
    final validDays = <({String date, int tokens})>[
      for (final day in daily ?? [])
        if (day is Map &&
            day['startDate'] is String &&
            RegExp(r'^\d{4}-\d{2}-\d{2}$')
                .hasMatch(day['startDate'] as String) &&
            day['tokens'] is int &&
            (day['tokens'] as int) >= 0)
          (date: day['startDate'] as String, tokens: day['tokens'] as int),
    ]..sort((a, b) => a.date.compareTo(b.date));
    final lifetime = summary?['lifetimeTokens'];
    return AccountUsage(
      email: account['email'] as String?,
      identityKey: json['identityKey'] as String?,
      detailsIncluded: json['detailsIncluded'] != false,
      tokensFetchedAt: json['detailsIncluded'] == false ? null : DateTime.now(),
      plan: account['planType'] as String?,
      buckets: [
        if (byId != null && byId.isNotEmpty) ...[
          for (final entry in byId.entries)
            if (entry.value is Map<String, dynamic>)
              UsageBucket.fromJson(
                entry.key,
                entry.value as Map<String, dynamic>,
              ),
        ] else if (single != null)
          UsageBucket.fromJson(single['limitId'] as String? ?? 'codex', single),
      ],
      lifetimeTokens: lifetime is int && lifetime >= 0 ? lifetime : null,
      latestDailyTokens: validDays.isEmpty ? null : validDays.last.tokens,
      latestDate: validDays.isEmpty ? null : validDays.last.date,
      limitsError: json['limitsError'] as String?,
      tokensError: json['tokensError'] as String?,
      fetchedAt: DateTime.now(),
    );
  }
}

AccountUsage retainUsageDetails(AccountUsage current, AccountUsage? previous) {
  if (current.detailsIncluded ||
      previous == null ||
      previous.identity != current.identity) {
    return current;
  }
  return AccountUsage(
    email: current.email,
    plan: current.plan,
    buckets: current.buckets,
    fetchedAt: current.fetchedAt,
    identityKey: current.identityKey,
    detailsIncluded: false,
    lifetimeTokens: previous.lifetimeTokens,
    latestDailyTokens: previous.latestDailyTokens,
    latestDate: previous.latestDate,
    tokensError: previous.tokensError,
    tokensFetchedAt: previous.tokensFetchedAt,
    limitsError: current.limitsError,
  );
}

String tokenCount(int? value) {
  if (value == null) return '暂无数据';
  return value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
}

String resetCountdown(DateTime? reset, DateTime now) {
  if (reset == null) return '重置时间暂不可用';
  final seconds = reset.difference(now).inSeconds;
  if (seconds <= 0) {
    return '已到重置时间，点击重新查询';
  }
  final minutes = math.max(1, (seconds / 60).ceil());
  if (minutes >= 1440) {
    return '${minutes ~/ 1440} 天 ${minutes % 1440 ~/ 60} 小时后重置';
  }
  if (minutes >= 60) return '${minutes ~/ 60} 小时 ${minutes % 60} 分钟后重置';
  return '$minutes 分钟后重置';
}

abstract interface class AccountUsageService {
  Future<AccountUsage> query(String desktopPath);
}

abstract interface class LimitsUsageService implements AccountUsageService {
  Future<AccountUsage> queryLimits(String desktopPath);
}

class NativeAccountUsageService implements LimitsUsageService {
  const NativeAccountUsageService(this.backend, {this.offlineTrial = false});
  final LauncherBackend backend;
  final bool offlineTrial;
  @override
  Future<AccountUsage> queryLimits(String desktopPath) async {
    if (offlineTrial) throw StateError('offline_trial_operation_disabled');
    return AccountUsage.fromJson(
      await backend.call('account_usage', {
        'path': desktopPath,
        'details': false,
      }),
    );
  }

  @override
  Future<AccountUsage> query(String desktopPath) async {
    if (offlineTrial) throw StateError('offline_trial_operation_disabled');
    return AccountUsage.fromJson(
      await backend.call('account_usage', {'path': desktopPath}),
    );
  }
}
