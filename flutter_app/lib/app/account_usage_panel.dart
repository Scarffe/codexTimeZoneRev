import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

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
          Text('正在读取登录账号与用量…', style: muted),
        ] else if (controller.error != null)
          FAlert(
            variant: FAlertVariant.destructive,
            title: const Text('查询失败'),
            subtitle: Text(controller.error!),
          )
        else if (data == null) ...[
          Text('查看当前 Codex 账号的额度与 token 用量。', style: muted),
          const SizedBox(height: 8),
          Text('点击按钮后查询，不会自动获取或刷新。', style: muted),
        ] else ...[
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
          const FDivider(
            style: FDividerStyleDelta.delta(
              padding: EdgeInsetsGeometryDelta.value(
                EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
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
          if (data.tokensError != null) ...[
            const SizedBox(height: 8),
            Text(data.tokensError!, style: muted),
          ],
          const SizedBox(height: 10),
          Text(
            '查询于 ${ClockReading.fromDate(data.fetchedAt.toLocal()).time} · 手动更新',
            style: muted,
          ),
        ],
      ],
    );
    return FCard(
      key: const ValueKey('account-usage-card'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  '账号用量',
                  style: context.theme.typography.display.lg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                FButton(
                  key: const ValueKey('query-account-usage'),
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.outline,
                  onPress: controller.busy || widget.launcher.preview
                      ? null
                      : () {
                          if (_scroll.hasClients) _scroll.jumpTo(0);
                          controller.query(widget.launcher.effectivePath);
                        },
                  prefix: const Icon(FLucideIcons.refreshCw),
                  child: Text(controller.busy ? '正在查询用量…' : '查询账号用量'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('重置时间', style: context.theme.typography.body.sm),
                const SizedBox(width: 12),
                Expanded(
                  child: FSelect<String>(
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
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.bounded)
              Expanded(
                child: RawScrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  thumbColor: context.theme.colors.mutedForeground.withValues(
                    alpha: 0.45,
                  ),
                  thickness: 4,
                  radius: const Radius.circular(4),
                  child: SingleChildScrollView(
                    key: const ValueKey('account-usage-details'),
                    controller: _scroll,
                    primary: false,
                    padding: const EdgeInsets.only(right: 8),
                    child: details,
                  ),
                ),
              )
            else
              details,
            const SizedBox(height: 8),
            Text(
              controller.useLocalTime
                  ? '本地时间 · 系统时区'
                  : '节点时间 · ${settings.mode == 'zone' ? settings.zoneId : offsetLabel(settings.offset * 60)}',
              style: muted,
            ),
          ],
        ),
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
