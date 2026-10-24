import 'dart:convert';

import 'package:crypto/crypto.dart';

String? _text(Object? value, {int max = 32768}) =>
    value is String && value.trim().isNotEmpty && value.length <= max
    ? value
    : null;
String _required(Object? value) =>
    _text(value) ??
    (throw const FormatException('invalid_attention_reference'));

/// Titles and aliases are bounded metadata, never a raw sourceInfo payload.
String attentionTitle(String value) => value
    .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
    .trim()
    .charactersTake(160);

extension on String {
  String charactersTake(int count) => String.fromCharCodes(runes.take(count));
}

String attentionPathIdentity(String value) {
  if (value.startsWith(r'\\?\UNC\')) {
    value = r'\\' + value.substring(8);
  } else if (value.startsWith(r'\\?\')) {
    value = value.substring(4);
  }
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value) || value.startsWith(r'\\')) {
    return value.replaceAll('/', r'\').toLowerCase();
  }
  return value;
}

enum SessionAttentionStatus { unknown, running, completed, cancelled }

SessionAttentionStatus _status(Object? value) => switch (value) {
  'running' => SessionAttentionStatus.running,
  'completed' => SessionAttentionStatus.completed,
  'cancelled' => SessionAttentionStatus.cancelled,
  _ => SessionAttentionStatus.unknown,
};

class AttentionSession {
  const AttentionSession({
    required this.path,
    required this.id,
    required this.title,
  });
  final String path, id, title;
  static AttentionSession? fromMetadata(Object? value) {
    if (value is! Map) return null;
    final path = _text(value['path']), id = _text(value['id']);
    if (path == null || id == null) return null;
    return AttentionSession(
      path: path,
      id: id,
      title: attentionTitle(_text(value['title']) ?? '会话 $id'),
    );
  }
}

class SessionAttentionWatch {
  const SessionAttentionWatch({
    required this.key,
    required this.path,
    required this.expectedSessionId,
    this.alias,
    this.enabled = true,
  });
  final String key, path, expectedSessionId;
  final String? alias;
  final bool enabled;
  String get title => alias?.isNotEmpty == true
      ? alias!
      : attentionTitle('会话 $expectedSessionId');
  SessionAttentionWatch copyWith({bool? enabled, String? alias}) =>
      SessionAttentionWatch(
        key: key,
        path: path,
        expectedSessionId: expectedSessionId,
        alias: alias ?? this.alias,
        enabled: enabled ?? this.enabled,
      );
  Map<String, Object?> toJson() => {
    'key': key,
    'path': path,
    'expectedSessionId': expectedSessionId,
    'alias': alias,
    'enabled': enabled,
  };
  factory SessionAttentionWatch.fromJson(Map value) {
    if (value['enabled'] is! bool ||
        (value['alias'] != null && value['alias'] is! String)) {
      throw const FormatException('invalid_attention_watch');
    }
    return SessionAttentionWatch(
      key: _required(value['key']),
      path: _required(value['path']),
      expectedSessionId: _required(value['expectedSessionId']),
      alias: value['alias'] == null
          ? null
          : attentionTitle(value['alias'] as String),
      enabled: value['enabled'] as bool,
    );
  }
}

class SessionAttentionItem {
  const SessionAttentionItem({
    required this.watch,
    this.status = SessionAttentionStatus.unknown,
    this.observedAt,
    this.readError,
    this.catchingUp = false,
  });
  final SessionAttentionWatch watch;
  final SessionAttentionStatus status;
  final DateTime? observedAt;
  final String? readError;
  final bool catchingUp;
  String get key => watch.key;
  String get path => watch.path;
  String get expectedSessionId => watch.expectedSessionId;
  String? get alias => watch.alias;
  String get title => watch.title;
  Duration? ageAt(DateTime now) =>
      observedAt == null ? null : now.difference(observedAt!);
}

class SessionAttentionNotice {
  const SessionAttentionNotice({
    required this.watchKey,
    required this.path,
    required this.sessionId,
    required this.turnId,
    required this.title,
    required this.createdAt,
    this.read = false,
    this.durationMs,
  });
  final String watchKey, path, sessionId, turnId, title;
  final DateTime createdAt;
  final bool read;
  final int? durationMs;
  String get id => sha256
      .convert(utf8.encode(jsonEncode([watchKey, sessionId, turnId])))
      .toString();
  SessionAttentionNotice asRead() => SessionAttentionNotice(
    watchKey: watchKey,
    path: path,
    sessionId: sessionId,
    turnId: turnId,
    title: title,
    createdAt: createdAt,
    read: true,
    durationMs: durationMs,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'watchKey': watchKey,
    'path': path,
    'sessionId': sessionId,
    'turnId': turnId,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'read': read,
    'durationMs': durationMs,
  };
  factory SessionAttentionNotice.fromJson(Map value) {
    final duration = value['durationMs'];
    if (value['read'] is! bool ||
        (duration != null && (duration is! int || duration < 0))) {
      throw const FormatException('invalid_attention_notice');
    }
    final notice = SessionAttentionNotice(
      watchKey: _required(value['watchKey']),
      path: _required(value['path']),
      sessionId: _required(value['sessionId']),
      turnId: _required(value['turnId']),
      title: attentionTitle(_required(value['title'])),
      createdAt: DateTime.parse(_required(value['createdAt'])),
      read: value['read'] as bool,
      durationMs: duration as int?,
    );
    if (value['id'] != notice.id) {
      throw const FormatException('invalid_attention_notice_id');
    }
    return notice;
  }
}

/// Only allowlisted summary fields survive the native map boundary.
class AttentionObservation {
  AttentionObservation._(
    this.sessionId,
    this.epoch,
    this.status,
    this.turnId,
    this.catchingUp,
    this.terminals,
  );
  final String sessionId;
  final int epoch;
  final SessionAttentionStatus status;
  final String? turnId;
  final bool catchingUp;
  final List<AttentionTerminal> terminals;
  factory AttentionObservation.fromSummary(
    Map<String, dynamic> value,
    String expectedId,
  ) {
    final info = value['sourceInfo'];
    final id = info is Map ? _text(info['id']) : null;
    if (id == null || id != expectedId) {
      throw const FormatException('会话标识缺失或已变化，请重新选择');
    }
    if (value['logEpoch'] is! int ||
        value['catchingUp'] is! bool ||
        value['terminals'] is! List) {
      throw const FormatException('会话状态摘要不可用');
    }
    final current = value['current'];
    final turnId = current is Map ? _text(current['turnId']) : null;
    final status = turnId == null
        ? SessionAttentionStatus.unknown
        : _status(current['status']);
    final terminals = <AttentionTerminal>[];
    for (final terminal in value['terminals'] as List) {
      if (terminal is! Map) continue;
      final turn = _text(terminal['turnId']);
      final state = _status(terminal['status']);
      if (turn == null ||
          ![
            SessionAttentionStatus.completed,
            SessionAttentionStatus.cancelled,
          ].contains(state)) {
        continue;
      }
      final duration = terminal['durationMs'];
      terminals.add(
        AttentionTerminal(
          turn,
          state,
          duration is int && duration >= 0 ? duration : null,
        ),
      );
    }
    return AttentionObservation._(
      id,
      value['logEpoch'] as int,
      status,
      turnId,
      value['catchingUp'] as bool,
      List.unmodifiable(terminals),
    );
  }
}

class AttentionTerminal {
  const AttentionTerminal(this.turnId, this.status, this.durationMs);
  final String turnId;
  final SessionAttentionStatus status;
  final int? durationMs;
}

/// Preserve survivor order and unread work before keeping read history.
List<SessionAttentionNotice> retainAttentionNotices(
  List<SessionAttentionNotice> notices,
) {
  final overflow = notices.length - 200;
  if (overflow <= 0) return List.unmodifiable(notices);
  var readToRemove = notices.where((notice) => notice.read).length;
  if (readToRemove > overflow) readToRemove = overflow;
  var unreadToRemove = overflow - readToRemove;
  final retained = <SessionAttentionNotice>[];
  for (final notice in notices) {
    if (notice.read && readToRemove > 0) {
      readToRemove--;
    } else if (!notice.read && unreadToRemove > 0) {
      unreadToRemove--;
    } else {
      retained.add(notice);
    }
  }
  return List.unmodifiable(retained);
}

class SessionAttentionSnapshot {
  SessionAttentionSnapshot({
    required List<SessionAttentionWatch> watches,
    required List<SessionAttentionNotice> notices,
  }) : watches = List.unmodifiable(watches),
       notices = retainAttentionNotices(notices);
  final List<SessionAttentionWatch> watches;
  final List<SessionAttentionNotice> notices;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'watches': [for (final w in watches) w.toJson()],
    'notices': [for (final n in notices) n.toJson()],
  };
  factory SessionAttentionSnapshot.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['watches'] is! List ||
        value['notices'] is! List) {
      throw const FormatException('invalid_attention_store');
    }
    final watches = (value['watches'] as List)
        .map((v) => SessionAttentionWatch.fromJson(v as Map))
        .toList();
    final notices = (value['notices'] as List)
        .map((v) => SessionAttentionNotice.fromJson(v as Map))
        .toList();
    if (watches.length > 8 ||
        watches.map((w) => w.key).toSet().length != watches.length ||
        watches.map((w) => attentionPathIdentity(w.path)).toSet().length !=
            watches.length ||
        notices.map((n) => n.id).toSet().length != notices.length) {
      throw const FormatException('invalid_attention_duplicates');
    }
    return SessionAttentionSnapshot(watches: watches, notices: notices);
  }
}
