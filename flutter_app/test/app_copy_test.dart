import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/l10n/copy_types.dart';
import 'package:codex_timezone/l10n/copy_common.dart';
import 'package:codex_timezone/l10n/copy_launcher.dart';
import 'package:codex_timezone/l10n/copy_accounts.dart';
import 'package:codex_timezone/l10n/copy_sessions.dart';
import 'package:codex_timezone/l10n/copy_analysis.dart';
import 'package:codex_timezone/l10n/copy_benchmark.dart';
import 'package:codex_timezone/l10n/copy_notices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const zh = AppCopy(AppLanguage.zh), en = AppCopy(AppLanguage.en);
  test('both languages preserve numbers and explicitly selected date zone', () {
    final time = DateTime.utc(2026, 10, 25, 23, 4, 5);
    expect(zh.dateTime(time, local: false), '2026年10月25日 23:04');
    expect(en.dateTime(time, local: false), 'Oct 25, 2026 23:04');
    expect(
      en.dateTime(time, compact: true, local: false, includeSeconds: true),
      '10-25 23:04:05',
    );
    expect(zh.weekday(time), '星期日');
    expect(en.weekday(time), 'Sunday');
    for (final copy in [zh, en]) {
      expect(copy.number(12.3), '12.30');
      expect(copy.number(double.nan), '—');
      expect(copy.seconds(null), '—');
      expect(copy.seconds(1234), '1.23 s');
      expect(copy.integer(-1234567), '-1,234,567');
    }
    expect(
      en.relative(time.add(const Duration(minutes: 3)), now: time),
      'in 3 min',
    );
    expect(
      zh.relative(time.subtract(const Duration(minutes: 3)), now: time),
      '3分前',
    );
  });
  test(
    'application templates do not translate or substitute inside user values',
    () {
      const raw = r'中文 / {duration} / D:\账号\source.json';
      expect(
        en.text('nav.unread', args: {'name': raw, 'count': 2}),
        '$raw · 2 unread',
      );
      expect(
        zh.text('nav.unread', args: {'name': raw, 'count': 2}),
        '$raw · 2 未读',
      );
    },
  );
  test(
    'catalogs have unique keys and matching named parameters in both languages',
    () {
      final catalogs = <AppMessages>[
        commonMessages,
        launcherMessages,
        accountMessages,
        sessionMessages,
        analysisMessages,
        benchmarkMessages,
        noticeMessages,
      ];
      final seen = <String>{};
      final parameter = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');
      Set<String> parameters(String text) =>
          parameter.allMatches(text).map((m) => m[1]!).toSet();
      for (final catalog in catalogs) {
        for (final entry in catalog.entries) {
          expect(seen.add(entry.key), true, reason: 'Duplicate ${entry.key}');
          expect(entry.value.zh.trim(), isNotEmpty, reason: entry.key);
          expect(entry.value.en.trim(), isNotEmpty, reason: entry.key);
          expect(
            parameters(entry.value.en),
            parameters(entry.value.zh),
            reason: entry.key,
          );
          if (entry.key != 'app.language.zh') {
            expect(
              RegExp(r'[\u3400-\u9fff]').hasMatch(entry.value.en),
              false,
              reason: entry.key,
            );
          }
        }
      }
    },
  );
}
