import 'dart:convert';

import 'backend.dart';
import 'network_transport.dart';

const benchmarkMetricKeys = [
  'ttftMs',
  'ttfoMs',
  'streamTokensPerSecond',
  'e2eTokensPerSecond',
  'fullResponseTokensPerSecond',
];
const benchmarkTimingKeys = [
  'start',
  'firstContent',
  'lastContent',
  'firstVisible',
  'lastVisible',
  'usage',
  'done',
  'httpEnd',
];
const benchmarkProtocols = ['chat_completions', 'responses'];
const benchmarkStates = [
  'starting',
  'queued',
  'connecting',
  'streaming',
  'completed',
  'failed',
  'cancelled',
  'interrupted',
];
const benchmarkScenarios = [
  'chat_text_complete',
  'chat_reasoning_complete',
  'chat_missing_usage',
  'chat_truncated',
  'chat_slow',
  'responses_text_complete',
  'responses_reasoning_complete',
  'responses_missing_usage',
  'responses_truncated',
  'responses_slow',
  'responses_failed',
  'responses_incomplete',
];
const _reasonCodes = {
  'missing_content',
  'missing_visible_text',
  'missing_finish',
  'non_stop_finish',
  'missing_done',
  'missing_http_eof',
  'missing_usage',
  'nonpositive_http_duration',
  'invalid_reasoning_count',
  'first_chunk_count_not_usable',
  'nonpositive_content_duration',
  'insufficient_output_tokens',
  'reasoning_generation_boundary_unknown',
  'text_generation_boundary_unknown',
  'tool_token_scope_unknown',
  'first_chunk_assumed_one',
  'reasoning_scope_unknown',
  'cancelled',
  'interrupted',
  'shutdown',
  'previous_process_ended',
  'worker_panic',
  'worker_exit',
  'collector_failed',
  'conflicting_finish',
  'conflicting_usage',
  'content_after_finish',
  'duplicate_http_eof',
  'event_after_done',
  'event_after_http_eof',
  'reversed_time',
  'chat_after_done',
  'chat_message_too_large',
  'inconsistent_token_usage',
  'invalid_chat_json',
  'invalid_token_count',
  'response_identity_changed',
  'unsupported_chat_schema',
  'unsupported_choices',
  'unsupported_finish_reason',
  'unsupported_sse_event',
  'invalid_responses_item',
  'invalid_responses_json',
  'invalid_responses_sequence',
  'missing_response_identity',
  'missing_responses_output_item',
  'response_error',
  'response_failed',
  'response_incomplete',
  'responses_after_terminal',
  'responses_content_after_done',
  'responses_event_type_mismatch',
  'responses_item_after_done',
  'responses_item_identity_changed',
  'responses_message_too_large',
  'unsupported_responses_event',
  'unsupported_responses_schema',
  'incomplete_sse',
  'sse_after_eof',
  'sse_event_too_large',
  'sse_input_too_large',
  'body_idle_timeout',
  'body_too_large',
  'header_timeout',
  'http_status',
  'invalid_content_type',
  'request_timeout',
  'transport_error',
  'transport_setup',
  'unknown_reason',
};

Map<String, dynamic> benchmarkMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_benchmark_data');
  }
  return value;
}

String benchmarkChoice(Object? value, Iterable<String> allowed) {
  if (value is! String || !allowed.contains(value)) {
    throw const FormatException('invalid_benchmark_data');
  }
  return value;
}

int? benchmarkInteger(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0 || value > 0x7fffffffffffffff) {
    throw const FormatException('invalid_benchmark_number');
  }
  return value;
}

int _requiredInteger(Object? value) =>
    benchmarkInteger(value) ??
    (throw const FormatException('missing_benchmark_number'));

String? _identifier(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      !RegExp(r'^[a-zA-Z0-9_.+\-]{1,160}$').hasMatch(value)) {
    throw const FormatException('invalid_benchmark_identifier');
  }
  return value;
}

List<String> _reasons(Object? value) {
  if (value is! List || value.length > 64 || value.any((e) => e is! String)) {
    throw const FormatException('invalid_benchmark_reasons');
  }
  return List.unmodifiable(
    value
        .map((e) => _reasonCodes.contains(e) ? e as String : 'unknown_reason')
        .toSet(),
  );
}

bool _flag(Object? value) {
  if (value is! bool) throw const FormatException('invalid_benchmark_flag');
  return value;
}

