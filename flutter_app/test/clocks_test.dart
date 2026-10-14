import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;
import 'package:codex_timezone/domain/settings.dart';
import 'package:codex_timezone/services/clocks.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);
  test('New York spring DST skips from 01:59 to 03:00', () {
    const settings = LauncherSettings(zoneId: 'America/New_York');
    final before = targetClock(settings, DateTime.utc(2026, 3, 8, 6, 59));
    final after = targetClock(settings, DateTime.utc(2026, 3, 8, 7));
    expect(before.time, '01:59:00');
    expect(before.offset, 'UTC −05:00');
    expect(after.time, '03:00:00');
    expect(after.offset, 'UTC −04:00');
  });
  test('fractional regions and fixed offset date rollover', () {
    final instant = DateTime.utc(2026, 1, 1, 23);
    expect(
      targetClock(
        const LauncherSettings(zoneId: 'Asia/Kolkata'),
        instant,
      ).offset,
      'UTC +05:30',
    );
    expect(
      targetClock(
        const LauncherSettings(zoneId: 'Asia/Kathmandu'),
        instant,
      ).offset,
      'UTC +05:45',
    );
    final fixed = targetClock(
      const LauncherSettings(mode: 'offset', offset: 14),
      instant,
    );
    expect(fixed.time, '13:00:00');
    expect(fixed.date, contains('1 月 2 日'));
  });
  test('usage reset time switches between node timezone and local time', () {
    final instant = DateTime.utc(2026, 10, 14, 12, 36);
    expect(
      usageResetTime(
        const LauncherSettings(zoneId: 'America/Los_Angeles'),
        instant,
        local: false,
      ),
      '2026/10/14 05:36',
    );
    expect(
      usageResetTime(
        const LauncherSettings(mode: 'offset', offset: 14),
        instant,
        local: false,
      ),
      '2026/10/15 02:36',
    );
    final local = instant.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final expected =
        '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
    expect(
      usageResetTime(
        const LauncherSettings(zoneId: 'invalid/zone'),
        instant,
        local: true,
      ),
      expected,
    );
  });
}
