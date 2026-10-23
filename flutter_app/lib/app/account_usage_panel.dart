import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

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
  void _syncClock() {
    if (widget.controller.data == null) {
      _clock?.cancel();
      _clock = null;
    } else {
      // Only the displayed countdown updates; account reads remain explicit.
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final data = controller.data;
    final settings = widget.launcher.settings;
    final muted = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.busy) ...[
          const FProgress(),
          const SizedBox(height: 10),
          Text('正在查询用量…', style: muted),
        ],
        if (controller.error != null)
          FAlert(
            variant: FAlertVariant.destructive,
            title: const Text('查询失败'),
            subtitle: Text(controller.error!),
          )
        else if (data == null && !controller.busy) ...[
          Text('查看当前 Codex 账号的额度与 token 用量。', style: muted),
          const SizedBox(height: 8),
          Text(
            controller.monitoring ? '正在自动监控当前账号额度。' : '点击按钮查询，或开启自动监控。',
            style: muted,
          ),
        ],
        if (data != null) ...[
          if (controller.stale) Text('上次成功结果 · 当前数据可能已过期', style: muted),
          Row(
            children: [
              Expanded(
                child: Text(
                  data.email ?? '已登录 ChatGPT 账号',
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.body.sm,
                ),
              ),
              if (data.plan != null) ...[
                const SizedBox(width: 8),
                FBadge(child: Text(data.plan!.toUpperCase())),
              ],
            ],
          ),
          for (final bucket in data.buckets) ...[
            const SizedBox(height: 12),
            if (data.buckets.length > 1) ...[
              Text(bucket.label, style: context.theme.typography.body.sm),
              const SizedBox(height: 6),
            ],
            if (bucket.windows.isEmpty)
              Text('额度信息暂不可用', style: muted)
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final windows = [
                    for (final window in bucket.windows)
                      _UsageWindowView(
                        window: window,
                        settings: settings,
                        local: controller.useLocalTime,
                      ),
                  ];
                  if (windows.length == 2 && constraints.maxWidth >= 300) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: windows[0]),
                        const SizedBox(width: 16),
                        Expanded(child: windows[1]),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < windows.length; i++) ...[
                        if (i != 0) const SizedBox(height: 12),
                        windows[i],
                      ],
                    ],
                  );
                },
              ),
          ],
          if (data.limitsError != null) ...[
            const SizedBox(height: 10),
            Text(data.limitsError!, style: muted),
          ] else if (data.buckets.isEmpty) ...[
            const SizedBox(height: 10),
            Text('额度信息暂不可用', style: muted),
          ],
          if (data.tokensError != null) ...[
            const SizedBox(height: 8),
            Text(data.tokensError!, style: muted),
          ],
          const SizedBox(height: 10),
          Text(
            '查询于 ${ClockReading.fromDate(data.fetchedAt.toLocal()).time} · ${controller.monitoring ? '自动监控' : '手动更新'}',
            style: muted,
          ),
        ],
      ],
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(FLucideIcons.gauge, size: 18),
                const SizedBox(width: 8),
                Text(
                  '账号用量',
                  style: context.theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FTooltip(
                  tipBuilder: (context, _) => const Text('查询账号用量'),
                  child: FButton.icon(
                    key: const ValueKey('query-account-usage'),
                    semanticsLabel: controller.busy ? '正在查询用量…' : '查询账号用量',
                    variant: FButtonVariant.ghost,
                    onPress: controller.busy || widget.launcher.preview
                        ? null
                        : () {
                            if (_scroll.hasClients) _scroll.jumpTo(0);
                            controller.query(widget.launcher.effectivePath);
                          },
                    child: const Icon(FLucideIcons.refreshCw),
                  ),
                ),
                FButton(
                  key: const ValueKey('toggle-usage-monitor'),
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.ghost,
                  selected: controller.monitoring,
                  prefix: Icon(
                    controller.monitoring
                        ? FLucideIcons.pause
                        : FLucideIcons.play,
                    size: 16,
                  ),
                  onPress: widget.launcher.preview
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
          ],
        ),
        if (controller.preferencesError != null)
          Text(controller.preferencesError!, style: muted),
        if (controller.failures > 0 && controller.nextRefreshAt != null)
          Text(
            '失败退避中，最早重试：${ClockReading.fromDate(controller.nextRefreshAt!.toLocal()).time}',
            style: muted,
          ),
        const SizedBox(height: 10),
        details,
        const SizedBox(height: 8),
        MonitorDisclosure(
          label: '用量与时间详情',
          toggleKey: const ValueKey('account-details-toggle'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (data != null) ...[
                Wrap(
                  spacing: 24,
                  runSpacing: 10,
                  children: [
                    _TokenMetric(label: '累计 token', value: data.lifetimeTokens),
                    _TokenMetric(
                      label: data.latestDate == null
                          ? '每日 token'
                          : '最近一天 · ${data.latestDate}',
                      value: data.latestDailyTokens,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '完整查询时间：${data.fetchedAt.toLocal().toIso8601String()}',
                  style: muted,
                ),
                if (data.tokensFetchedAt != null)
                  Text(
                    'token 统计更新：${data.tokensFetchedAt!.toLocal().toIso8601String()}',
                    style: muted,
                  ),
              ],
              if (controller.nextRefreshAt != null)
                Text(
                  '下次尝试：${controller.nextRefreshAt!.toLocal().toIso8601String()}',
                  style: muted,
                ),
              const SizedBox(height: 12),
              Text('重置时间基准', style: context.theme.typography.body.sm),
              const SizedBox(height: 6),
              FSelect<String>(
                key: const ValueKey('usage-time-basis'),
                items: const {'节点时间': 'node', '本地时间': 'local'},
                control: FSelectControl.lifted(
                  value: controller.useLocalTime ? 'local' : 'node',
                  onChange: (value) {
                    if (value != null) {
                      controller.setLocalTime(value == 'local');
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                controller.useLocalTime
                    ? '本地时间 · 系统时区'
                    : '节点时间 · ${settings.mode == 'zone' ? settings.zoneId : offsetLabel(settings.offset * 60)}',
                style: muted,
              ),
              if (data != null)
                for (final bucket in data.buckets)
                  for (final window in bucket.windows)
                    if (window.resetsAt != null)
                      Text(
                        '${bucket.label} · ${window.label}重置：${window.resetsAt!.toUtc().toIso8601String()}',
                        style: muted,
                      ),
            ],
          ),
        ),
      ],
    );
    return FCard(
      key: const ValueKey('account-usage-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
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

class _UsageWindowView extends StatelessWidget {
  const _UsageWindowView({
    required this.window,
    required this.settings,
    required this.local,
  });
  final UsageWindow window;
  final LauncherSettings settings;
  final bool local;
  String get resetTime {
    final reset = window.resetsAt;
    if (reset == null) return '重置时间暂不可用';
    try {
      return usageResetTime(settings, reset, local: local);
    } catch (_) {
      return '请选择有效的显示时区';
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = window.usedPercent;
    final muted = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(window.label, style: context.theme.typography.body.sm),
        const SizedBox(height: 4),
        Text(
          percent == null
              ? '用量暂不可用'
              : '已用 ${percent.toStringAsFixed(percent % 1 == 0 ? 0 : 1)}%',
          style: context.theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (percent != null) ...[
          const SizedBox(height: 6),
          FDeterminateProgress(
            value: percent / 100,
            semanticsLabel: window.label,
          ),
        ],
        const SizedBox(height: 6),
        Text(resetTime, style: muted),
        if (window.resetsAt != null) ...[
          const SizedBox(height: 4),
          Text(resetCountdown(window.resetsAt, DateTime.now()), style: muted),
        ],
      ],
    );
  }
}

class _TokenMetric extends StatelessWidget {
  const _TokenMetric({required this.label, required this.value});
  final String label;
  final int? value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: context.theme.typography.body.sm.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      ),
      const SizedBox(height: 4),
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
