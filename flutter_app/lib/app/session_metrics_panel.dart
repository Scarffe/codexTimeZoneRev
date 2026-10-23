import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/session_metrics_controller.dart';
import '../services/session_activity_timeline.dart';
import '../services/session_measurement_quality.dart';
import 'monitor_presentation.dart';
import 'session_timing_panel.dart';

class SessionMetricsPanel extends StatelessWidget {
  const SessionMetricsPanel({super.key, required this.controller});
  final SessionMetricsController controller;

  String _short(Object? value, [int limit = 28]) {
    final text = (value ?? '未知').toString();
    return text.length > limit ? '${text.substring(0, limit - 1)}…' : text;
  }

  String _project(Object? value) => _short(
    value
        ?.toString()
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .lastOrNull,
    18,
  );

  Map<String, String> _choices() {
    final result = <String, String>{};
    for (final s in controller.sessions) {
      final id = (s['id'] ?? '').toString();
      final tag = id.length > 8 ? id.substring(id.length - 8) : id;
      final base =
          '${_short(controller.sessionName(s))} · ${_project(s['cwd'])} · $tag';
      var label = base;
      var suffix = 2;
      while (result.containsKey(label)) {
        label = '$base · ${suffix++}';
      }
      result[label] = s['path'] as String;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final last = controller.last;
      final quality = controller.measurementQuality;
      final analysis = last?['analysis'] is Map<String, dynamic>
          ? last!['analysis'] as Map<String, dynamic>
          : null;
      final timeline = analysis?['timeline'];
      final turnIdentity = (
        controller.selected,
        controller.data?['logEpoch'],
        last?['turnId'] ??
            (
              timeline is Map ? timeline['startEpochMs'] : null,
              timeline is Map ? timeline['endEpochMsExclusive'] : null,
            ),
      );
      final duration = last?['durationMs'];
      final first = last?['firstTokenMs'];
      final validDuration = SessionActivityTimelineData.isSafeMilliseconds(
        duration,
      );
      final recordedFirst = SessionActivityTimelineData.isSafeMilliseconds(
        first,
      );
      final contradicts =
          recordedFirst && validDuration && (first as int) > (duration as int);
      String ms(Object? value, bool valid) =>
          valid ? '${((value as int) / 1000).toStringAsFixed(3)} s' : '不可用';
      final choices = _choices();
      final info = controller.sourceInfo;
      final listedSelection = controller.selectorValue;
      final selectedMetadata = controller.sessions
          .where((s) => s['path'] == listedSelection)
          .firstOrNull;
      return FCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '会话回合统计',
                      style: context.theme.typography.display.sm,
                    ),
                  ),
                  MonitorIconAction(
                    key: const ValueKey('session-refresh'),
                    label: controller.listing ? '正在列出会话' : '刷新本机会话列表',
                    icon: FLucideIcons.refreshCw,
                    onPress: controller.listing ? null : controller.list,
                  ),
                ],
              ),
              const Text('本地 · 只读'),
              const SizedBox(height: 8),
              if (controller.sessions.isNotEmpty)
                FSelect<String>.search(
                  key: const ValueKey('session-selector'),
                  label: const Text('最近会话'),
                  items: choices,
                  filter: (query) {
                    final q = query.trim().toLowerCase();
                    return controller.sessions
                        .where(
                          (s) => [
                            controller.sessionName(s),
                            s['cwd'],
                            s['id'],
                            s['path'],
                          ].join(' ').toLowerCase().contains(q),
                        )
                        .map((s) => s['path'] as String);
                  },
                  control: FSelectControl.lifted(
                    value: controller.selectorValue,
                    onChange: controller.select,
                  ),
                ),
              if (controller.selected != null &&
                  controller.selectorValue == null)
                const Text('当前采集会话不在最近列表中；仍继续采集，可选择其他会话。'),
              const SizedBox(height: 8),
              if (controller.selected != null)
                Text(
                  '${_short(info == null ? '等待核验' : controller.sessionName(info))} · ${_project(info?['cwd'])}',
                  key: const ValueKey('session-short-identity'),
                ),
              Text(
                '会话状态：${controller.stateLabel}',
                key: const ValueKey('session-state'),
              ),
              if (controller.listError != null) const Text('列表刷新失败；错误详情可展开查看'),
              if (controller.selectionError != null)
                Text(controller.selectionError!),
              if (controller.error != null)
                Text(
                  '会话读取失败；错误详情可展开查看',
                  style: TextStyle(color: context.theme.colors.destructive),
                ),
              if (controller.selected == null)
                const Text('请选择会话；不会自动猜测当前对话。')
              else ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.outline,
                    onPress: () => controller.select(null),
                    prefix: const Icon(FLucideIcons.square),
                    child: const Text('停止会话采集'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${controller.error != null && last != null
                      ? '保留的上轮样本 · 非当前状态'
                      : controller.data?['catchingUp'] == true
                      ? '正在读取历史 · 尚无可用上轮'
                      : last == null
                      ? '尚无完成回合'
                      : '上轮指标'} · 含工具与等待',
                  style: context.theme.typography.body.sm.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth >= 570
                        ? (constraints.maxWidth - 24) / 3
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _Metric(
                          width: width,
                          icon: FLucideIcons.gauge,
                          label: '回合均值',
                          value: quality.verifiedTokensPerSecond == null
                              ? '不可用'
                              : '${quality.verifiedTokensPerSecond!.toStringAsFixed(2)} tokens/s',
                          valueKey: 'session-rate-value',
                        ),
                        _Metric(
                          width: width,
                          icon: FLucideIcons.timer,
                          label: '首模型 token 等待',
                          value: ms(first, recordedFirst && !contradicts),
                          valueKey: 'session-first-token-value',
                          note: '可能含推理',
                        ),
                        _Metric(
                          width: width,
                          icon: FLucideIcons.clock,
                          label: '完整回合',
                          value: ms(duration, validDuration),
                          valueKey: 'session-duration-value',
                          note: '输出 ${last?['outputTokens'] ?? '不可用'} tokens',
                        ),
                      ],
                    );
                  },
                ),
                if (contradicts) const Text('首模型 token 不可用：超过完整回合耗时'),
                const SizedBox(height: 8),
                Text(
                  '样本质量：${quality.label}',
                  key: const ValueKey('session-quality'),
                ),
                if (controller.data?['catchingUp'] != true)
                  SessionTimingPanel(
                    key: const ValueKey('session-timing-panel'),
                    analysis: analysis,
                    durationMs: duration,
                    firstTokenMs: first,
                    turnIdentity: turnIdentity,
                  ),
                const SizedBox(height: 8),
                MonitorDisclosure(
                  key: const ValueKey('session-source-disclosure'),
                  label: '会话来源',
                  toggleKey: const ValueKey('session-source-details'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '来源项目：${info?['cwd'] ?? '未知（尚未成功读取）'}',
                        key: const ValueKey('session-source'),
                      ),
                      Text(
                        '会话：${info == null ? '等待核验' : controller.sessionName(info)}',
                      ),
                      Text('会话 ID：${info?['id'] ?? '未知'}'),
                      Text('日志：${controller.selected}'),
                      Text('上轮身份：${last?['turnId'] ?? '未知'}'),
                      Text(
                        '日志写入时间：${controller.activityLabel(selectedMetadata ?? const {})}',
                      ),
                      Text(
                        '最近成功读取：${controller.lastRead?.toLocal().toString().split('.').first ?? '尚未成功读取'}',
                      ),
                      const Text(
                        '固定跟踪所选会话；列表按日志写入时间排序，不据此推断模型活动。无标题时使用会话 ID。仅显示最近 100 个本地主会话。',
                      ),
                    ],
                  ),
                ),
                _MeasurementDetails(
                  key: const ValueKey('session-quality-disclosure'),
                  quality: quality,
                  reasoningTokens: last?['reasoningTokens'],
                ),
              ],
              if (controller.error != null || controller.listError != null)
                MonitorDisclosure(
                  key: const ValueKey('session-error-disclosure'),
                  label: '错误详情',
                  toggleKey: const ValueKey('session-error-details'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (controller.listError != null)
                        Text('列表刷新失败：${controller.listError}'),
                      if (controller.error != null) Text(controller.error!),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    required this.valueKey,
    this.note,
  });
  final double width;
  final IconData icon;
  final String label, value, valueKey;
  final String? note;
  @override
  Widget build(BuildContext context) {
    final secondary = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final unitBoundary = value.lastIndexOf(' ');
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(icon, size: 16, color: context.theme.colors.mutedForeground),
              Text(label, style: secondary),
            ],
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: unitBoundary < 0
                      ? value
                      : value.substring(0, unitBoundary),
                  style: context.theme.typography.display.xl2.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (unitBoundary >= 0)
                  TextSpan(
                    text: value.substring(unitBoundary),
                    style: secondary,
                  ),
              ],
            ),
            key: ValueKey(valueKey),
          ),
          if (note != null) Text(note!, style: secondary),
        ],
      ),
    );
  }
}

