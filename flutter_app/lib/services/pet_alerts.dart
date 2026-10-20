import 'account_usage.dart';

/// Session-only de-duplication. Never writes account identifiers to disk.
class PetAlerts {
  final _seen = <String, int>{};

  String? observe(AccountUsage usage, DateTime now) {
    final messages = <String>[];
    for (final bucket in usage.buckets) {
      for (var i = 0; i < bucket.windows.length; i++) {
        final window = bucket.windows[i];
        final reset = window.resetsAt;
        final used = window.usedPercent;
        if (used == null || reset == null || !reset.isAfter(now)) continue;
        final left = 100 - used;
        final level = left <= 10 ? 2 : (left <= 20 ? 1 : 0);
        final key =
            '${usage.identity}|${bucket.id}|$i|${reset.millisecondsSinceEpoch}';
        if (level > (_seen[key] ?? 0)) {
          messages.add('${bucket.label} ${window.label}剩余 ${left.round()}%');
          _seen[key] = level;
        }
      }
    }
    // Bound session memory without retaining historic accounts indefinitely.
    if (_seen.length > 256) _seen.remove(_seen.keys.first);
    return messages.isEmpty ? null : messages.join('；');
  }
}