String _modelName(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      utf8.encode(value).length > 256 ||
      value.runes.any((c) => c < 32 || c == 127)) {
    throw const FormatException('invalid_benchmark_model');
  }
  return value;
}

/// Request fields remain in memory. Credentials are supplied separately.
class BenchmarkLiveConfig {
  const BenchmarkLiveConfig({
    this.baseUrl = '',
    this.model = '',
    this.prompt = '',
    this.maxOutputTokens = 256,
    this.route = 'system',
  });
  final String baseUrl, model, prompt, route;
  final int maxOutputTokens;
  bool get valid {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['https', 'http'].contains(uri.scheme) ||
        (uri.scheme == 'http' &&
            !(uri.host == '::1' ||
                RegExp(r'^127\.(\d{1,3}\.){2}\d{1,3}$').hasMatch(uri.host))) ||
        uri.path.endsWith('/chat/completions') ||
        uri.path.endsWith('/responses') ||
        !['system', 'direct'].contains(route) ||
        maxOutputTokens < 1 ||
        maxOutputTokens > 8192 ||
        prompt.isEmpty ||
        utf8.encode(prompt).length > 65536) {
      return false;
    }
    try {
      _modelName(model);
      return true;
    } catch (_) {
      return false;
    }
  }

  Uri endpointFor(String protocol) => Uri.parse(
    '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/${protocol == 'responses' ? 'responses' : 'chat/completions'}',
  );
  BenchmarkLiveConfig copy({
    String? baseUrl,
    String? model,
    String? prompt,
    int? maxOutputTokens,
    String? route,
  }) => BenchmarkLiveConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    prompt: prompt ?? this.prompt,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    route: route ?? this.route,
  );
}

class BenchmarkMetric {
  const BenchmarkMetric({
    required this.value,
    required this.unit,
    required this.quality,
    required this.reasons,
    required this.numeratorTokens,
    required this.denominatorNs,
    required this.countSource,
  });
  final double? value;
  final String unit, quality, countSource;
  final List<String> reasons;
  final int? numeratorTokens, denominatorNs;
  factory BenchmarkMetric.fromJson(Map<String, dynamic> json, String key) {
    final v = json['value'];
    if (v != null && (v is! num || !v.isFinite || v < 0)) {
      throw const FormatException('invalid_benchmark_number');
    }
    final unit = benchmarkChoice(json['unit'], [
      key.endsWith('Ms') ? 'ms' : 'tokens/s',
    ]);
    final quality = benchmarkChoice(json['quality'], [
      'unavailable',
      'measured',
      'reported',
      'estimated',
    ]);
    if ((quality == 'unavailable') != (v == null)) {
      throw const FormatException('invalid_benchmark_quality');
    }
    final numerator = benchmarkInteger(json['numeratorTokens']);
    final denominator = benchmarkInteger(json['denominatorNs']);
    if (v != null &&
        (denominator == null ||
            (!key.endsWith('Ms') && (numerator == null || denominator == 0)))) {
      throw const FormatException('missing_benchmark_formula');
    }
    return BenchmarkMetric(
      value: (v as num?)?.toDouble(),
      unit: unit,
      quality: quality,
      reasons: _reasons(json['reasons']),
      numeratorTokens: numerator,
      denominatorNs: denominator,
      countSource: benchmarkChoice(json['countSource'], [
        'monotonic_clock',
        for (final prefix in ['completion', 'output']) ...[
          'reported_${prefix}_tokens',
          'reported_${prefix}_tokens_including_reasoning',
          'reported_${prefix}_tokens_minus_first_text_logprobs',
          'reported_${prefix}_tokens_minus_assumed_one',
        ],
      ]),
    );
  }
  BenchmarkMetric unavailable(String reason) => BenchmarkMetric(
    value: null,
    unit: unit,
    quality: 'unavailable',
    reasons: List.unmodifiable({...reasons, reason}),
    numeratorTokens: numeratorTokens,
    denominatorNs: denominatorNs,
    countSource: countSource,
  );
  Map<String, Object?> toJson() => {
    'value': value,
    'unit': unit,
    'quality': quality,
    'reasons': reasons,
    'numeratorTokens': numeratorTokens,
    'denominatorNs': denominatorNs,
    'countSource': countSource,
  };
}

