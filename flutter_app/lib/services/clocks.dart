import 'package:timezone/timezone.dart' as tz;

import '../domain/settings.dart';

String offsetLabel(int minutes) {
  final absolute = minutes.abs();
  return 'UTC ${minutes < 0 ? '−' : '+'}${(absolute ~/ 60).toString().padLeft(2, '0')}:${(absolute % 60).toString().padLeft(2, '0')}';
}

class ClockReading {
  const ClockReading(this.time, this.date, this.offset);
  final String time;
  final String date;
  final String offset;
  factory ClockReading.fromDate(DateTime date, {int? fixedOffset}) {
    String two(int n) => n.toString().padLeft(2, '0');
    return ClockReading(
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}',
      '${date.year} 年 ${date.month} 月 ${date.day} 日 · 星期${'一二三四五六日'[date.weekday - 1]}',
      offsetLabel(fixedOffset ?? date.timeZoneOffset.inMinutes),
    );
  }
}

ClockReading targetClock(LauncherSettings settings, DateTime instant) {
  if (settings.mode == 'offset') {
    return ClockReading.fromDate(
      instant.toUtc().add(Duration(hours: settings.offset)),
      fixedOffset: settings.offset * 60,
    );
  }
  return ClockReading.fromDate(
    tz.TZDateTime.from(instant, tz.getLocation(settings.zoneId)),
  );
}
