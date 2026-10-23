import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/benchmark.dart';
import '../state/benchmark_controller.dart';
import 'monitor_information.dart';
import 'monitor_presentation.dart';

const _labels = {
  'ttftMs': 'TTFT · 首段响应',
  'ttfoMs': 'TTFO · 首段可见输出',
  'streamTokensPerSecond': '流式输出速率',
  'e2eTokensPerSecond': '端到端速率',
  'fullResponseTokensPerSecond': '完整响应速率',
};
const _formulas = {
  'ttftMs': '首段内容时间 − 请求开始',
  'ttfoMs': '首段可见文本时间 − 请求开始',
  'streamTokensPerSecond': '(输出 token − 首块 token) / (末段内容 − 首段内容)',
  'e2eTokensPerSecond': '最终输出 token / (HTTP EOF − 请求开始)',
  'fullResponseTokensPerSecond': '(输出 token − 首块 token) / (HTTP EOF − 首段内容)',
};
String _quality(String quality) => switch (quality) {
  'measured' => '实测延迟',
  'reported' => '报告计数',
  'estimated' => '估计',
  _ => '不可用',
};
String _state(String state) => switch (state) {
  'starting' => '正在保存开始意图',
  'queued' => '排队',
  'connecting' => '连接中',
  'streaming' => '回放中',
  'completed' => '已完成',
  'cancelled' => '已取消',
  'interrupted' => '已中断',
  'failed' => '失败',
  _ => '等待开始',
};