class BenchmarkScenario {
  const BenchmarkScenario(this.id, this.protocol, this.label, this.description);
  final String id, protocol, label, description;
}

class BenchmarkCatalog {
  const BenchmarkCatalog(this.scenarios, {this.liveExecutionEnabled = false});
  final List<BenchmarkScenario> scenarios;
  final bool liveExecutionEnabled;
  factory BenchmarkCatalog.fromJson(Map<String, dynamic> json) {
    if (json['offlineOnly'] is! bool ||
        json['liveExecutionEnabled'] is! bool ||
        json['offlineOnly'] == json['liveExecutionEnabled'] ||
        json['scenarios'] is! List) {
      throw const FormatException('invalid_benchmark_catalog');
    }
    return BenchmarkCatalog(
      List.unmodifiable(
        (json['scenarios'] as List).map((v) {
          final j = benchmarkMap(v);
          final id = benchmarkChoice(j['scenarioId'], benchmarkScenarios);
          final protocol = benchmarkChoice(j['protocol'], benchmarkProtocols);
          if (!id.startsWith(
            protocol == 'responses' ? 'responses_' : 'chat_',
          )) {
            throw const FormatException('invalid_benchmark_scenario');
          }
          String label(String key) {
            final value = j[key];
            if (value is! String || value.length > 200) {
              throw const FormatException('invalid_benchmark_catalog');
            }
            return value;
          }

          return BenchmarkScenario(
            id,
            protocol,
            label('label'),
            label('description'),
          );
        }),
      ),
      liveExecutionEnabled: json['liveExecutionEnabled'] as bool,
    );
  }
}

