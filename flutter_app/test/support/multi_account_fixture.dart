// Unshipped pure-memory acceptance dependencies. No native backend or network.
import 'dart:async';

import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/desktop_services.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';

import 'compact_dashboard_fixture.dart';

class SyntheticMultiSources extends AccountSourcesService {
  @override
  bool get synthetic => true;
  final queries = <String>[];
  final queryFailureKinds = <String, String>{};
  final jobs = <String, int>{};
  int created = 0, shutdowns = 0;
  int cancelFailures = 0, removeFailures = 0;
  bool staleNetworkFailure = true;
  Completer<SourceLoginStatus>? statusGate;

  AccountUsage sample(String id, {DateTime? observed}) {
    final now = DateTime.now();
    final unknown = id == 'profile-unknown';
    final stale = id == 'profile-stale';
    return AccountUsage(
      email: 'same-synthetic-identity@example.test',
      plan: 'synthetic',
      identityKey: 'same-synthetic-identity',
      fetchedAt: observed ?? now,
      detailsIncluded: false,
      buckets: [
        UsageBucket(
          label: 'Codex',
          windows: [
            UsageWindow(
              usedPercent: unknown
                  ? null
                  : stale
                  ? 78
                  : 28,
              durationMinutes: 300,
              resetsAt: unknown
                  ? null
                  : now.add(Duration(minutes: stale ? 40 : 360)),
            ),
            UsageWindow(
              usedPercent: unknown
                  ? null
                  : stale
                  ? 63
                  : 46,
              durationMinutes: 10080,
              resetsAt: unknown ? null : now.add(const Duration(days: 4)),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<SourceCapability> probe() async => const SourceCapability(true, true);
  @override
  Future<String> create() async => 'profile-synthetic${++created}';
  @override
  Future<String> loginStart(String id) async {
    jobs[id] = 0;
    return 'synthetic-job-$id';
  }

  @override
  Future<SourceLoginStatus> loginStatus(String id, String job) async =>
      statusGate != null
      ? statusGate!.future
      : SourceLoginStatus(
          (jobs[id] = (jobs[id] ?? 0) + 1) < 3 ? 'waiting' : 'succeeded',
        );
  @override
  Future<SourceLoginStatus> loginCancel(String id, String job) async {
    if (cancelFailures > 0) {
      cancelFailures--;
      throw const SourceFailure('network');
    }
    jobs.remove(id);
    return const SourceLoginStatus('cancelled');
  }

  @override
  Future<AccountUsage> query(
    String id, {
    String desktopPath = '',
    bool details = false,
  }) async {
    queries.add(id);
    final failure = queryFailureKinds[id];
    if (failure != null) throw SourceFailure(failure);
    if (id == 'profile-stale' && staleNetworkFailure) {
      throw const SourceFailure('network');
    }
    return sample(id);
  }

  @override
  Future<void> remove(String id) async {
    if (removeFailures > 0) {
      removeFailures--;
      throw const SourceFailure('network');
    }
    jobs.remove(id);
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
    jobs.clear();
  }
}

class SyntheticMultiDesktop implements DesktopServices {
  @override
  Future<String?> chooseClient(String platform) async => null;
  @override
  Future<void> copyVerified(String text) async {}
}

Future<
  ({
    AccountSourcesController owner,
    SyntheticMultiSources service,
    CompactDashboardBackend backend,
    SessionMetricsController metrics,
  })
>
syntheticMultiFixture() async {
  final service = SyntheticMultiSources();
  final store = AccountSourceStore.memory();
  await store.write({
    'selectedId': 'profile-primary',
    'pinnedId': 'profile-primary',
    'sources': [
      for (final (id, alias) in [
        ('profile-primary', '主账号'),
        ('profile-stale', '研究来源'),
        ('profile-unknown', '备用来源'),
      ])
        {
          'id': id,
          'alias': alias,
          'generation': 0,
          'usage': service
              .sample(
                id,
                observed: id == 'profile-stale'
                    ? DateTime.now().subtract(const Duration(hours: 3))
                    : null,
              )
              .toCacheJson(),
        },
    ],
  });
  final owner = AccountSourcesController(service, store, offlineTrial: true);
  await owner.initialize(() => '');
  await owner.refresh('profile-stale');
  final backend = CompactDashboardBackend();
  final metrics = SessionMetricsController(backend);
  await metrics.list();
  metrics.select(compactDashboardSessionPath);
  await Future<void>.value();
  return (owner: owner, service: service, backend: backend, metrics: metrics);
}
