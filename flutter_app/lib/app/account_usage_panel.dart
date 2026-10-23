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
      barrierLabel: '关闭账号用量详情',
      pageBuilder: (_, _, _) =>
          _AccountUsageInformation(controller: widget.controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
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
                  '账户额度',
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
                label: '额度视图',
                value: _view,
                items: const {'剩余': 'remaining', '已用': 'used', '距重置': 'reset'},
                onChanged: (value) => setState(() => _view = value),
              ),
              if (data.buckets.length > 1)
                MonitorChoice(
                  key: const ValueKey('account-quota-bucket'),
                  inline: true,
                  label: '额度组',
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
                label: '重置时间基准',
                value: controller.useLocalTime ? 'local' : 'node',
                items: const {'节点时间': 'node', '本地时间': 'local'},
                onChanged: (value) => controller.setLocalTime(value == 'local'),
              ),
            ],
            MonitorIconAction(
              key: const ValueKey('account-usage-info'),
              label: '账号用量详情',
              icon: FLucideIcons.info,
              onPress: _showInformation,
            ),
            FButton.icon(
              key: const ValueKey('query-account-usage'),
              semanticsLabel: controller.busy ? '正在查询用量…' : '查询账号用量',
              variant: FButtonVariant.ghost,
              onPress:
                  controller.busy ||
                      widget.launcher.preview ||
                      controller.offlineTrial
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
              onPress: widget.launcher.preview || controller.offlineTrial
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
              child: Text(controller.monitoring ? '暂停自动刷新' : '开启自动刷新'),
            ),
          ],
        ),
        if (controller.busy) ...[
          const SizedBox(height: 5),
          const FProgress(),
          Text('正在查询用量…', style: muted),
        ],
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            if (controller.error != null)
              Text(data == null ? '查询失败' : '查询失败 · 上次观测', style: muted),
            if (controller.preferencesError != null)
              Text('监控设置保存失败 · 查看详情', style: muted),
            if (controller.failures > 0 && controller.nextRefreshAt != null)
              Text(
                '失败退避中，最早重试：${ClockReading.fromDate(controller.nextRefreshAt!.toLocal()).time}',
                style: muted,
              ),
            if (data != null && controller.stale)
              Text('上次观测 · 数据已过期', style: muted),
            if (data?.limitsError != null) Text('额度更新失败 · 查看详情', style: muted),
            if (data?.tokensError != null)
              Text('token 更新失败 · 查看详情', style: muted),
          ],
        ),
        const SizedBox(height: 6),
        if (data == null)
          Text(controller.busy ? '正在读取额度' : '尚无额度数据', style: muted)
        else if (windows.isEmpty)
          Text('额度信息暂不可用', style: muted)
        else
          MonitorBarChart(
            key: const ValueKey('account-quota-chart'),
            bars: [
              for (final window in windows)
                ChartBar(
                  label: window.label,
                  value: _chartValue(window, now),
                  detail:
                      '${_resetTime(window, settings, controller.useLocalTime)} · ${_resetState(window, now)}',
                ),
            ],
            horizontal: true,
            compactMeters: true,
            unit: _view == 'reset' ? '小时' : '%',
            maxValue: _view == 'reset' ? null : 100,
          ),
        if (data == null && !controller.busy)
          Text(
            controller.monitoring ? '正在自动监控当前账号额度。' : '点击按钮查询，或开启自动监控。',
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

  double? _chartValue(UsageWindow window, DateTime now) {
    if (_view == 'reset') {
      final reset = window.resetsAt;
      if (reset == null || !reset.isAfter(now)) return null;
      return reset.difference(now).inMilliseconds /
          Duration.millisecondsPerHour;
    }
    final used = window.usedPercent;
    if (used == null) return null;
    return _view == 'used' ? used : 100 - used;
  }

  @override
  void dispose() {
    _clock?.cancel();
    _scroll.dispose();
    super.dispose();
  }
}