/// Immutable observation. Only these fields can cross the journal boundary.
class BenchmarkSnapshot {
  const BenchmarkSnapshot({
    required this.runId,
    required this.state,
    required this.protocol,
    required this.scenarioId,
    required this.engineVersion,
    required this.requestedModel,
    required this.responseModel,
    required this.cleanupPending,
    required this.elapsedNs,
    required this.successfulSample,
    required this.protocolTerminal,
    required this.reasons,
    required this.timingsNs,
    required this.usage,
    required this.metrics,
    this.restored = false,
    this.executionMode = 'offline_replay',
  });
  final String? runId, responseModel, protocolTerminal;
  final String state, protocol, scenarioId, engineVersion, requestedModel;
  final String executionMode;
  final bool cleanupPending, successfulSample, restored;
  final int? elapsedNs;
  final List<String> reasons;
  final Map<String, int?> timingsNs;
  final Map<String, int?>? usage;
  final Map<String, BenchmarkMetric> metrics;
  bool get terminal =>
      ['completed', 'failed', 'cancelled', 'interrupted'].contains(state);
  factory BenchmarkSnapshot.fromJson(Map<String, dynamic> json) {
    final runId = _identifier(json['runId']);
    final state = benchmarkChoice(json['state'], benchmarkStates);
    final reasons = _reasons(json['reasons']);
    final unobservedIntent =
        runId == null &&
        state == 'interrupted' &&
        reasons.contains('previous_process_ended');
    benchmarkChoice(json['measurementKind'], ['independent_api']);
    final mode = benchmarkChoice(json['executionMode'], [
      'offline_replay',
      'live',
    ]);
    final live = mode == 'live';
    final source = benchmarkMap(json['source']);
    benchmarkChoice(source['kind'], [
      live ? 'user_endpoint' : 'offline_fixture',
    ]);
    benchmarkChoice(source['networkScope'], [
      live ? 'user_configured_endpoint' : 'literal_loopback_only',
    ]);
    if (live && source['scenarioId'] != null) {
      throw const FormatException('invalid_benchmark_scenario');
    }
    final scenario = live
        ? ''
        : benchmarkChoice(source['scenarioId'], benchmarkScenarios);
    final protocol = benchmarkChoice(json['protocol'], benchmarkProtocols);
    if (!live &&
        !scenario.startsWith(
          protocol == 'responses' ? 'responses_' : 'chat_',
        )) {
      throw const FormatException('invalid_benchmark_scenario');
    }
    final time = benchmarkMap(json['timingsNs']);
    final values = benchmarkMap(json['metrics']);
    final tokenUsage = json['usage'] == null
        ? null
        : benchmarkMap(json['usage']);
    final usage = tokenUsage == null
        ? null
        : Map<String, int?>.unmodifiable({
            for (final k in ['inputTokens', 'outputTokens', 'reasoningTokens'])
              k: benchmarkInteger(tokenUsage[k]),
          });
    if (usage != null && usage['outputTokens'] == null) {
      throw const FormatException('invalid_benchmark_usage');
    }
    if (usage?['reasoningTokens'] != null &&
        (usage!['outputTokens'] == null ||
            usage['reasoningTokens']! > usage['outputTokens']!)) {
      throw const FormatException('invalid_benchmark_usage');
    }
    return BenchmarkSnapshot(
      runId: runId,
      state: state,
      executionMode: mode,
      protocol: protocol,
      scenarioId: scenario,
      engineVersion: benchmarkChoice(json['engineVersion'], [
        live ? 'm4-rust-v1+aiperf-b1746a84' : 'm3-rust-v1+aiperf-b1746a84',
      ]),
      requestedModel: live
          ? _modelName(json['requestedModel'])
          : benchmarkChoice(json['requestedModel'], ['fixture-model']),
      responseModel: json['responseModel'] == null
          ? null
          : live
          ? _modelName(json['responseModel'])
          : benchmarkChoice(json['responseModel'], ['fixture-response-model']),
      cleanupPending: _flag(json['cleanupPending']),
      elapsedNs: unobservedIntent
          ? benchmarkInteger(json['elapsedNs'])
          : _requiredInteger(json['elapsedNs']),
      successfulSample: _flag(json['successfulSample']),
      protocolTerminal: json['protocolTerminal'] == null
          ? null
          : benchmarkChoice(json['protocolTerminal'], [
              'chat_done',
              'response.completed',
              'response.failed',
              'response.incomplete',
            ]),
      reasons: reasons,
      timingsNs: Map.unmodifiable({
        for (final k in benchmarkTimingKeys) k: benchmarkInteger(time[k]),
      }),
      usage: usage,
      metrics: Map.unmodifiable({
        for (final k in benchmarkMetricKeys)
          k: BenchmarkMetric.fromJson(benchmarkMap(values[k]), k),
      }),
    );
  }
  BenchmarkSnapshot copy({
    String? state,
    bool? cleanupPending,
    bool? successfulSample,
    bool? restored,
    String? reason,
    bool clearRates = false,
  }) => BenchmarkSnapshot(
    runId: runId,
    state: state ?? this.state,
    executionMode: executionMode,
    protocol: protocol,
    scenarioId: scenarioId,
    engineVersion: engineVersion,
    requestedModel: requestedModel,
    responseModel: responseModel,
    cleanupPending: cleanupPending ?? this.cleanupPending,
    elapsedNs: elapsedNs,
    successfulSample: successfulSample ?? this.successfulSample,
    protocolTerminal: protocolTerminal,
    reasons: List.unmodifiable({...reasons, ?reason}),
    timingsNs: timingsNs,
    usage: usage,
    metrics: Map.unmodifiable({
      for (final e in metrics.entries)
        e.key: clearRates && !e.key.endsWith('Ms')
            ? e.value.unavailable(reason ?? 'interrupted')
            : e.value,
    }),
    restored: restored ?? this.restored,
  );
  BenchmarkSnapshot recover() => terminal
      ? copy(restored: true)
      : copy(
          state: 'interrupted',
          successfulSample: false,
          restored: true,
          reason: 'previous_process_ended',
          clearRates: true,
        );
  static BenchmarkSnapshot interruptedIntent(
    String protocol,
    String scenario, {
    String executionMode = 'offline_replay',
  }) => BenchmarkSnapshot(
    runId: null,
    state: 'interrupted',
    executionMode: executionMode,
    protocol: protocol,
    scenarioId: scenario,
    engineVersion: executionMode == 'live'
        ? 'm4-rust-v1+aiperf-b1746a84'
        : 'm3-rust-v1+aiperf-b1746a84',
    requestedModel: executionMode == 'live' ? 'unknown' : 'fixture-model',
    responseModel: null,
    cleanupPending: false,
    elapsedNs: null,
    successfulSample: false,
    protocolTerminal: null,
    reasons: const ['previous_process_ended'],
    timingsNs: const {},
    usage: null,
    metrics: {
      for (final key in benchmarkMetricKeys)
        key: BenchmarkMetric(
          value: null,
          unit: key.endsWith('Ms') ? 'ms' : 'tokens/s',
          quality: 'unavailable',
          reasons: const ['previous_process_ended'],
          numeratorTokens: null,
          denominatorNs: null,
          countSource: key.endsWith('Ms')
              ? 'monotonic_clock'
              : 'reported_completion_tokens',
        ),
    },
    restored: true,
  );
  Map<String, Object?> toJson() => {
    'runId': runId,
    'state': state,
    'measurementKind': 'independent_api',
    'protocol': protocol,
    'executionMode': executionMode,
    'source': {
      'kind': executionMode == 'live' ? 'user_endpoint' : 'offline_fixture',
      'scenarioId': executionMode == 'live' ? null : scenarioId,
      'networkScope': executionMode == 'live'
          ? 'user_configured_endpoint'
          : 'literal_loopback_only',
    },
    'engineVersion': engineVersion,
    'requestedModel': requestedModel,
    'responseModel': responseModel,
    'cleanupPending': cleanupPending,
    'elapsedNs': elapsedNs,
    'successfulSample': successfulSample,
    'protocolTerminal': protocolTerminal,
    'reasons': reasons,
    'timingsNs': {for (final k in benchmarkTimingKeys) k: timingsNs[k]},
    'usage': usage == null
        ? null
        : {
            for (final k in ['inputTokens', 'outputTokens', 'reasoningTokens'])
              k: usage![k],
          },
    'metrics': {for (final k in benchmarkMetricKeys) k: metrics[k]!.toJson()},
  };
}

