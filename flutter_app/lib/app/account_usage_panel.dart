import '../l10n/app_copy.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'monitor_charts.dart';
import 'monitor_presentation.dart';
import '../domain/settings.dart';
import '../services/account_usage.dart';
import '../services/clocks.dart';
import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';

class AccountUsagePanel extends StatefulWidget {
  const AccountUsagePanel({
    super.key,
    required this.controller,
    required this.launcher,
    this.bounded = false,
  });
  final AccountUsageController controller;
  final LauncherController launcher;
  final bool bounded;
  @override
  State<AccountUsagePanel> createState() => _AccountUsagePanelState();
}

class _AccountUsagePanelState extends State<AccountUsagePanel> {
  Timer? _clock;
  final _scroll = ScrollController();
  String _view = 'remaining';
  String? _bucketId;
  Object? _sourceIdentity;

  void _syncClock() {
    if (widget.controller.data == null) {
      _clock?.cancel();
      _clock = null;
    } else {
      // Only displayed countdowns update; account reads remain controller-owned.
      _clock ??= Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant AccountUsagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  UsageBucket? _selectedBucket(List<UsageBucket> buckets) {
    if (buckets.isEmpty) return null;
    final matching = buckets.where((bucket) => bucket.id == _bucketId);
    final preferred = buckets.where((bucket) => bucket.id == 'codex');
    final selected = matching.isNotEmpty
        ? matching.first
        : preferred.isNotEmpty
        ? preferred.first
        : buckets.first;
    _bucketId = selected.id;
    return selected;
  }

  void _showInformation() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppCopy.of(context).text('accounts.usage.closeInfo'),
      pageBuilder: (_, _, _) =>
          _AccountUsageInformation(controller: widget.controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final sourceIdentity = (
      controller.sources?.selectedId,
      controller.sources?.selected?.generation,
    );
    if (_sourceIdentity != sourceIdentity) {
      _sourceIdentity = sourceIdentity;
      _bucketId = null;
    }
    final offlineBlocked =
        controller.offlineTrial &&
        controller.sources?.service.synthetic != true;
    final noManagedAccount =
        controller.sources != null && controller.sources!.selected == null;
    final data = controller.data;
    final bucket = _selectedBucket(data?.buckets ?? const []);
    final windows = bucket?.windows ?? const <UsageWindow>[];
    final settings = widget.launcher.settings;
    final now = DateTime.now();
    final muted = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(FLucideIcons.gauge, size: 18),
                const SizedBox(width: 6),
                Text(
                  AppCopy.of(context).text('accounts.usage.title'),
                  style: context.theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (bucket != null && (data?.buckets.length ?? 0) == 1)
              Text(bucket.label, style: muted),
            if (data != null) ...[
              MonitorChoice(
                key: const ValueKey('account-quota-view'),
                inline: true,
                label: AppCopy.of(context).text('accounts.usage.view'),
                value: _view,
                items: {
                  AppCopy.of(context).text('accounts.remaining'): 'remaining',
                  AppCopy.of(context).text('accounts.used'): 'used',
                  AppCopy.of(context).text('accounts.untilReset'): 'reset',
                },
                onChanged: (value) => setState(() => _view = value),
              ),
              if (data.buckets.length > 1)
                MonitorChoice(
                  key: const ValueKey('account-quota-bucket'),
                  inline: true,
                  label: AppCopy.of(context).text('accounts.usage.bucket'),
                  value: bucket!.id,
                  items: {
                    for (final item in data.buckets)
                      (data.buckets
                                  .where((other) => other.label == item.label)
                                  .length >
                              1
                          ? '${item.label} · ${item.id}'
                          : item.label): item
                          .id,
                  },
                  onChanged: (value) => setState(() => _bucketId = value),
                ),
              MonitorChoice(
                key: const ValueKey('usage-time-basis'),
                inline: true,
                label: AppCopy.of(context).text('accounts.usage.timeBasis'),
                value: controller.useLocalTime ? 'local' : 'node',
                items: {
                  AppCopy.of(context).text('accounts.usage.nodeTime'): 'node',
                  AppCopy.of(context).text('accounts.usage.localTime'): 'local',
                },
                onChanged: (value) => controller.setLocalTime(value == 'local'),
              ),
            ],
            MonitorIconAction(
              key: const ValueKey('account-usage-info'),
              label: AppCopy.of(context).text('accounts.usage.details'),
              icon: FLucideIcons.info,
              onPress: _showInformation,
            ),
            FButton.icon(
              key: const ValueKey('query-account-usage'),
              semanticsLabel: controller.busy
                  ? AppCopy.of(context).text('accounts.usage.querying')
                  : AppCopy.of(context).text('accounts.usage.query'),
              variant: FButtonVariant.ghost,
              onPress:
                  controller.busy ||
                      widget.launcher.preview ||
                      offlineBlocked ||
                      noManagedAccount
                  ? null
                  : () {
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                      controller.query(widget.launcher.effectivePath);
                    },
              child: const Icon(FLucideIcons.refreshCw, size: 18),
            ),
            FButton(
              key: const ValueKey('toggle-usage-monitor'),
              mainAxisSize: MainAxisSize.min,
              variant: FButtonVariant.ghost,
              selected: controller.monitoring,
              prefix: Icon(
                controller.monitoring ? FLucideIcons.pause : FLucideIcons.play,
                size: 16,
              ),
              onPress:
                  widget.launcher.preview || offlineBlocked || noManagedAccount
                  ? null
                  : () {
                      if (controller.monitoring) {
                        controller.pause();
                      } else {
                        controller.startMonitoring(
                          () => widget.launcher.effectivePath,
                        );
                      }
                    },
              child: Text(
                controller.monitoring
                    ? AppCopy.of(context).text('accounts.usage.pause')
                    : AppCopy.of(context).text('accounts.usage.start'),
              ),
            ),
          ],
        ),
        if (controller.busy) ...[
          const SizedBox(height: 5),
          const FProgress(),
          Text(
            AppCopy.of(context).text('accounts.usage.querying'),
            style: muted,
          ),
        ],
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            if (controller.error != null)
              Text(
                data == null
                    ? AppCopy.of(context).text('accounts.usage.queryFailed')
                    : AppCopy.of(context)
                          .text('accounts.usage.queryFailedPrevious'),
                style: muted,
              ),
            if (controller.preferencesError != null)
              Text(
                AppCopy.of(context).text('accounts.usage.preferenceError'),
                style: muted,
              ),
            if (controller.failures > 0 && controller.nextRefreshAt != null)
              Text(
                AppCopy.of(context).text(
                  'accounts.usage.backoff',
                  args: {
                    'time': ClockReading.fromDate(
                      controller.nextRefreshAt!.toLocal(),
                    ).time,
                  },
                ),
                style: muted,
              ),
            if (data != null && controller.stale)
              Text(
                AppCopy.of(context).text('accounts.usage.stale'),
                style: muted,
              ),
            if (data?.limitsError != null)
              Text(
                AppCopy.of(context).text('accounts.usage.limitsError'),
                style: muted,
              ),
            if (data?.tokensError != null)
              Text(
                AppCopy.of(context).text('accounts.usage.tokensError'),
                style: muted,
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (data == null)
          Text(
            controller.busy
                ? AppCopy.of(context).text('accounts.usage.reading')
                : AppCopy.of(context).text('accounts.usage.empty'),
            style: muted,
          )
        else if (windows.isEmpty)
          Text(
            AppCopy.of(context).text('accounts.usage.unavailable'),
            style: muted,
          )
        else
          AccountQuotaPresentation(
            key: const ValueKey('account-quota-chart'),
            inspectionIdentity: (
              controller.sources?.selectedId,
              controller.sources?.selected?.generation,
              data.identity,
            ),
            bucket: bucket!,
            settings: settings,
            useLocalTime: controller.useLocalTime,
            now: now,
            view: _view,
          ),
        if (data == null && !controller.busy)
          Text(
            noManagedAccount
                ? AppCopy.of(context).text('accounts.usage.addFirst')
                : controller.monitoring
                ? AppCopy.of(context).text('accounts.usage.monitoring')
                : AppCopy.of(context).text('accounts.usage.prompt'),
            style: muted,
          ),
      ],
    );
    return FCard(
      key: const ValueKey('account-usage-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
        child: widget.bounded
            ? RawScrollbar(
                controller: _scroll,
                thumbVisibility: true,
                thumbColor: context.theme.colors.mutedForeground.withValues(
                  alpha: .45,
                ),
                thickness: 4,
                radius: const Radius.circular(4),
                child: SingleChildScrollView(
                  key: const ValueKey('account-usage-details'),
                  controller: _scroll,
                  primary: false,
                  padding: const EdgeInsets.only(right: 8),
                  child: content,
                ),
              )
            : content,
      ),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    _scroll.dispose();
    super.dispose();
  }
}

/// Pure quota chart assembly for analysis and other display-only workspaces.
/// Reads, refresh actions, choices, source state and countdown ticks are owned
/// by the caller. The default account panel retains those responsibilities.
class AccountQuotaPresentation extends StatelessWidget {
  const AccountQuotaPresentation({
    super.key,
    required this.bucket,
    required this.settings,
    required this.useLocalTime,
    required this.now,
    this.view = 'remaining',
    this.inspectionIdentity,
  });
  final UsageBucket bucket;
  final LauncherSettings settings;
  final bool useLocalTime;
  final DateTime now;
  final String view;
  final Object? inspectionIdentity;