String _resetTime(UsageWindow window, LauncherSettings settings, bool local) {
  if (window.resetsAt == null) return '重置时间暂不可用';
  try {
    return usageResetTime(settings, window.resetsAt!, local: local);
  } catch (_) {
    return '请选择有效的显示时区';
  }
}

String _resetState(UsageWindow window, DateTime now) =>
    window.resetsAt != null && !window.resetsAt!.isAfter(now)
    ? '到期 · 待查询'
    : resetCountdown(window.resetsAt, now);

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
                        const Text('账号用量详情'),
                        const SizedBox(height: 12),
                        if (data != null) ...[
                          Text(data.email ?? '已登录 ChatGPT 账号'),
                          if (data.plan != null) Text(data.plan!.toUpperCase()),
                          _TokenMetric(
                            label: '累计 token',
                            value: data.lifetimeTokens,
                          ),
                          _TokenMetric(
                            label: data.latestDate == null
                                ? '最近一天 · 日期未知'
                                : '最近一天 · ${data.latestDate}',
                            value: data.latestDailyTokens,
                          ),
                          if (data.tokensFetchedAt == null)
                            const Text('token 更新时间未知'),
                          if (!data.detailsIncluded) const Text('token 数据来自缓存'),
                          Text(
                            '额度更新时间：${data.fetchedAt.toLocal().toIso8601String()}',
                          ),
                          if (data.tokensFetchedAt != null)
                            Text(
                              'token 更新时间：${data.tokensFetchedAt!.toLocal().toIso8601String()}',
                            ),
                          if (data.limitsError != null)
                            Text('额度：${data.limitsError}'),
                          if (data.tokensError != null)
                            Text('token：${data.tokensError}'),
                          for (final bucket in data.buckets)
                            for (final window in bucket.windows)
                              if (window.resetsAt != null)
                                Text(
                                  '${bucket.label} · ${window.label}重置：${window.resetsAt!.toUtc().toIso8601String()}',
                                ),
                        ],
                        if (controller.error != null) Text(controller.error!),
                        if (controller.preferencesError != null)
                          Text(controller.preferencesError!),
                        if (controller.lastAttempt != null)
                          Text(
                            '最近尝试：${controller.lastAttempt!.toLocal().toIso8601String()}',
                          ),
                        if (controller.nextRefreshAt != null)
                          Text(
                            '下次尝试：${controller.nextRefreshAt!.toLocal().toIso8601String()}',
                          ),
                        const SizedBox(height: 12),
                        FButton(
                          variant: FButtonVariant.outline,
                          onPress: () => Clipboard.setData(
                            ClipboardData(
                              text: [
                                if (data?.email != null) data!.email!,
                                if (data != null) ...[
                                  data.plan ?? '套餐未知',
                                  '累计 token：${tokenCount(data.lifetimeTokens)}',
                                  '最近一天：${data.latestDate ?? '日期未知'} · ${tokenCount(data.latestDailyTokens)}',
                                ],
                                if (data != null)
                                  '额度更新时间：${data.fetchedAt.toLocal().toIso8601String()}',
                                if (data?.tokensFetchedAt != null)
                                  'token 更新时间：${data!.tokensFetchedAt!.toLocal().toIso8601String()}',
                                if (data?.limitsError != null)
                                  '额度：${data!.limitsError}',
                                if (data?.tokensError != null)
                                  'token：${data!.tokensError}',
                                if (controller.error != null) controller.error!,
                                if (controller.preferencesError != null)
                                  controller.preferencesError!,
                              ].join('\n'),
                            ),
                          ),
                          child: const Text('复制详情'),
                        ),
                        const SizedBox(height: 8),
                        FButton(
                          onPress: () => Navigator.of(context).pop(),
                          child: const Text('关闭'),
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
        tokenCount(value),
        style: context.theme.typography.body.md.copyWith(
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}
