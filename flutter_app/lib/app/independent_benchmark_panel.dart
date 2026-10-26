import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/benchmark.dart';
import '../state/benchmark_controller.dart';
import '../l10n/app_copy.dart';
import '../l10n/copy_benchmark.dart';
import 'dashboard_style.dart';
import 'monitor_information.dart';
import 'monitor_presentation.dart';

String _label(BuildContext context, String key) =>
    AppCopy.of(context).text('benchmark.metric.$key');
String _quality(
  BuildContext context,
  String quality,
) => AppCopy.of(context).text(
  'benchmark.quality.${const {'measured', 'reported', 'estimated'}.contains(quality) ? quality : 'unavailable'}',
);
String _state(BuildContext context, String state) => AppCopy.of(
  context,
).text('benchmark.state.${benchmarkStates.contains(state) ? state : 'idle'}');
String _scenario(BuildContext context, BenchmarkScenario scenario) {
  final copy = AppCopy.of(context);
  if (!copy.isEnglish) return scenario.label;
  final name = scenario.id.replaceFirst(RegExp(r'^(chat|responses)_'), '');
  final key = 'benchmark.scenario.$name';
  return benchmarkMessages.containsKey(key) ? copy.text(key) : scenario.label;
}

String _error(BuildContext context, String raw) {
  final copy = AppCopy.of(context);
  for (final entry in benchmarkMessages.entries) {
    if (entry.key.startsWith('benchmark.error.') && entry.value.zh == raw) {
      return copy.text(entry.key);
    }
  }
  return raw;
}

