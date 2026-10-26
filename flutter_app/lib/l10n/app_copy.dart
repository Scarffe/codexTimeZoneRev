import 'package:flutter/widgets.dart';

import 'app_language.dart';
import 'copy_types.dart';
import 'copy_common.dart';
import 'copy_launcher.dart';
import 'copy_accounts.dart';
import 'copy_sessions.dart';
import 'copy_analysis.dart';
import 'copy_benchmark.dart';
import 'copy_notices.dart';
import 'copy_tasks.dart';
import 'copy_global.dart';

/// Application copy is explicitly scoped: platform/system locale must not
/// silently change this app's Chinese default, or translate source/user data.
class AppCopyScope extends InheritedWidget {
  const AppCopyScope({super.key, required this.language, required super.child});
  final AppLanguage language;
  @override
  bool updateShouldNotify(AppCopyScope oldWidget) =>
      language != oldWidget.language;
}

class AppCopy {
  const AppCopy(this.language);
  final AppLanguage language;
  bool get isEnglish => language == AppLanguage.en;
  Locale get locale => language.locale;

  static AppCopy of(BuildContext context) => AppCopy(
    context.dependOnInheritedWidgetOfExactType<AppCopyScope>()?.language ??
        AppLanguage.zh,
  );

  static final AppMessages messages = Map.unmodifiable({
    ...commonMessages,
    ...launcherMessages,
    ...accountMessages,
    ...sessionMessages,
    ...analysisMessages,
    ...benchmarkMessages,
    ...noticeMessages,
    ...taskMessages,
    ...globalMessages,
  });
  static final _parameter = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');

  /// Only stable application keys enter this method. Aliases, paths, model and
  /// session names are arguments, never keys or inputs to a global replacer.
  String text(String key, {Map<String, Object?> args = const {}}) {
    final message = messages[key];
    final template = message == null
        ? key
        : (isEnglish ? message.en : message.zh);
    return template.replaceAllMapped(
      _parameter,
      (match) => args[match[1]]?.toString() ?? match[0]!,
    );
  }

  String number(num? value, {int decimals = 2}) =>
      value == null || !value.isFinite ? '—' : value.toStringAsFixed(decimals);

  String integer(int value) {
    final grouped = value.abs().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
    return value < 0 ? '-$grouped' : grouped;
  }

  String seconds(num? milliseconds) =>
      milliseconds == null || !milliseconds.isFinite
      ? '—'
      : '${number(milliseconds / 1000)} s';

  /// The UI chooses its display zone. Log timestamps default to local time;
  /// the launcher's target-zone preview passes local:false to retain its zone.
  String dateTime(
    DateTime? value, {
    bool compact = false,
    bool local = true,
    bool includeSeconds = false,
  }) {
    if (value == null) return '—';
    final date = local ? value.toLocal() : value;
    String two(int number) => number.toString().padLeft(2, '0');
    final clock =
        '${two(date.hour)}:${two(date.minute)}'
        '${includeSeconds ? ':${two(date.second)}' : ''}';
    if (compact) return '${two(date.month)}-${two(date.day)} $clock';
    if (!isEnglish) return '${date.year}年${date.month}月${date.day}日 $clock';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year} $clock';
  }

  String weekday(DateTime value) => (isEnglish
      ? const [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ]
      : const [
          '星期一',
          '星期二',
          '星期三',
          '星期四',
          '星期五',
          '星期六',
          '星期日',
        ])[value.weekday - 1];

  String duration(Duration value) {
    var remaining = value.inSeconds.abs();
    final parts = <String>[];
    for (final unit in [
      (86400, 'd', '天'),
      (3600, 'h', '小时'),
      (60, 'min', '分'),
      (1, 's', '秒'),
    ]) {
      final amount = remaining ~/ unit.$1;
      remaining %= unit.$1;
      if (amount > 0 || (unit.$1 == 1 && parts.isEmpty)) {
        parts.add(isEnglish ? '$amount ${unit.$2}' : '$amount${unit.$3}');
      }
      if (parts.length == 2) break;
    }
    return parts.join(isEnglish ? ' ' : '');
  }

  String relative(DateTime target, {required DateTime now}) {
    final difference = target.difference(now);
    return text(
      difference.isNegative ? 'common.ago' : 'common.after',
      args: {'duration': duration(difference)},
    );
  }
}