  double? _value(UsageWindow window) {
    if (view == 'reset') {
      final reset = window.resetsAt;
      return reset == null || !reset.isAfter(now)
          ? null
          : reset.difference(now).inMilliseconds / Duration.millisecondsPerHour;
    }
    final used = window.usedPercent;
    if (used == null || !used.isFinite || used < 0 || used > 100) return null;
    return view == 'used' ? used : 100 - used;
  }

  @override
  Widget build(BuildContext context) {
    if (bucket.windows.isEmpty) {
      return Text(AppCopy.of(context).text('accounts.usage.unavailable'));
    }
    final identity = (inspectionIdentity, bucket.id, view);
    final bars = [
      for (final window in bucket.windows)
        ChartBar(
          identity: (window.durationMinutes, window.label),
          label: quotaWindowLabel(AppCopy.of(context), window),
          value: _value(window),
          detail:
              '${_resetTime(AppCopy.of(context), window, settings, useLocalTime)} · ${_resetState(AppCopy.of(context), window, now)}',
        ),
    ];
    return view == 'reset'
        ? MonitorBarChart(
            showInspection: false,
            inspectionIdentity: identity,
            bars: bars,
            horizontal: true,
            compactMeters: true,
            hoverDetails: false,
            unit: AppCopy.of(context).text('accounts.hours'),
          )
        : MonitorRingChart(
            showInspection: false,
            inspectionIdentity: identity,
            bars: bars,
            hoverDetails: false,
          );
  }
}

String _resetTime(
  AppCopy copy,
  UsageWindow window,
  LauncherSettings settings,
  bool local,
) {
  if (window.resetsAt == null) return copy.text('accounts.resetUnavailable');
  try {
    return usageResetTime(settings, window.resetsAt!, local: local);
  } catch (_) {
    return copy.text('accounts.invalidTimeZone');
  }
}

String _resetState(AppCopy copy, UsageWindow window, DateTime now) =>
    window.resetsAt != null && !window.resetsAt!.isAfter(now)
    ? copy.text('accounts.expired')
    : _quotaCountdown(copy, window.resetsAt, now);

// These detail and clipboard timestamps are provenance facts. Keep their exact
// ISO representation (including fractional seconds) independent of UI language.
class _AccountUsageInformation extends StatelessWidget {
  const _AccountUsageInformation({required this.controller});
  final AccountUsageController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 500,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: FCard(
            style: FCardStyleDelta.delta(
              decoration: DecorationDelta.shapeDelta(
                color: context.theme.colors.card,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final data = controller.data;
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          AppCopy.of(context).text('accounts.usage.details'),
                        ),
                        const SizedBox(height: 12),
                        if (data != null) ...[
                          Text(
                            data.email ??
                                AppCopy.of(context)
                                    .text('accounts.usage.signedIn'),
                          ),
                          if (data.plan != null) Text(data.plan!.toUpperCase()),
                          _TokenMetric(
                            label: AppCopy.of(context)
                                .text('accounts.usage.lifetime'),
                            value: data.lifetimeTokens,
                          ),
                          _TokenMetric(
                            label: data.latestDate == null
                                ? AppCopy.of(context)
                                      .text('accounts.usage.latestUnknown')
                                : AppCopy.of(context).text(
                                    'accounts.usage.latestDay',
                                    args: {'date': data.latestDate},
                                  ),
                            value: data.latestDailyTokens,
                          ),
                          if (data.tokensFetchedAt == null)
                            Text(
                              AppCopy.of(context)
                                  .text('accounts.usage.tokensTimeUnknown'),
                            ),
                          if (!data.detailsIncluded)
                            Text(
                              AppCopy.of(context)
                                  .text('accounts.usage.cachedTokens'),
                            ),
                          Text(
                            AppCopy.of(context).text(
                              'accounts.usage.limitsUpdated',
                              args: {
                                'time': data.fetchedAt
                                    .toLocal()
                                    .toIso8601String(),
                              },
                            ),
                          ),
                          if (data.tokensFetchedAt != null)
                            Text(
                              AppCopy.of(context).text(
                                'accounts.usage.tokensUpdated',
                                args: {
                                  'time': data.tokensFetchedAt!
                                      .toLocal()
                                      .toIso8601String(),
                                },
                              ),
                            ),
                          if (data.limitsError != null)
                            Text(
                              AppCopy.of(context).text(
                                'accounts.usage.limitsDetails',
                                args: {
                                  'error': _usageDetailsError(
                                    context,
                                    data.limitsError,
                                    data.limitsErrorKind,
                                  ),
                                },
                              ),
                            ),
                          if (data.tokensError != null)
                            Text(
                              AppCopy.of(context).text(
                                'accounts.usage.tokenDetails',
                                args: {
                                  'error': _usageDetailsError(
                                    context,
                                    data.tokensError,
                                    data.tokensErrorKind,
                                  ),
                                },
                              ),
                            ),
                          for (final bucket in data.buckets)
                            for (final window in bucket.windows)
                              if (window.resetsAt != null)
                                Text(
                                  AppCopy.of(context).text(
                                    'accounts.usage.windowReset',
                                    args: {
                                      'bucket': bucket.label,
                                      'window': quotaWindowLabel(
                                        AppCopy.of(context),
                                        window,
                                      ),
                                      'time': window.resetsAt!
                                          .toUtc()
                                          .toIso8601String(),
                                    },
                                  ),
                                ),
                        ],
                        if (controller.error != null)
                          Text(_controllerUsageError(context, controller)),
                        if (controller.preferencesError != null)
                          Text(
                            _preferenceError(
                              context,
                              controller.preferencesError!,
                            ),
                          ),
                        if (controller.lastAttempt != null)
                          Text(
                            AppCopy.of(context).text(
                              'accounts.usage.lastAttempt',
                              args: {
                                'time': controller.lastAttempt!
                                    .toLocal()
                                    .toIso8601String(),
                              },
                            ),
                          ),
                        if (controller.nextRefreshAt != null)
                          Text(
                            AppCopy.of(context).text(
                              'accounts.usage.nextAttempt',
                              args: {
                                'time': controller.nextRefreshAt!
                                    .toLocal()
                                    .toIso8601String(),
                              },
                            ),
                          ),
                        const SizedBox(height: 12),
                        FButton(
                          variant: FButtonVariant.outline,
                          onPress: () => Clipboard.setData(
                            ClipboardData(
                              text: [
                                if (data?.email != null) data!.email!,
                                if (data != null) ...[
                                  data.plan ??
                                      AppCopy.of(context)
                                          .text('accounts.usage.unknownPlan'),
                                  AppCopy.of(context).text(
                                    'accounts.usage.lifetimeValue',
                                    args: {
                                      'value': _tokenCount(
                                        context,
                                        data.lifetimeTokens,
                                      ),
                                    },
                                  ),
                                  AppCopy.of(context).text(
                                    'accounts.usage.latestValue',
                                    args: {
                                      'date':
                                          data.latestDate ??
                                          AppCopy.of(
                                            context,
                                          ).text('accounts.usage.unknownDate'),
                                      'value': _tokenCount(
                                        context,
                                        data.latestDailyTokens,
                                      ),
                                    },
                                  ),
                                ],
                                if (data != null)
                                  AppCopy.of(context).text(
                                    'accounts.usage.limitsUpdated',
                                    args: {
                                      'time': data.fetchedAt
                                          .toLocal()
                                          .toIso8601String(),
                                    },
                                  ),
                                if (data?.tokensFetchedAt != null)
                                  AppCopy.of(context).text(
                                    'accounts.usage.tokensUpdated',
                                    args: {
                                      'time': data!.tokensFetchedAt!
                                          .toLocal()
                                          .toIso8601String(),
                                    },
                                  ),
                                if (data?.limitsError != null)
                                  AppCopy.of(context).text(
                                    'accounts.usage.limitsDetails',
                                    args: {
                                      'error': _usageDetailsError(
                                        context,
                                        data!.limitsError,
                                        data.limitsErrorKind,
                                      ),
                                    },
                                  ),
                                if (data?.tokensError != null)
                                  AppCopy.of(context).text(
                                    'accounts.usage.tokenDetails',
                                    args: {
                                      'error': _usageDetailsError(
                                        context,
                                        data!.tokensError,
                                        data.tokensErrorKind,
                                      ),
                                    },
                                  ),
                                if (controller.error != null)
                                  _controllerUsageError(context, controller),
                                if (controller.preferencesError != null)
                                  _preferenceError(
                                    context,
                                    controller.preferencesError!,
                                  ),
                              ].join('\n'),
                            ),
                          ),
                          child: Text(
                            AppCopy.of(context)
                                .text('accounts.usage.copyDetails'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FButton(
                          onPress: () => Navigator.of(context).pop(),
                          child: Text(
                            AppCopy.of(context).text('accounts.close'),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TokenMetric extends StatelessWidget {
  const _TokenMetric({required this.label, required this.value});
  final String label;
  final int? value;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        label,
        style: context.theme.typography.body.sm.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      ),
      Text(
        _tokenCount(context, value),
        style: context.theme.typography.body.md.copyWith(
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

/// Duration labels are generated by this UI; bucket and model names stay raw.
String quotaWindowLabel(AppCopy copy, UsageWindow window) {
  if (!copy.isEnglish) return window.label;
  final minutes = window.durationMinutes;
  if (minutes == null || minutes <= 0) {
    return copy.text('accounts.window.quota');
  }
  if (minutes == 10080) return copy.text('accounts.window.weekly');
  final (count, unit) = minutes % 1440 == 0
      ? (minutes ~/ 1440, 'days')
      : minutes % 60 == 0
      ? (minutes ~/ 60, 'hours')
      : (minutes, 'minutes');
  return copy.text('accounts.window.$unit', args: {'count': count});
}

String _quotaCountdown(AppCopy copy, DateTime? reset, DateTime now) {
  if (!copy.isEnglish) return resetCountdown(reset, now);
  if (reset == null) return copy.text('accounts.resetUnavailable');
  final seconds = reset.difference(now).inSeconds;
  if (seconds <= 0) return copy.text('accounts.expired');
  final minutes = (seconds / 60).ceil().clamp(1, 2147483647);
  final duration = minutes >= 1440
      ? '${minutes ~/ 1440} d ${minutes % 1440 ~/ 60} h'
      : minutes >= 60
      ? '${minutes ~/ 60} h ${minutes % 60} min'
      : '$minutes min';
  return copy.text('accounts.resetsIn', args: {'duration': duration});
}

String _tokenCount(BuildContext context, int? value) => value == null
    ? AppCopy.of(context).text('accounts.usage.noData')
    : AppCopy.of(context).integer(value);

String _usageDetailsError(BuildContext context, String? raw, String? kind) {
  final copy = AppCopy.of(context);
  // Cache-unavailable placeholders are application copy. Actual backend error
  // details, including their source language, remain available verbatim.
  if (raw == '额度暂不可用') {
    return copy.text('accounts.usage.cachedLimitsUnavailable');
  }
  if (raw == '用量暂不可用') {
    return copy.text('accounts.usage.cachedTokensUnavailable');
  }
  return raw ?? kind ?? copy.text('common.unknown');
}

String _controllerUsageError(
  BuildContext context,
  AccountUsageController controller,
) {
  final source = controller.sources?.selected;
  if (source?.errorKind != null) {
    return AppCopy.of(context).text(switch (source!.errorKind) {
      'auth_required' || 'auth_failed' => 'accounts.sourceError.auth',
      'network' => 'accounts.sourceError.network',
      'rate_limited' => 'accounts.sourceError.rate',
      'timeout' => 'accounts.sourceError.timeout',
      'unsupported' || 'isolation_failed' => 'accounts.sourceError.unsupported',
      'cancelled' => 'accounts.sourceError.cancelled',
      'busy' => 'accounts.sourceError.busy',
      _ => 'accounts.sourceError.unavailable',
    });
  }
  return controller.error ?? '';
}

String _preferenceError(BuildContext context, String raw) => switch (raw) {
  '监控设置读取失败，已使用默认值；原文件未改动。' => AppCopy.of(
    context,
  ).text('accounts.usage.preferencesRead'),
  '监控偏好已生效，但保存失败；请检查文件夹写入权限。' => AppCopy.of(
    context,
  ).text('accounts.usage.preferencesWrite'),
  _ => raw,
};
