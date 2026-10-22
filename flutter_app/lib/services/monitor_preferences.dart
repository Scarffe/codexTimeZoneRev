import 'dart:convert';
import 'dart:io';

/// Portable monitor-only preferences; launcher settings are never rewritten.
class MonitorPreferences {
  const MonitorPreferences({
    this.seconds = 120,
    this.threshold = 20,
    this.alerts = true,
    this.mode = 1,
    this.visible = true,
    this.enabled = false,
    this.localTime = true,
    this.reducedMotion = false,
    this.sessionAlerts = false,
    this.sessionMutedUntil,
  });
  final int seconds, threshold, mode;
  final int? sessionMutedUntil;
  final bool alerts, visible, enabled, localTime, reducedMotion, sessionAlerts;
  factory MonitorPreferences.fromJson(Map<String, dynamic> value) {
    int choice(String key, List<int> choices, int fallback) =>
        value[key] is int && choices.contains(value[key])
        ? value[key] as int
        : fallback;
    bool flag(String key, bool fallback) =>
        value[key] is bool ? value[key] as bool : fallback;
    return MonitorPreferences(
      seconds: choice('seconds', [60, 120, 300, 600], 120),
      threshold: choice('threshold', [10, 20, 30], 20),
      mode: choice('mode', [0, 1, 2], 1),
      alerts: flag('alerts', true),
      visible: flag('visible', true),
      enabled: flag('enabled', false),
      localTime: flag('localTime', true),
      reducedMotion: flag('reducedMotion', false),
      sessionAlerts: flag('sessionAlerts', false),
      sessionMutedUntil:
          value['sessionMutedUntil'] is int &&
              (value['sessionMutedUntil'] as int) >= 0 &&
              (value['sessionMutedUntil'] as int) <= 8640000000000000
          ? value['sessionMutedUntil'] as int
          : null,
    );
  }
  Map<String, Object> toJson() => {
    'seconds': seconds,
    'threshold': threshold,
    'alerts': alerts,
    'mode': mode,
    'visible': visible,
    'enabled': enabled,
    'localTime': localTime,
    'reducedMotion': reducedMotion,
    'sessionAlerts': sessionAlerts,
    'sessionMutedUntil': ?sessionMutedUntil,
  };
}

class MonitorPreferencesStore {
  MonitorPreferencesStore(this.file);
  factory MonitorPreferencesStore.portable() => MonitorPreferencesStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/monitor-preferences-v1.json',
    ),
  );
  final File file;
  bool _backupBeforeWrite = false;
  Future<Map<String, dynamic>> read() async {
    if (!await file.exists()) return {};
    Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } catch (_) {
      _backupBeforeWrite = true;
      rethrow;
    }
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      _backupBeforeWrite = true;
      throw const FormatException('Unsupported monitor settings');
    }
    return value;
  }

  Future<void> write(Map<String, Object?> value) async {
    if (_backupBeforeWrite && await file.exists()) {
      await file.copy(
        '${file.path}.invalid-${DateTime.now().microsecondsSinceEpoch}.bak',
      );
      _backupBeforeWrite = false;
    }
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode({'version': 1, ...value}), flush: true);
    // Dart's rename replaces an existing file on Windows as well.
    await temp.rename(file.path);
  }
}
