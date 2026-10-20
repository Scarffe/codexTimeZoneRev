import 'package:flutter_test/flutter_test.dart';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/pet_alerts.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';

class PetUsageService implements AccountUsageService {
  PetUsageService(this.value);
  final AccountUsage value;
  int queries = 0;
  @override
  Future<AccountUsage> query(String path) async {
    queries++;
    return value;
  }
}

void main() {
  final now = DateTime.utc(2026, 10, 20);
  AccountUsage sample(double used, {String identity = 'a', int cycle = 1}) =>
      AccountUsage(
        email: null,
        plan: null,
        identityKey: identity,
        fetchedAt: now,
        buckets: [
          UsageBucket(
            label: 'Codex',
            windows: [
              UsageWindow(
                usedPercent: used,
                durationMinutes: 300,
                resetsAt: now.add(Duration(hours: cycle)),
              ),
            ],
          ),
        ],
      );
  test('20 and 10 percent alert once each per identity and reset cycle', () {
    final policy = PetAlerts();
    expect(policy.observe(sample(79), now), isNull);
    expect(policy.observe(sample(80), now), contains('20%'));
    expect(policy.observe(sample(85), now), isNull);
    expect(policy.observe(sample(90), now), contains('10%'));
    expect(policy.observe(sample(95), now), isNull);
    expect(policy.observe(sample(95, identity: 'b'), now), isNotNull);
    expect(policy.observe(sample(95, cycle: 2), now), isNotNull);
    expect(
      policy.observe(sample(95), now.add(const Duration(hours: 2))),
      isNull,
    );
  });
  test('unknown reset does not produce a misleading cycle alert', () {
    final usage = AccountUsage(
      email: null,
      plan: null,
      fetchedAt: now,
      buckets: [
        const UsageBucket(
          label: 'Codex',
          windows: [UsageWindow(usedPercent: 99)],
        ),
      ],
    );
    expect(PetAlerts().observe(usage, now), isNull);
  });
  test('reset countdown never implies refreshed quota', () {
    expect(resetCountdown(now, now), contains('重新查询'));
    expect(resetCountdown(null, now), isNotEmpty);
    expect(
      resetCountdown(now.add(const Duration(minutes: 5)), now),
      contains('5'),
    );
  });
  test(
    'clock updates reuse snapshot and suppress stale cached alerts',
    () async {
      var clock = now;
      final service = PetUsageService(sample(95));
      final controller = AccountUsageController(service, now: () => clock);
      await controller.query('isolated');
      expect(controller.desktopSnapshot['alert'], contains('5%'));
      final serial = controller.desktopSnapshot['alertSerial'];
      clock = now.add(const Duration(minutes: 5));
      expect(controller.desktopSnapshot['stale'], isTrue);
      expect(controller.desktopSnapshot['alert'], '');
      expect(service.queries, 1);
      expect(controller.desktopSnapshot['alertSerial'], serial);
      controller.sourceChanged('other');
      expect(controller.desktopSnapshot['remaining'], -1.0);
      expect(controller.desktopSnapshot['alert'], '');
      controller.dispose();
    },
  );
  test('an old service result does not consume a fresh cycle alert', () async {
    var clock = now.add(const Duration(minutes: 5));
    final controller = AccountUsageController(
      PetUsageService(sample(95)),
      now: () => clock,
    );
    await controller.query('isolated');
    expect(controller.desktopSnapshot['alert'], '');
    clock = now;
    await controller.query('isolated');
    expect(controller.desktopSnapshot['alert'], contains('5%'));
    controller.dispose();
  });
}