class _MeasurementDetails extends StatelessWidget {
  const _MeasurementDetails({
    super.key,
    required this.quality,
    this.reasoningTokens,
  });
  final SessionMeasurementQuality quality;
  final Object? reasoningTokens;
  @override
  Widget build(BuildContext context) => MonitorDisclosure(
    label: '统计来源与核验详情',
    toggleKey: const ValueKey('session-measurement-details'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final reason in quality.reasons) Text(reason),
        Text('统计来源：${quality.sourceLabel}'),
        const Text('口径：回合输出 token ÷ 完整回合耗时。包含工具与等待；推理已包含在输出中时不重复相加。'),
        Text('推理：${reasoningTokens ?? '不可用'} tokens'),
        Text(
          '日志报告值 · 未充分核验：${quality.reportedTokensPerSecond?.toStringAsFixed(2) ?? '不可用'}${quality.reportedTokensPerSecond == null ? '' : ' tokens/s'}',
        ),
        const Text('已核验汇总按会话、模型、推理强度与服务层级分组，以总输出除以总耗时计算。'),
        if (quality.verifiedGroups.isEmpty) const Text('暂无可用的已核验分组'),
        for (final group in quality.verifiedGroups)
          Text(
            '会话 ${group['sessionId']} · ${group['model']} · ${group['effort']} · ${group['serviceTier']}：${group['turnCount']} 回合，${group['outputTokens']} tokens / ${((group['durationMs'] as num) / 1000).toStringAsFixed(3)} s = ${(group['tokensPerSecond'] as num).toStringAsFixed(2)} tokens/s',
          ),
      ],
    ),
  );
}
