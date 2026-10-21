import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../state/account_usage_controller.dart';

/// Only publishes display data; native surfaces never query the account.
class DesktopMonitor {
  DesktopMonitor(
    this.usage,
    this.path, {
    this.interval = const Duration(minutes: 2),
  });
  final AccountUsageController usage;
  final String Function() path;
  final Duration interval;
  static const channel = MethodChannel('codex_timezone/monitor');
  bool _closed = false;
  Timer? _clock;
  Map<String, Object?>? _lastSnapshot;

  void start() {
    usage.addListener(_publish);
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'mode0':
          usage.configurePet(mode: 0, visible: true);
        case 'mode1':
          usage.configurePet(mode: 1, visible: true);
        case 'mode2':
          usage.configurePet(mode: 2, visible: true);
        case 'showPet':
          usage.configurePet(visible: true);
        case 'hidePet':
          usage.configurePet(visible: false);
        case 'muteCycle':
          usage.muteCurrentCycle();
        case 'systemSuspend':
          usage.systemSuspending();
        case 'systemResume':
          usage.systemResumed();
        case 'refresh':
          await usage.query(path(), details: false);
        case 'pause':
          usage.pause();
        case 'resume':
          usage.startMonitoring(path);
        case 'exit':
          usage.pause(persist: false);
          await usage.settingsSaved;
          // Query owns its short-lived app-server. Let Rust Drop clean it first.
          while (usage.busy && !_closed) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await usage.settingsSaved;
          if (!_closed) await channel.invokeMethod<void>('exit');
      }
    });
    if (usage.savedMonitoring) {
      usage.startMonitoring(path, every: usage.interval);
    }
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _publish());
    _publish();
  }

  void _publish() {
    if (_closed) return;
    final snapshot = usage.desktopSnapshot;
    if (mapEquals(snapshot, _lastSnapshot)) return;
    _lastSnapshot = snapshot;
    unawaited(
      channel.invokeMethod<void>('publish', snapshot).catchError((Object e) {
        // A missing surface must not create a second polling path.
        _lastSnapshot = null;
      }),
    );
  }

  void dispose() {
    _closed = true;
    _clock?.cancel();
    usage.removeListener(_publish);
    channel.setMethodCallHandler(null);
  }
}