class BenchmarkService {
  const BenchmarkService(this.backend);
  final LauncherBackend backend;
  Future<BenchmarkCatalog> catalog() async =>
      BenchmarkCatalog.fromJson(await backend.call('benchmark_catalog'));
  Future<String> resolveLiveProxy(Uri endpoint) async {
    final resolved = await SystemProxyResolver.forBackend(backend)
        .resolve(endpoint);
    final first = resolved.split(';').first.trim();
    if (first != 'DIRECT' &&
        !RegExp(r'^PROXY [^\s;]+:[0-9]{1,5}$').hasMatch(first)) {
      throw const FormatException('unsupported_proxy');
    }
    return first;
  }

  Future<BenchmarkSnapshot> startLive(
    String protocol,
    BenchmarkLiveConfig config, {
    required String apiKey,
    required String resolvedProxy,
    void Function(String)? onOwned,
  }) async {
    if (!config.valid || apiKey.isEmpty || apiKey.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('invalid_live_config');
    }
    final raw = await backend.call('benchmark_start', {
      'mode': 'live',
      'protocol': protocol,
      'baseUrl': config.baseUrl,
      'model': config.model,
      'prompt': config.prompt,
      'apiKey': apiKey,
      'resolvedProxy': resolvedProxy,
      'maxOutputTokens': config.maxOutputTokens,
      'timeoutMs': 30000,
      'idleTimeoutMs': 5000,
    });
    final id = _identifier(raw['runId']);
    if (id == null) throw const FormatException('missing_run_id');
    onOwned?.call(id);
    return BenchmarkSnapshot.fromJson(raw);
  }

  Future<BenchmarkSnapshot> start(
    String protocol,
    String scenario, {
    void Function(String)? onOwned,
  }) async {
    final raw = await backend.call('benchmark_start', {
      'mode': 'offline_replay',
      'protocol': protocol,
      'scenarioId': scenario,
    });
    final id = _identifier(raw['runId']);
    if (id == null) throw const FormatException('missing_run_id');
    // Remember allocation identity even when another returned field is invalid.
    onOwned?.call(id);
    return BenchmarkSnapshot.fromJson(raw);
  }

  Future<BenchmarkSnapshot> observe(String command, String id) async =>
      BenchmarkSnapshot.fromJson(await backend.call(command, {'runId': id}));
  Future<void> clear(String id) async {
    final result = await backend.call('benchmark_clear', {'runId': id});
    if (result['cleared'] != true || result['runId'] != id) {
      throw const FormatException('invalid_benchmark_clear');
    }
  }

  Future<bool> shutdown(String? id) async {
    final result = await backend.call('benchmark_shutdown', {'runId': id});
    if (result['accepting'] != false ||
        result['runId'] != id ||
        result['cleanupComplete'] is! bool) {
      throw const FormatException('invalid_benchmark_shutdown');
    }
    return result['cleanupComplete'] as bool;
  }
}
