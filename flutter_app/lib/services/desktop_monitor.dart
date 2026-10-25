import 'dart:async';

import '../state/session_rhythm_controller.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../state/account_usage_controller.dart';
import '../state/session_metrics_controller.dart';
import '../state/benchmark_controller.dart';
import '../state/session_attention_controller.dart';

/// Only publishes display data; native surfaces never query the account.
class DesktopMonitor {
  DesktopMonitor(
    this.usage,
    this.path, {
    this.onRoles,
    this.onSessionDetails,
    this.onAttentionDetails,
    this.attention,
    this.rhythm,
    this.onMonitor,
    this.backgroundStart = false,
    this.workspace,
    this.onNotice,
    this.metrics,
    this.benchmark,
    this.interval = const Duration(minutes: 2),
  });
  final SessionRhythmController? rhythm;
  final AccountUsageController usage;
  final SessionAttentionController? attention;
  final VoidCallback? onAttentionDetails;
  final SessionMetricsController? metrics;
  final BenchmarkController? benchmark;
  final String Function() path;
  final Duration interval;
  final VoidCallback? onRoles, onSessionDetails, onMonitor;
  final bool backgroundStart;
  final String Function()? workspace;
  final ValueChanged<String>? onNotice;
  static const channel = MethodChannel('codex_timezone/monitor');
  bool _closed = false;
  bool _started = false;
  Future<void>? _exitRequest;
  int _quotaNoticeSerial = 0, _sessionNoticeSerial = 0;
  Timer? _clock;
  Map<String, Object?>? _lastSnapshot;