class IndependentBenchmarkPanel extends StatelessWidget {
  const IndependentBenchmarkPanel({super.key, required this.controller});
  final BenchmarkController controller;
  void _inspect(BuildContext context, String key, BenchmarkMetric? metric) {
    unawaited(
      showMonitorInformation(
        context,
        title: _labels[key]!,
        builder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_formulas[key]!),
            const SizedBox(height: 12),
            Text(
              metric == null
                  ? '尚无观测事实'
                  : key.endsWith('Ms')
                  ? '${metric.denominatorNs ?? '—'} / 10^6 ms'
                  : '${metric.numeratorTokens ?? '—'} × 10^9 / ${metric.denominatorNs ?? '—'} tokens/s',
            ),
            const SizedBox(height: 8),
            Text('计数来源：${metric?.countSource ?? '—'}'),
            Text('质量：${_quality(metric?.quality ?? 'unavailable')}'),
            Text(
              '原因：${metric == null || metric.reasons.isEmpty ? '无' : metric.reasons.join(' · ')}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Rust 计算；延迟使用客户端单调时钟。推理计入 output 的子集；协议终态与 HTTP EOF 分开。',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      final scenarios =
          controller.catalog?.scenarios
              .where((s) => s.protocol == controller.protocol)
              .toList() ??
          <BenchmarkScenario>[];
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
            if (controller.canStart) unawaited(controller.start());
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (controller.canCancel) unawaited(controller.cancel());
          },
        },
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
            key: const PageStorageKey('independent-api-scroll'),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: FCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '独立 API 测速',
                          style: context.theme.typography.display.lg,
                        ),
                        const SizedBox(height: 6),
                        const Text('离线回放 · 合成数据 · 客户端观测'),
                        const SizedBox(height: 12),
                        FSelect<String>(
                          key: const ValueKey('benchmark-protocol'),
                          label: const Text('协议'),
                          items: const {
                            'Chat Completions': 'chat_completions',
                            'Responses': 'responses',
                          },
                          enabled:
                              !controller.busy && controller.catalog != null,
                          control: FSelectControl.lifted(
                            value: controller.protocol,
                            onChange: (v) {
                              if (v != null) {
                                unawaited(controller.selectProtocol(v));
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        FSelect<String>(
                          key: const ValueKey('benchmark-scenario'),
                          label: const Text('合成场景'),
                          items: {for (final s in scenarios) s.label: s.id},
                          enabled: !controller.busy && scenarios.isNotEmpty,
                          control: FSelectControl.lifted(
                            value:
                                scenarios.any(
                                  (s) => s.id == controller.scenarioId,
                                )
                                ? controller.scenarioId
                                : null,
                            onChange: (v) {
                              if (v != null) {
                                unawaited(controller.selectScenario(v));
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FButton(
                              key: const ValueKey('benchmark-start'),
                              mainAxisSize: MainAxisSize.min,
                              onPress: controller.canStart
                                  ? () => unawaited(controller.start())
                                  : null,
                              prefix: const Icon(FLucideIcons.play, size: 16),
                              child: const Text('开始回放'),
                            ),
                            FButton(
                              key: const ValueKey('benchmark-cancel'),
                              variant: FButtonVariant.outline,
                              mainAxisSize: MainAxisSize.min,
                              onPress: controller.canCancel
                                  ? () => unawaited(controller.cancel())
                                  : null,
                              child: const Text('取消'),
                            ),
                            FButton(
                              key: const ValueKey('benchmark-clear'),
                              variant: FButtonVariant.ghost,
                              mainAxisSize: MainAxisSize.min,
                              onPress: controller.canClear && snapshot != null
                                  ? () => unawaited(controller.clear())
                                  : null,
                              child: const Text('清除结果'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${controller.starting ? _state('starting') : _state(snapshot?.state ?? '')}${snapshot?.restored == true ? ' · 已恢复的最后观察' : ''}',
                        ),
                        Text(
                          '耗时：${snapshot?.elapsedNs == null ? '—' : '${(snapshot!.elapsedNs! / 1e9).toStringAsFixed(3)} s'}${snapshot != null && !snapshot.restored && snapshot.cleanupPending ? ' · 自有任务清理中' : ''}',
                        ),
                        Text(
                          '样本质量：${snapshot == null
                              ? '尚无测试结果'
                              : snapshot.successfulSample
                              ? '样本有效'
                              : '不可作为成功测速样本'}',
                        ),
                        if (snapshot != null) ...[
                          Text(
                            '结果来源：${snapshot.protocol} · ${snapshot.scenarioId}',
                          ),
                          if (snapshot.reasons.isNotEmpty)
                            Text('原因：${snapshot.reasons.join(' · ')}'),
                        ],
                        if (controller.lastError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              controller.lastError!,
                              style: TextStyle(
                                color: context.theme.colors.destructive,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = constraints.maxWidth >= 850
                                ? 3
                                : constraints.maxWidth >= 480
                                ? 2
                                : 1;
                            final width = math.max(
                              0.0,
                              (constraints.maxWidth - (columns - 1) * 10) /
                                  columns,
                            );
                            return Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final key in benchmarkMetricKeys)
                                  SizedBox(
                                    width: width,
                                    child: Container(
                                      key: ValueKey('benchmark-metric-$key'),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: context.theme.colors.border,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Wrap(
                                            spacing: 4,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              Text(_labels[key]!),
                                              MonitorIconAction(
                                                key: ValueKey(
                                                  'benchmark-inspect-$key',
                                                ),
                                                label: '查看${_labels[key]}公式与原因',
                                                icon: FLucideIcons.info,
                                                onPress: () => _inspect(
                                                  context,
                                                  key,
                                                  snapshot?.metrics[key],
                                                ),
                                              ),
                                            ],
                                          ),
                                          Text(
                                            snapshot?.metrics[key]?.value
                                                    ?.toStringAsFixed(2) ??
                                                '—',
                                            style: context
                                                .theme
                                                .typography
                                                .display
                                                .lg,
                                          ),
                                          Text(
                                            '${key.endsWith('Ms') ? 'ms' : 'tokens/s'} · ${_quality(snapshot?.metrics[key]?.quality ?? 'unavailable')}',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        _TimingMarkers(snapshot: snapshot),
                        const SizedBox(height: 12),
                        const Text('真实 API 测试尚未启用。Ctrl+Enter 开始 · Esc 取消。'),
                        const Text(
                          '记录是最后保存的观察，恢复后不会自动补发请求。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

const _timingLabels = {
  'start': '请求开始',
  'firstContent': '首段内容',
  'lastContent': '末段内容',
  'firstVisible': '首段可见文本',
  'lastVisible': '末段可见文本',
  'usage': 'usage',
  'done': '协议终态',
  'httpEnd': 'HTTP EOF',
};

class _TimingMarkers extends StatelessWidget {
  const _TimingMarkers({this.snapshot});
  final BenchmarkSnapshot? snapshot;
  @override
  Widget build(BuildContext context) {
    final times = snapshot?.timingsNs ?? const <String, int?>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('请求事件时间点 · 沿客户端实测耗时定位'),
        SizedBox(
          height: 32,
          child: CustomPaint(
            painter: _MarkerPainter(
              times,
              snapshot?.elapsedNs ?? 0,
              context.theme.colors.primary,
              context.theme.colors.border,
            ),
          ),
        ),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final entry in _timingLabels.entries)
              Text(
                '${entry.value} ${times[entry.key] == null ? '—' : '${(times[entry.key]! / 1e6).toStringAsFixed(1)} ms'}',
              ),
          ],
        ),
      ],
    );
  }
}

class _MarkerPainter extends CustomPainter {
  _MarkerPainter(this.times, this.elapsed, this.color, this.border);
  final Map<String, int?> times;
  final int elapsed;
  final Color color, border;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(3, size.height / 2),
      Offset(math.max(3, size.width - 3), size.height / 2),
      paint,
    );
    if (elapsed <= 0) return;
    paint.color = color;
    for (final time in times.values.whereType<int>()) {
      if (time < 0 || time > elapsed) continue;
      final x = 3 + (size.width - 6) * time / elapsed;
      canvas.drawCircle(Offset(x, size.height / 2), 3, paint);
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter oldDelegate) =>
      oldDelegate.times != times ||
      oldDelegate.elapsed != elapsed ||
      oldDelegate.color != color ||
      oldDelegate.border != border;
}
