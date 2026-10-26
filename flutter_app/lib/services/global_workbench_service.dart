import 'backend.dart';
import 'global_workbench.dart';

/// Production transport: no scan is performed by query, no model/account calls.
class GlobalWorkbenchService {
  GlobalWorkbenchService(this.backend);
  final LauncherBackend backend;
  bool get synthetic => false;
  Future<void> capabilities() async {
    final value = await backend.call('global_monitor', {
      'action': 'capabilities',
    });
    if (value['globalVersion'] != 1 ||
        value['localReadOnly'] != true ||
        value['queryScans'] != false) {
      throw const FormatException('unsupported_global_capabilities');
    }
  }

  Future<GlobalSnapshot> scan({
    required int generation,
    List<String>? roots,
    int? nowMs,
  }) async => GlobalSnapshot.fromJson(
    await backend.call('global_monitor', {
      'action': 'scan',
      'generation': generation,
      'roots': ?roots,
      'nowMs': ?nowMs,
    }),
  );
  Future<GlobalSnapshot> query(
    GlobalQuery query, {
    int? expectedRevision,
  }) async => GlobalSnapshot.fromJson(
    await backend.call(
      'global_monitor',
      query.toJson(expectedRevision: expectedRevision),
    ),
  );
  Future<void> cancel(int generation) async {
    await backend.call('global_monitor', {
      'action': 'cancel',
      'generation': generation,
    });
  }

  Future<void> shutdown() async {
    await backend.call('global_monitor', {'action': 'shutdown'});
  }
}

/// Explicitly pure, in-memory demo source. It cannot delegate to native or read a root.
final class SyntheticGlobalWorkbenchService extends GlobalWorkbenchService {
  SyntheticGlobalWorkbenchService({GlobalSnapshot? snapshot})
    : _snapshot = snapshot ?? _empty(),
      super(const _NoGlobalBackend());
  final GlobalSnapshot _snapshot;
  @override
  bool get synthetic => true;
  @override
  Future<void> capabilities() async {}
  @override
  Future<GlobalSnapshot> scan({
    required int generation,
    List<String>? roots,
    int? nowMs,
  }) async => _snapshot;
  @override
  Future<GlobalSnapshot> query(
    GlobalQuery query, {
    int? expectedRevision,
  }) async => _snapshot;
  @override
  Future<void> cancel(int generation) async {}
  @override
  Future<void> shutdown() async {}
  static GlobalSnapshot _empty() => GlobalSnapshot(
    revision: 0,
    indexEpoch: 0,
    phase: 'empty',
    observedAtMs: 0,
    restored: false,
    coverage: const GlobalCoverage(),
    totals: GlobalTotals(
      tokens: const GlobalTokens(),
      sessions: 0,
      states: const {},
      attention: const {},
      staleRunning: 0,
    ),
    filteredCount: 0,
    offset: 0,
    hasMore: false,
  );
}

class _NoGlobalBackend implements LauncherBackend {
  const _NoGlobalBackend();
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async => throw StateError('synthetic_global_has_no_delegate');
}
