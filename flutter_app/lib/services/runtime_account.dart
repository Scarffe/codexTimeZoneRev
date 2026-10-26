import 'backend.dart';

const _runtimePhases = {
  'disconnected',
  'connecting',
  'unattached',
  'awaiting_confirmation',
  'active',
  'unresolved',
  'target_exited',
};
const _runtimeErrorKinds = {
  'unsupported',
  'invalid_target',
  'target_not_found',
  'target_exited',
  'owner_busy',
  'source_busy',
  'busy',
  'auth_required',
  'isolation_failed',
  'cli_changed',
  'identity_changed',
  'source_mismatch',
  'timeout',
  'cancelled',
  'delivery_unresolved',
  'not_written',
  'transport_unavailable',
  'network',
  'rate_limited',
  'shutdown',
  'unavailable',
  'invalid_request',
};

class RuntimeAccountFailure implements Exception {
  const RuntimeAccountFailure(this.kind);
  final String kind;
}

/// Deliberately contains no credential, principal, email or target process data.
class RuntimeAccountStatus {
  const RuntimeAccountStatus({
    this.supported = false,
    this.connected = false,
    this.phase = 'disconnected',
    this.preparing = false,
    this.sourceId,
    this.errorKind,
    this.activeSourceRetained = false,
    this.pendingSourceRetained = false,
  });
  final bool supported, connected, preparing;
  final String phase;
  final String? sourceId, errorKind;
  final bool activeSourceRetained, pendingSourceRetained;
  bool get modelAttributionVerified => false;
  bool get inFlightMayUsePrevious => true;

  factory RuntimeAccountStatus.fromJson(Map<String, dynamic> value) {
    if (value['runtimeVersion'] != 1 ||
        !_runtimePhases.contains(value['phase'])) {
      throw const RuntimeAccountFailure('unavailable');
    }
    final error = value['errorKind'];
    return RuntimeAccountStatus(
      supported: value['supported'] == true,
      connected: value['connected'] == true,
      phase: value['phase'] as String,
      preparing: value['preparing'] == true,
      sourceId: value['sourceId'] is String
          ? value['sourceId'] as String
          : null,
      errorKind: error == null
          ? null
          : _runtimeErrorKinds.contains(error)
          ? error as String
          : 'unavailable',
      activeSourceRetained: value['activeSourceRetained'] == true,
      pendingSourceRetained: value['pendingSourceRetained'] == true,
    );
  }

  RuntimeAccountStatus withError(String kind) => RuntimeAccountStatus(
    supported: supported,
    connected: connected,
    phase: phase,
    preparing: preparing,
    sourceId: sourceId,
    errorKind: kind,
    activeSourceRetained: activeSourceRetained,
    pendingSourceRetained: pendingSourceRetained,
  );
}

abstract class RuntimeAccountService {
  Future<RuntimeAccountStatus> request(String action, {String? sourceId});
}

class NativeRuntimeAccountService implements RuntimeAccountService {
  NativeRuntimeAccountService(this.backend, {this.offlineTrial = false});
  final LauncherBackend backend;
  final bool offlineTrial;
  @override
  Future<RuntimeAccountStatus> request(
    String action, {
    String? sourceId,
  }) async {
    if (offlineTrial) {
      return const RuntimeAccountStatus(errorKind: 'offline_disabled');
    }
    if (!const {
          'status',
          'connect',
          'switch',
          'cancel',
          'reconcile',
          'stop_unowned',
        }.contains(action) ||
        (action == 'switch' &&
            (sourceId == null || sourceId.isEmpty || sourceId == 'current'))) {
      throw const RuntimeAccountFailure('invalid_request');
    }
    try {
      return RuntimeAccountStatus.fromJson(
        await backend.call('desktop_runtime', {
          'action': action,
          if (action == 'switch') 'sourceId': sourceId,
        }),
      );
    } on RuntimeAccountFailure {
      rethrow;
    } catch (_) {
      throw const RuntimeAccountFailure('unavailable');
    }
  }
}

/// Pure in-memory preview. It has no native delegate or credential dependency.
final class SyntheticRuntimeAccountService implements RuntimeAccountService {
  RuntimeAccountStatus _status = const RuntimeAccountStatus(supported: true);
  @override
  Future<RuntimeAccountStatus> request(
    String action, {
    String? sourceId,
  }) async {
    switch (action) {
      case 'status':
      case 'reconcile':
        return _status;
      case 'connect':
        _status = const RuntimeAccountStatus(
          supported: true,
          connected: true,
          phase: 'unattached',
        );
      case 'switch':
        if (!_status.connected ||
            sourceId == null ||
            sourceId.isEmpty ||
            sourceId == 'current') {
          throw const RuntimeAccountFailure('invalid_request');
        }
        _status = RuntimeAccountStatus(
          supported: true,
          connected: true,
          phase: 'active',
          sourceId: sourceId,
          activeSourceRetained: true,
        );
      case 'cancel':
        break;
      case 'stop_unowned':
        if (_status.activeSourceRetained ||
            _status.pendingSourceRetained ||
            _status.preparing) {
          return _status.withError('owner_busy');
        }
        _status = const RuntimeAccountStatus(supported: true);
      default:
        throw const RuntimeAccountFailure('invalid_request');
    }
    return _status;
  }
}
