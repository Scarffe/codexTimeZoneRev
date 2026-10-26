import 'backend.dart';

class GlobalLiveItem {
  const GlobalLiveItem({
    required this.threadId,
    this.turnId,
    required this.state,
    required this.attention,
    required this.observedAtMs,
    required this.sequence,
  });
  final String threadId, state, attention;
  final String? turnId;
  final int observedAtMs, sequence;
}

class GlobalLiveSnapshot {
  const GlobalLiveSnapshot({
    this.connected = false,
    this.coverage = 'unavailable',
    this.dropped = 0,
    this.generation = 0,
    this.items = const [],
  });
  final bool connected;
  final String coverage;
  final int dropped, generation;
  final List<GlobalLiveItem> items;
  bool get initialGap => true;
  factory GlobalLiveSnapshot.fromJson(Map<String, dynamic> value) {
    if (value['liveVersion'] != 1 ||
        !const {'partial', 'unavailable'}.contains(value['coverage']) ||
        value['items'] is! List) {
      throw const FormatException('invalid_global_live_snapshot');
    }
    final items = <GlobalLiveItem>[];
    for (final raw in value['items'] as List) {
      if (raw is! Map ||
          raw['threadId'] is! String ||
          (raw['threadId'] as String).isEmpty ||
          !const {
            'unknown',
            'not_loaded',
            'idle',
            'running',
            'completed',
            'cancelled',
            'failed',
          }.contains(raw['state']) ||
          !const {
            'unknown',
            'none',
            'approval',
            'input',
            'approval_and_input',
          }.contains(raw['attention']) ||
          raw['observedAtMs'] is! int ||
          raw['sequence'] is! int ||
          (raw['turnId'] != null && raw['turnId'] is! String)) {
        throw const FormatException('invalid_global_live_item');
      }
      items.add(
        GlobalLiveItem(
          threadId: raw['threadId'] as String,
          turnId: raw['turnId'] as String?,
          state: raw['state'] as String,
          attention: raw['attention'] as String,
          observedAtMs: raw['observedAtMs'] as int,
          sequence: raw['sequence'] as int,
        ),
      );
    }
    return GlobalLiveSnapshot(
      connected: value['connected'] == true,
      coverage: value['coverage'] as String,
      dropped: value['dropped'] is int ? value['dropped'] as int : 0,
      generation: value['generation'] is int ? value['generation'] as int : 0,
      items: List.unmodifiable(items),
    );
  }
}

abstract class GlobalLiveService {
  Future<GlobalLiveSnapshot> status();
}

class NativeGlobalLiveService implements GlobalLiveService {
  NativeGlobalLiveService(this.backend);
  final LauncherBackend backend;
  @override
  Future<GlobalLiveSnapshot> status() async => GlobalLiveSnapshot.fromJson(
    await backend.call('global_live', {'action': 'status'}),
  );
}

final class SyntheticGlobalLiveService implements GlobalLiveService {
  SyntheticGlobalLiveService({this.snapshot = const GlobalLiveSnapshot()});
  final GlobalLiveSnapshot snapshot;
  @override
  Future<GlobalLiveSnapshot> status() async => snapshot;
}
