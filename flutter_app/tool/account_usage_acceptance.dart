import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/backend.dart';

// Explicit local check. Reads existing login; never creates a turn or changes login.
Future<void> main(List<String> arguments) async {
  const backend = NativeBackend();
  final response = await backend.call('account_usage', {'path': ''});
  final usage = AccountUsage.fromJson(response);
  if (usage.buckets.isEmpty && usage.lifetimeTokens == null) {
    throw StateError('No account usage returned');
  }
  for (final bucket in usage.buckets) {
    for (final window in bucket.windows) {
      if (window.usedPercent == null || window.resetsAt == null) {
        throw StateError('Missing percentage or reset timestamp');
      }
    }
  }
  if (arguments.isNotEmpty) {
    await File(arguments.first).writeAsString(jsonEncode(response));
  }
  stdout.writeln(
    jsonEncode({
      'accountDetected': usage.email != null,
      'plan': usage.plan,
      'windows': [
        for (final bucket in usage.buckets)
          for (final window in bucket.windows)
            {
              'period': window.label,
              'usedPercent': window.usedPercent,
              'resetsAt': window.resetsAt!.toIso8601String(),
            },
      ],
      'tokenSummaryAvailable': usage.lifetimeTokens != null,
      'dailyTokensAvailable': usage.latestDailyTokens != null,
      'limitsError': usage.limitsError,
      'tokensError': usage.tokensError,
    }),
  );
}