  void start() {
    if (_started || _closed) return;
    _started = true;
    usage.setMainWindowVisible(!backgroundStart);
    usage.addListener(_publish);
    metrics?.addListener(_publish);
    attention?.addListener(_publish);
    benchmark?.addListener(_publish);
    rhythm?.addListener(_publish);
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'attentionDetails':
          await _syncMainVisibility();
          onAttentionDetails?.call();
        case 'sessionDetails':
          await _syncMainVisibility();
          onSessionDetails?.call();
        case 'monitorDetails':
          await _syncMainVisibility();
          onMonitor?.call();
        case 'closeRequested':
          if (backgroundStart || _keepAlive) {
            await channel.invokeMethod<void>('hide');
            await _syncMainVisibility();
          } else {
            await _exit();
          }
        case 'roles':
        case 'reduceMotion':
        case 'mode0':
        case 'mode1':
        case 'mode2':
        case 'showPet':
        case 'hidePet':
          // Legacy tray commands must not resurrect the paused pet feature.
          break;
        case 'mainShown':
          await _syncMainVisibility();
        case 'mainHidden':
          await _syncMainVisibility();
        case 'muteCycle':
          usage.muteCurrentCycle();
        case 'systemSuspend':
          metrics?.resetObservation();
          attention?.resetObservation();
          usage.systemSuspending();
          await benchmark?.interrupt();
        case 'systemResume':
          attention?.resetObservation();
          usage.systemResumed();
        case 'refresh':
          final owner = usage.sources;
          if (owner == null) {
            await usage.query(path(), details: false);
          } else {
            await owner.refresh(owner.pinnedId);
          }
        case 'pause':
          usage.pause();
        case 'resume':
          usage.startMonitoring(path);
        case 'exit':
          await _exit();
      }
    });
    unawaited(_syncMainVisibility());
    if (usage.savedMonitoring) {
      usage.startMonitoring(
        path,
        every: interval == const Duration(minutes: 2)
            ? usage.interval
            : interval,
      );
    }
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _publish());
    _publish();
  }

  bool get _keepAlive =>
      usage.monitoring ||
      rhythm?.busy == true ||
      usage.sources?.anyBusy == true ||
      metrics?.selected != null ||
      attention?.watches.any((watch) => watch.enabled) == true ||
      benchmark?.keepAlive == true;

  Future<void> _exit() =>
      _exitRequest ??= _gracefulExit().catchError((Object _) {
        _exitRequest = null;
        onNotice?.call('退出清理未完成，监控已停止；请再次选择退出以重试。');
      });

  Future<void> _gracefulExit() async {
    usage.pause(persist: false);
    await Future.wait([
      if (usage.sources != null) usage.sources!.shutdown(),
      if (benchmark != null) benchmark!.shutdown(),
      if (attention != null) attention!.shutdown(),
      if (rhythm != null) rhythm!.shutdown(),
    ]);
    await benchmark?.saved;
    await usage.roles.saved;
    await usage.settingsSaved;
    // Query owns its short-lived app-server. Let Rust Drop clean it first.
    while (usage.sources == null && usage.busy && !_closed) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await usage.settingsSaved;
    await metrics?.selectionSaved;
    if (!_closed) await channel.invokeMethod<void>('exit');
  }

  Future<void> _syncMainVisibility() async {
    try {
      final visible = await channel.invokeMethod<bool>('mainVisible') ?? false;
      if (!_closed) usage.setMainWindowVisible(visible);
    } catch (_) {
      if (!_closed) usage.setMainWindowVisible(false);
    }
  }

  void _publish() {
    if (_closed) return;
    metrics?.configureReminders(
      enabled:
          usage.sessionAlertsEnabled &&
          !(metrics?.selected != null &&
              attention?.hasWatchedPath(metrics!.selected!) == true),
      muteUntil: usage.sessionMutedUntil,
    );
    attention?.configureReminders(
      enabled: usage.sessionAlertsEnabled,
      muteUntil: usage.sessionMutedUntil,
    );
    final snapshot = usage.desktopSnapshot;
    snapshot['keepAlive'] = _keepAlive;
    snapshot['workspace'] = workspace?.call() ?? 'launcher';
    snapshot['petVisible'] = false;
    snapshot['roleImage'] = '';
    snapshot['roleName'] = '';
    snapshot['sessionAlert'] = metrics?.alert ?? '';
    snapshot['sessionAlertSerial'] = metrics?.alertSerial ?? 0;
    snapshot['attentionAlert'] = attention?.alert ?? '';
    snapshot['attentionAlertSerial'] = attention?.alertSerial ?? 0;
    // Durable completed notices have a separate status, never selected log status.
    snapshot['attentionAlertStatus'] = attention?.alert.isNotEmpty == true
        ? 2
        : 0;
    final quotaSerial = snapshot['alertSerial'] as int;
    final sessionSerial = snapshot['sessionAlertSerial'] as int;
    final quotaNotice = quotaSerial > _quotaNoticeSerial
        ? snapshot['alert'] as String
        : '';
    final sessionNotice = sessionSerial > _sessionNoticeSerial
        ? snapshot['sessionAlert'] as String
        : '';
    _quotaNoticeSerial = quotaSerial;
    _sessionNoticeSerial = sessionSerial;
    // Records a local event; the OS may suppress the native notification.
    if (quotaNotice.isNotEmpty || sessionNotice.isNotEmpty) {
      onNotice?.call(quotaNotice.isNotEmpty ? quotaNotice : sessionNotice);
    }
    snapshot['sessionStatus'] = metrics?.selected == null
        ? 0
        : switch (metrics?.stateLabel) {
            '回合进行中' => 1,
            '回合已结束' => 2,
            '已取消' => 3,
            _ => 4,
          };
    snapshot['sessionRate'] = metrics?.verifiedTokensPerSecond ?? -1.0;
    snapshot['sessionSummary'] = metrics?.petSummary ?? '';
    final summary = metrics?.summary ?? '';
    if (summary.isNotEmpty) {
      snapshot['text'] =
          '${metrics?.stateLabel} · ${snapshot['text']} · $summary';
      snapshot['detail'] =
          '${metrics?.stateLabel}\n$summary\n${snapshot['detail']}';
    }
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
    metrics?.removeListener(_publish);
    attention?.removeListener(_publish);
    benchmark?.removeListener(_publish);
    rhythm?.removeListener(_publish);
    channel.setMethodCallHandler(null);
  }
}
