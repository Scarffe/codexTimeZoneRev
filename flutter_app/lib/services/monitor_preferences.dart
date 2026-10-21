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
    this.enabled = true,
    this.localTime = true,
  });
  final int seconds, threshold, mode;
  final bool alerts, visible, enabled, localTime;
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
      enabled: flag('enabled', true),
      localTime: flag('localTime', true),
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
