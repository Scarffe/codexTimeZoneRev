import 'dart:async';

import '../l10n/app_copy.dart';
import '../l10n/app_language.dart';

import '../state/session_rhythm_controller.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../state/account_usage_controller.dart';
import '../state/session_metrics_controller.dart';
import '../state/benchmark_controller.dart';
import '../state/tasks_controller.dart';
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
    this.tasks,
    this.interval = const Duration(minutes: 2),
    this.language,
  });
  final SessionRhythmController? rhythm;
  final AccountUsageController usage;
  final SessionAttentionController? attention;
  final VoidCallback? onAttentionDetails;
  final SessionMetricsController? metrics;
  final BenchmarkController? benchmark;
  final TasksController? tasks;
  final String Function() path;
  final Duration interval;
  final AppLanguage Function()? language;
  AppCopy get _copy => AppCopy(language?.call() ?? AppLanguage.zh);
  void refreshPresentation() => _publish();
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
    tasks?.addListener(_publish);
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
          await tasks?.cancelAll();
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
      benchmark?.keepAlive == true ||
      tasks?.keepAlive == true;

  Future<void> _exit() =>
      _exitRequest ??= _gracefulExit().catchError((Object _) {
        _exitRequest = null;
        onNotice?.call(_copy.text('notice.exitIncomplete'));
      });

  Future<void> _gracefulExit() async {
    usage.pause(persist: false);
    // Task children own source leases. Confirm their cleanup before sources exit.
    await tasks?.shutdown();
    await tasks?.saved;
    if (tasks?.cleanupComplete == false) {
      throw StateError('owned_task_cleanup_incomplete');
    }
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
    final copy = _copy;
    if (copy.isEnglish) {
      final label = usage.sources?.pinned?.alias ?? 'Codex';
      final remaining = snapshot['remaining'] as num;
      final status = copy.text(
        snapshot['busy'] == true
            ? 'notice.refreshing'
            : snapshot['stale'] == true
            ? 'notice.stale'
            : snapshot['animationState'] == 3
            ? 'notice.unavailable'
            : snapshot['paused'] == true
            ? 'notice.paused'
            : 'notice.monitoring',
      );
      snapshot['text'] = copy.text(
        'notice.quotaSummary',
        args: {
          'name': label,
          'value': remaining < 0 ? '—' : '${copy.number(remaining)}%',
          'status': status,
        },
      );
      final data = usage.sources == null
          ? usage.data
          : usage.sources?.pinned?.usage;
      final bucket =
          data?.buckets.where((b) => b.id == 'codex').firstOrNull ??
          data?.buckets.firstOrNull;
      final now = DateTime.now();
      snapshot['detail'] =
          bucket?.windows
              .map((window) {
                final minutes = window.durationMinutes;
                final key = minutes == null || minutes <= 0
                    ? 'notice.window'
                    : minutes == 10080
                    ? 'notice.windowWeek'
                    : minutes % 1440 == 0
                    ? 'notice.windowDays'
                    : minutes % 60 == 0
                    ? 'notice.windowHours'
                    : 'notice.windowMinutes';
                final count = minutes == null
                    ? 0
                    : minutes % 1440 == 0
                    ? minutes ~/ 1440
                    : minutes % 60 == 0
                    ? minutes ~/ 60
                    : minutes;
                final reset = window.resetsAt;
                final countdown = reset == null
                    ? copy.text('notice.resetUnknown')
                    : !reset.isAfter(now)
                    ? copy.text('notice.resetAwaiting')
                    : copy.text(
                        'notice.reset',
                        args: {
                          'time': copy.dateTime(reset),
                          'relative': copy.relative(reset, now: now),
                        },
                      );
                final left = window.usedPercent == null
                    ? '—'
                    : '${copy.number(100 - window.usedPercent!)}%';
                return '${copy.text('notice.quotaSummary', args: {
                  'name': copy.text(key, args: {'count': count}),
                  'value': left,
                  'status': status,
                })}\n$countdown';
              })
              .join('\n\n') ??
          snapshot['text'];
      if ((snapshot['alert'] as String).isNotEmpty) {
        final id = usage.sources?.alertSourceId;
        final source = usage.sources?.states
            .where((s) => s.id == id)
            .firstOrNull;
        snapshot['alert'] = copy.text(
          'notice.lowQuota',
          args: {'name': source?.alias ?? 'Codex'},
        );
      }
      if ((snapshot['sessionAlert'] as String).isNotEmpty) {
        snapshot['sessionAlert'] = copy.text('notice.selectedCompleted');
      }
      if ((snapshot['attentionAlert'] as String).isNotEmpty) {
        final notice = attention?.activeNotice;
        snapshot['attentionAlert'] = notice == null
            ? copy.text('notice.selectedCompleted')
            : copy.text('notice.completed', args: {'name': notice.title});
      }
    }
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
    final state = copy.isEnglish
        ? copy.text(
            'notice.session.${metrics?.selected == null
                ? 'none'
                : metrics?.error != null
                ? 'unavailable'
                : metrics?.data?['catchingUp'] == true
                ? 'history'
                : const {'running', 'completed', 'cancelled'}.contains(metrics?.data?['current']?['status'])
                ? metrics!.data!['current']['status']
                : 'unknown'}',
          )
        : metrics?.stateLabel ?? '';
    final summary = copy.isEnglish && metrics?.selected != null
        ? copy.text(
            'notice.turnRate',
            args: {
              'value': metrics?.verifiedTokensPerSecond == null
                  ? '—'
                  : '${copy.number(metrics!.verifiedTokensPerSecond)} tokens/s',
            },
          )
        : metrics?.summary ?? '';
    snapshot['sessionSummary'] = copy.isEnglish
        ? '$state\n$summary'
        : metrics?.petSummary ?? '';
    if (summary.isNotEmpty) {
      snapshot['text'] = '$state · ${snapshot['text']} · $summary';
      snapshot['detail'] = '$state\n$summary\n${snapshot['detail']}';
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
    tasks?.removeListener(_publish);
    rhythm?.removeListener(_publish);
    channel.setMethodCallHandler(null);
  }
}
