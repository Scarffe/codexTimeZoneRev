import 'dart:async';

import 'package:flutter/services.dart';

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

  void start() {
    usage.addListener(_publish);
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'refresh':
          await usage.query(path(), details: false);
        case 'pause':
          usage.pause();
        case 'resume':
          usage.startMonitoring(path);
        case 'exit':
          usage.pause();
          // Query owns its short-lived app-server. Let Rust Drop clean it first.
          while (usage.busy && !_closed) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (!_closed) await channel.invokeMethod<void>('exit');
      }
    });
    usage.startMonitoring(path, every: interval);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => _publish());
    _publish();
  }

  void _publish() {
    if (_closed) return;
    unawaited(
      channel.invokeMethod<void>('publish', usage.desktopSnapshot).catchError((
        Object e,
      ) {
        // A missing surface must not create a second polling path.
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
