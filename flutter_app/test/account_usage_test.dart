import 'dart:async';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> usageResponse() => {
  'account': {'email': 'tester@example.com', 'planType': 'plus'},
  'limits': {
    'rateLimitsByLimitId': {
      'codex': {
        'primary': {
          'usedPercent': 8,
          'windowDurationMins': 300,
          'resetsAt': 1791981390,
        },
        'secondary': {
          'usedPercent': 5,
          'windowDurationMins': 10080,
          'resetsAt': 1792477941,
        },
      },
      'other': {
        'limitName': '独立额度',
        'primary': {
          'usedPercent': 42,
          'windowDurationMins': 60,
          'resetsAt': null,
        },
      },
    },
    'rateLimits': {
      'primary': {'usedPercent': 99},
    },
  },
  'tokenUsage': {
    'summary': {'lifetimeTokens': 1234567},
    'dailyUsageBuckets': [
      {'startDate': '2026-10-14', 'tokens': 12345},
      {'startDate': '2026-10-12', 'tokens': 2},
    ],
  },
};

class PendingUsage implements AccountUsageService {
  int calls = 0;
  String? path;
  Completer<AccountUsage> pending = Completer();
  @override
  Future<AccountUsage> query(String desktopPath) {
    calls++;
    path = desktopPath;
    return pending.future;
  }
}

class UsageBackend implements LauncherBackend {
  String? command;
  Map<String, dynamic>? payload;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    this.command = command;
    this.payload = payload;
    return usageResponse();
  }
}

void main() {
  test(
    'reads multiple buckets, epoch seconds, and most recent daily statistic',
    () {
      final data = AccountUsage.fromJson(usageResponse());
      expect(data.buckets.map((b) => b.label), ['Codex', '独立额度']);
      expect(data.buckets.first.windows.map((w) => w.label), ['5 小时额度', '周额度']);
      expect(
        data.buckets.first.windows.first.resetsAt!.millisecondsSinceEpoch,
        1791981390000,
      );
      expect(data.latestDate, '2026-10-14');
      expect(data.latestDailyTokens, 12345);
      expect(tokenCount(data.lifetimeTokens), '1,234,567');
    },
  );

  test('old single bucket and null statistics remain usable without fabricated zero', () {
    final response = usageResponse();
    final limits = Map<String, dynamic>.from(response['limits'] as Map);
    limits['rateLimitsByLimitId'] = null;
    response['limits'] = limits;
    response['tokenUsage'] = {
      'summary': {'lifetimeTokens': null},
      'dailyUsageBuckets': null,
    };
    final data = AccountUsage.fromJson(response);
    expect(data.buckets, hasLength(1));
    expect(data.buckets.first.windows.first.usedPercent, 99);
    expect(data.lifetimeTokens, isNull);
    expect(data.latestDailyTokens, isNull);
    expect(tokenCount(null), '暂无数据');
    expect(tokenCount(0), '0');
  });

  test('clamps percentages and never claims reset has recovered the quota', () {
    expect(UsageWindow.fromJson({'usedPercent': 200}).usedPercent, 100);
    expect(UsageWindow.fromJson({'usedPercent': -1}).usedPercent, 0);
    final now = DateTime.utc(2026, 10, 14);
    expect(
      resetCountdown(now.subtract(const Duration(minutes: 1)), now),
      '已到重置时间，点击重新查询',
    );
    expect(resetCountdown(now.add(const Duration(seconds: 1)), now), '1 分钟后重置');
    expect(resetCountdown(null, now), '重置时间暂不可用');
  });

  test('only an explicit query calls native backend', () async {
    final backend = UsageBackend();
    final service = NativeAccountUsageService(backend);
    expect(backend.command, isNull);
    await service.query(r'C:\Codex\Codex.exe');
    expect(backend.command, 'account_usage');
    expect(backend.payload, {'path': r'C:\Codex\Codex.exe'});
  });

  test('manual query deduplicates clicks and clears previous account on refresh failure', () async {
    final service = PendingUsage();
    final controller = AccountUsageController(service);
    addTearDown(controller.dispose);
    expect(service.calls, 0);
    final first = controller.query('desktop');
    await controller.query('desktop');
    expect(service.calls, 1);
    expect(controller.busy, isTrue);
    service.pending.complete(AccountUsage.fromJson(usageResponse()));
    await first;
    expect(controller.data, isNotNull);
    expect(controller.busy, isFalse);
    service.pending = Completer();
    final refresh = controller.query('other desktop');
    expect(controller.data, isNull);
    service.pending.completeError(StateError('未检测到已登录账号'));
    await refresh;
    expect(controller.data, isNull);
    expect(controller.error, '未检测到已登录账号');
    expect(service.calls, 2);
  });

  test(
    'disposing during query does not notify or retain account data',
    () async {
      final service = PendingUsage();
      final controller = AccountUsageController(service);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final query = controller.query('desktop');
      controller.dispose();
      service.pending.complete(AccountUsage.fromJson(usageResponse()));
      await query;
      expect(notifications, 1);
      expect(controller.data, isNull);
    },
  );
}
