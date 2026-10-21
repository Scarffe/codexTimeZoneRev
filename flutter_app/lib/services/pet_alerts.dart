import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'account_usage.dart';

/// Only opaque cycle digests and expiration/level values may be persisted.
class PetAlerts {
  final _seen = <String, ({int level, int expires})>{};
  String _key(
    AccountUsage usage,
    UsageBucket bucket,
    UsageWindow window,
    int i,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            usage.identity,
            bucket.id,
            window.durationMinutes ?? i,
            window.resetsAt!.millisecondsSinceEpoch,
          ]),
        ),
      )
      .toString();
  void restore(Object? records, DateTime now) {
    if (records is! Map) return;
    for (final entry in records.entries.take(256)) {
      final value = entry.value;
      if (entry.key is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) &&
          value is List &&
          value.length == 2 &&
          value[0] is int &&
          [1, 2, 3].contains(value[0]) &&
          value[1] is int &&
          value[1] > now.millisecondsSinceEpoch) {
        _seen[entry.key] = (level: value[0], expires: value[1]);
      }
    }
  }

  Map<String, Object> records(DateTime now) {
    _seen.removeWhere((_, v) => v.expires <= now.millisecondsSinceEpoch);
    return {
      for (final e in _seen.entries) e.key: [e.value.level, e.value.expires],
    };
  }

  bool isMuted(AccountUsage usage, DateTime now) {
    var windows = 0;
    for (final bucket in usage.buckets) {
      for (var i = 0; i < bucket.windows.length; i++) {
        final window = bucket.windows[i];
        if (window.resetsAt?.isAfter(now) != true) continue;
        windows++;
        if (_seen[_key(usage, bucket, window, i)]?.level != 3) return false;
      }
    }
    return windows > 0;
  }

  void mute(AccountUsage usage, DateTime now) {
    for (final bucket in usage.buckets) {
      for (var i = 0; i < bucket.windows.length; i++) {
        final window = bucket.windows[i];
        if (window.resetsAt?.isAfter(now) != true) continue;
        _seen[_key(usage, bucket, window, i)] = (
          level: 3,
          expires: window.resetsAt!.millisecondsSinceEpoch,
        );
      }
    }
    _bound(now);
  }

  void _bound(DateTime now) {
    records(now);
    while (_seen.length > 256) {
      _seen.remove(_seen.keys.first);
    }
  }

  String? observe(AccountUsage usage, DateTime now, {int threshold = 20}) {
    final messages = <String>[];
    for (final bucket in usage.buckets) {
      for (var i = 0; i < bucket.windows.length; i++) {
        final window = bucket.windows[i],
            reset = window.resetsAt,
            used = window.usedPercent;
        if (used == null || reset == null || !reset.isAfter(now)) continue;
        final left = 100 - used;
        final level = left <= 10 ? 2 : (left <= threshold ? 1 : 0);
        final key = _key(usage, bucket, window, i);
        if (level > (_seen[key]?.level ?? 0)) {
          messages.add('${bucket.label} ${window.label}剩余 ${left.round()}%');
          _seen[key] = (level: level, expires: reset.millisecondsSinceEpoch);
        }
      }
    }
    _bound(now);
    return messages.isEmpty ? null : messages.join('；');
  }
}