class IndependentBenchmarkPanel extends StatelessWidget {
  const IndependentBenchmarkPanel({super.key, required this.controller});
  final BenchmarkController controller;
  void _inspect(BuildContext context, String key, BenchmarkMetric? metric) {
    unawaited(
      showMonitorInformation(
        context,
        title: _label(context, key),
        titleKey: 'benchmark.metric.$key',
        builder: (context) {
          final copy = AppCopy.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(copy.text('benchmark.formula.$key')),
              const SizedBox(height: 12),
              Text(
                metric == null
                    ? copy.text('benchmark.noFacts')
                    : key.endsWith('Ms')
                    ? '${metric.denominatorNs ?? '—'} / 10^6 ms'
                    : '${metric.numeratorTokens ?? '—'} × 10^9 / ${metric.denominatorNs ?? '—'} tokens/s',
              ),
              const SizedBox(height: 8),
              Text(
                copy.text(
                  'benchmark.countSource',
                  args: {'value': metric?.countSource ?? '—'},
                ),
              ),
              Text(
                copy.text(
                  'benchmark.quality',
                  args: {
                    'value': _quality(
                      context,
                      metric?.quality ?? 'unavailable',
                    ),
                  },
                ),
              ),
              Text(
                copy.text(
                  'benchmark.reasons',
                  args: {
                    'value': metric == null || metric.reasons.isEmpty
                        ? copy.text('common.none')
                        : metric.reasons.join(' · '),
                  },
                ),
              ),
              const SizedBox(height: 12),
              Text(copy.text('benchmark.method')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final copy = AppCopy.of(context);
      final snapshot = controller.snapshot;
      final palette = DashboardPalette.of(context);
      final muted = context.theme.typography.body.sm.copyWith(
        color: palette.muted,
      );
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              copy.text('benchmark.title'),
                              style: context.theme.typography.body.lg,
                            ),
                            Text(copy.text('benchmark.subtitle'), style: muted),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _controls(context, scenarios),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${controller.starting ? _state(context, 'starting') : _state(context, snapshot?.state ?? '')}${snapshot?.restored == true ? copy.text('benchmark.restoredSuffix') : ''}',
                              style: context.theme.typography.body.md.copyWith(
                                fontWeight: FontWeight.w600,
                                color: snapshot?.state == 'failed'
                                    ? palette.danger
                                    : palette.foreground,
                              ),
                            ),
                            Text(
                              '${copy.text('benchmark.elapsed', args: {'value': snapshot?.elapsedNs == null ? '—' : '${(snapshot!.elapsedNs! / 1e9).toStringAsFixed(2)} s'})}${snapshot != null && !snapshot.restored && snapshot.cleanupPending ? copy.text('benchmark.cleanupSuffix') : ''}',
                              style: muted,
                            ),
                            Text(
                              copy.text(
                                'benchmark.sampleQuality',
                                args: {
                                  'value': copy.text(
                                    snapshot == null
                                        ? 'benchmark.noResult'
                                        : snapshot.successfulSample
                                        ? 'benchmark.valid'
                                        : 'benchmark.invalid',
                                  ),
                                },
                              ),
                              style: muted,
                            ),
                          ],
                        ),
                        if (snapshot != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            copy.text(
                              'benchmark.resultSource',
                              args: {
                                'value':
                                    '${snapshot.protocol} · ${snapshot.scenarioId}',
                              },
                            ),
                            style: muted,
                          ),
                          if (snapshot.reasons.isNotEmpty)
                            Text(
                              copy.text(
                                'benchmark.reasons',
                                args: {'value': snapshot.reasons.join(' · ')},
                              ),
                              style: muted,
                            ),
                        ],
                        if (controller.lastError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _error(context, controller.lastError!),
                              style: TextStyle(color: palette.danger),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 1400
                        ? 5
                        : constraints.maxWidth >= 640
                        ? 3
                        : constraints.maxWidth >= 390
                        ? 2
                        : 1;
                    final width = math.max(
                      0.0,
                      (constraints.maxWidth - (columns - 1) * 12) / columns,
                    );
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final key in benchmarkMetricKeys)
                          SizedBox(
                            width: width,
                            child: FCard(
                              key: ValueKey('benchmark-metric-$key'),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  6,
                                  10,
                                  10,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _label(context, key),
                                            style: context
                                                .theme
                                                .typography
                                                .body
                                                .lg,
                                          ),
                                        ),
                                        MonitorIconAction(
                                          key: ValueKey(
                                            'benchmark-inspect-$key',
                                          ),
                                          label: copy.text(
                                            'benchmark.inspect',
                                            args: {
                                              'name': _label(context, key),
                                            },
                                          ),
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
                                      style:
                                          context.theme.typography.display.xl2,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${key.endsWith('Ms') ? 'ms' : 'tokens/s'} · ${_quality(context, snapshot?.metrics[key]?.quality ?? 'unavailable')}',
                                      style: muted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                FCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
                    child: _TimingMarkers(snapshot: snapshot),
                  ),
                ),
                const SizedBox(height: 10),
                Text(copy.text('benchmark.offlineOnly'), style: muted),
                Text(copy.text('benchmark.restorePolicy'), style: muted),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _controls(BuildContext context, List<BenchmarkScenario> scenarios) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final selectWidth = width >= 750
              ? 220.0
              : width >= 460
              ? (width - 12) / 2
              : width;
          return Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: selectWidth,
                child: FSelect<String>(
                  key: const ValueKey('benchmark-protocol'),
                  label: Text(AppCopy.of(context).text('benchmark.protocol')),
                  items: const {
                    'Chat Completions': 'chat_completions',
                    'Responses': 'responses',
                  },
                  enabled: !controller.busy && controller.catalog != null,
                  control: FSelectControl.lifted(
                    value: controller.protocol,
                    onChange: (v) {
                      if (v != null) unawaited(controller.selectProtocol(v));
                    },
                  ),
                ),
              ),
              SizedBox(
                width: selectWidth,
                child: FSelect<String>(
                  key: const ValueKey('benchmark-scenario'),
                  label: Text(AppCopy.of(context).text('benchmark.scenario')),
                  items: {
                    for (final s in scenarios) _scenario(context, s): s.id,
                  },
                  enabled: !controller.busy && scenarios.isNotEmpty,
                  control: FSelectControl.lifted(
                    value: scenarios.any((s) => s.id == controller.scenarioId)
                        ? controller.scenarioId
                        : null,
                    onChange: (v) {
                      if (v != null) unawaited(controller.selectScenario(v));
                    },
                  ),
                ),
              ),
              FButton(
                key: const ValueKey('benchmark-start'),
                mainAxisSize: MainAxisSize.min,
                onPress: controller.canStart
                    ? () => unawaited(controller.start())
                    : null,
                prefix: const Icon(FLucideIcons.play, size: 16),
                child: Text(AppCopy.of(context).text('benchmark.start')),
              ),
              FButton(
                key: const ValueKey('benchmark-cancel'),
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: controller.canCancel
                    ? () => unawaited(controller.cancel())
                    : null,
                child: Text(AppCopy.of(context).text('common.cancel')),
              ),
              FButton(
                key: const ValueKey('benchmark-clear'),
                variant: FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: controller.canClear && controller.snapshot != null
                    ? () => unawaited(controller.clear())
                    : null,
                child: Text(AppCopy.of(context).text('benchmark.clear')),
              ),
            ],
          );
        },
      );
}

class _TimingMarkers extends StatelessWidget {
  const _TimingMarkers({this.snapshot});
  final BenchmarkSnapshot? snapshot;
  @override
  Widget build(BuildContext context) {
    final times = snapshot?.timingsNs ?? const <String, int?>{};
    final palette = DashboardPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppCopy.of(context).text('benchmark.timeline'),
          style: context.theme.typography.body.lg,
        ),
        SizedBox(
          height: 32,
          child: CustomPaint(
            painter: _MarkerPainter(
              times,
              snapshot?.elapsedNs ?? 0,
              palette.dataBlue,
              palette.grid,
            ),
          ),
        ),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final key in benchmarkTimingKeys)
              Text(
                '${AppCopy.of(context).text('benchmark.timing.$key')} ${times[key] == null ? '—' : '${(times[key]! / 1e6).toStringAsFixed(2)} ms'}',
                style: context.theme.typography.body.sm.copyWith(
                  color: palette.muted,
                ),
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
