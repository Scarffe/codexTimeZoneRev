import 'account_usage.dart';
import 'backend.dart';

const currentAccountSource = 'current';

/// Public failure kinds, never raw transport messages or account identities.
class SourceFailure implements Exception {
  const SourceFailure(this.kind);
  final String kind;
  @override
  String toString() => sourceErrorMessage(kind);
}

String sourceErrorMessage(String? kind) => switch (kind) {
  'auth_required' || 'auth_failed' => '请重新登录此监控来源。',
  'network' => '网络暂不可用，保留上次观测。',
  'rate_limited' => '请求过于频繁，请稍后重试。',
  'timeout' => '查询超时，请稍后重试。',
  'unsupported' || 'isolation_failed' => '当前环境不支持安全添加来源。',
  'cancelled' => '操作已取消。',
  'busy' => '此来源正在处理其他操作。',
  _ => '来源暂不可用，请稍后重试。',
};

class SourceCapability {
  const SourceCapability(this.supported, this.managedLogin);
  final bool supported, managedLogin;
}

class SourceLoginStatus {
  const SourceLoginStatus(this.state, {this.errorKind});
  final String state;
  final String? errorKind;
  bool get terminal =>
      ['succeeded', 'failed', 'cancelled', 'timed_out'].contains(state);
}

abstract class AccountSourcesService {
  /// Only an explicitly injected pure fixture may opt in during offline trials.
  bool get synthetic => false;
  Future<SourceCapability> probe();
  Future<String> create();
  Future<String> loginStart(String id);
  Future<SourceLoginStatus> loginStatus(String id, String job);
  Future<SourceLoginStatus> loginCancel(String id, String job);
  Future<AccountUsage> query(
    String id, {
    String desktopPath = '',
    bool details = false,
  });
  Future<void> remove(String id);
  Future<void> shutdown();
}

class NativeAccountSourcesService extends AccountSourcesService {
  NativeAccountSourcesService(this.backend, {this.offlineTrial = false});
  final LauncherBackend backend;
  final bool offlineTrial;
  Future<Map<String, dynamic>> _call(
    String command, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (offlineTrial) throw const SourceFailure('unsupported');
    Map<String, dynamic> result;
    try {
      result = await backend.call(command, args);
    } catch (_) {
      throw const SourceFailure('unavailable');
    }
    if (result['ok'] != true) {
      final error = result['error'];
      throw SourceFailure(
        error is Map && error['kind'] is String
            ? error['kind'] as String
            : 'unavailable',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> _sourceCall(
    String command,
    String id, [
    Map<String, dynamic> args = const {},
  ]) async {
    final value = await _call(command, {'sourceId': id, ...args});
    if (value['sourceId'] != id ||
        (args.containsKey('jobId') && value['jobId'] != args['jobId'])) {
      throw const SourceFailure('identity_changed');
    }
    return value;
  }

  @override
  Future<SourceCapability> probe() async {
    final value = await _call('account_source_probe');
    return SourceCapability(
      value['supported'] == true,
      value['managedLogin'] == true,
    );
  }

  @override
  Future<String> create() async =>
      (await _call('account_source_create'))['sourceId'] as String;
  @override
  Future<String> loginStart(String id) async =>
      (await _sourceCall('account_source_login_start', id))['jobId'] as String;
  @override
  Future<SourceLoginStatus> loginStatus(String id, String job) async {
    final value = await _sourceCall('account_source_login_status', id, {
      'jobId': job,
    });
    final error = value['error'];
    return SourceLoginStatus(
      value['state'] as String,
      errorKind: error is Map ? error['kind'] as String? : null,
    );
  }

  @override
  Future<SourceLoginStatus> loginCancel(String id, String job) async {
    final value = await _sourceCall('account_source_login_cancel', id, {
      'jobId': job,
    });
    final state = value['state'];
    if (!['succeeded', 'failed', 'timed_out', 'cancelled'].contains(state)) {
      throw const SourceFailure('unavailable');
    }
    final error = value['error'];
    return SourceLoginStatus(
      state as String,
      errorKind: error is Map && error['kind'] is String
          ? error['kind'] as String
          : null,
    );
  }

  @override
  Future<AccountUsage> query(
    String id, {
    String desktopPath = '',
    bool details = false,
  }) async {
    final value = await _sourceCall('account_source_usage', id, {
      if (id == currentAccountSource) 'desktopPath': desktopPath,
      'details': id == currentAccountSource && details,
    });
    // Native queriedAtMs is this machine's query completion time, not a
    // server sampling timestamp. Invalid/missing values retain receipt quality.
    final completedAtMs = value['queriedAtMs'];
    final queriedAt =
        completedAtMs is int &&
            completedAtMs > 0 &&
            completedAtMs <= 8640000000000000
        ? DateTime.fromMillisecondsSinceEpoch(completedAtMs, isUtc: true)
        : null;
    return AccountUsage.fromJson(
      value['usage'] as Map<String, dynamic>,
      queriedAt: queriedAt,
    );
  }

  @override
  Future<void> remove(String id) async {
    await _sourceCall('account_source_remove', id);
  }

  @override
  Future<void> shutdown() async {
    await _call('account_source_shutdown');
  }
}

/// Mutable only by the source owner; never use identity/email as a catalog key.
class AccountSourceState {
  AccountSourceState({
    required this.id,
    required this.alias,
    this.generation = 0,
  });
  final String id;
  String alias;
  int generation;
  AccountUsage? usage;
  String? errorKind, jobId;
  String loginState = 'idle';
  bool busy = false;
  bool pendingRemoval = false;
  int failures = 0, attempts = 0, revision = 0;
  DateTime? nextRefreshAt, lastAttempt;
  bool get isCurrent => id == currentAccountSource;
  bool get loggingIn => [
    'starting',
    'waiting',
    'cancelling',
    'cancel_failed',
  ].contains(loginState);
  String? get error => errorKind == null ? null : sourceErrorMessage(errorKind);
}
