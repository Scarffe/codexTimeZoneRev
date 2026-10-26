import '../services/session_attention.dart';
import 'app_copy.dart';
import 'copy_types.dart';

const sessionMessages = <String, AppMessage>{
  'sessions.generatedSessionTitle': (zh: '会话 {id}', en: 'Session {id}'),
  'sessions.diagnostic.restore': (
    zh: '关注记录无法恢复；原始文件将在下次保存前备份。',
    en: 'Watch records could not be restored; the original file will be backed up before the next save.',
  ),
  'sessions.diagnostic.initialize': (
    zh: '请先初始化会话关注记录',
    en: 'Initialize session watch records first',
  ),
  'sessions.diagnostic.list': (
    zh: '会话列表读取失败。',
    en: 'The session list could not be read.',
  ),
  'sessions.diagnostic.limit': (zh: '最多关注 8 个会话', en: 'Watch up to 8 sessions'),
  'sessions.diagnostic.identity': (
    zh: '该路径的会话标识已变化；请先移除旧关注',
    en: 'The session identity at this path changed; remove the old watch first',
  ),
  'sessions.diagnostic.uninitialized': (
    zh: '关注记录尚未初始化，无法保存。',
    en: 'Watch records have not been initialized and cannot be saved.',
  ),
  'sessions.diagnostic.save': (
    zh: '关注记录保存失败；本次提醒未发送。',
    en: 'Watch records could not be saved; this reminder was not sent.',
  ),
  'sessions.diagnostic.finalSave': (
    zh: '关注记录最终保存失败，请重试退出',
    en: 'The final watch save failed. Try exiting again.',
  ),

  'sessions.watchedUnread': (
    zh: '明确关注 {p0}/8 · 未读 {p1}',
    en: 'Watched {p0}/8 · Unread {p1}',
  ),
  'sessions.onlyExplicitlyWatchedSessionsAreReadRecent': (
    zh: '只读取你明确关注的会话；不会根据最近活动自动添加。新关注先建立基线，历史完成不产生提醒。',
    en: 'Only explicitly watched sessions are read. Recent activity never adds sessions automatically. New watches establish a baseline; historical completions do not notify.',
  ),
  'sessions.listAvailableSessions': (
    zh: '列出可关注会话',
    en: 'List available sessions',
  ),
  'sessions.noSessionsAvailable': (
    zh: '暂无可选择的会话。',
    en: 'No sessions available.',
  ),
  'sessions.localSessions': (zh: '本机会话', en: 'Local sessions'),
  'sessions.aliasOptional': (zh: '别名（可选）', en: 'Alias (optional)'),
  'sessions.watchLimitReached': (
    zh: '已达到 8 个关注上限',
    en: 'Watch limit reached (8)',
  ),
  'sessions.addWatch': (zh: '添加关注', en: 'Add watch'),
  'sessions.changesNotSaved': (zh: '操作未保存：{p0}', en: 'Changes not saved: {p0}'),
  'sessions.unread': (zh: '未读', en: 'Unread'),
  'sessions.watching': (zh: '关注中', en: 'Watching'),
  'sessions.all': (zh: '全部', en: 'All'),
  'sessions.markAllAsRead': (zh: '全部标为已读', en: 'Mark all as read'),
  'sessions.noActiveWatches': (zh: '暂无启用的关注。', en: 'No active watches.'),
  'sessions.noWatchesAdded': (zh: '尚未添加关注。', en: 'No watches added.'),
  'sessions.paused': (zh: '已暂停', en: 'Paused'),
  'sessions.readFailedCurrentStatusUnknownTaskFailure': (
    zh: '读取失败 · 当前状态未知；不会推断任务失败。',
    en: 'Read failed · Current status unknown; task failure is not inferred.',
  ),
  'sessions.readingHistoryBaselineNotYetComplete': (
    zh: '正在读取历史 · 尚未建立完整基线',
    en: 'Reading history · Baseline not yet complete',
  ),
  'sessions.pauseWatch': (zh: '暂停关注', en: 'Pause watch'),
  'sessions.resumeWatch': (zh: '恢复关注', en: 'Resume watch'),
  'sessions.removeWatch': (zh: '移除关注', en: 'Remove watch'),
  'sessions.noUnreadReminders': (zh: '暂无未读提醒。', en: 'No unread reminders.'),
  'sessions.noCompletionReminders': (
    zh: '暂无完成提醒。',
    en: 'No completion reminders.',
  ),
  'sessions.read': (zh: '已读', en: 'Read'),
  'sessions.turnCompleted': (zh: '回合已完成 · {p0}', en: 'Turn completed · {p0}'),
  'sessions.sessionTurn': (
    zh: '会话 {p0} · 回合 {p1}',
    en: 'Session {p0} · Turn {p1}',
  ),
  'sessions.openOriginalSessionAnalysis': (
    zh: '打开原会话分析',
    en: 'Open original session analysis',
  ),
  'sessions.markAsRead': (zh: '标为已读', en: 'Mark as read'),
  'sessions.turnRunning': (zh: '回合进行中', en: 'Turn running'),
  'sessions.turnCompleted2': (zh: '回合已完成', en: 'Turn completed'),
  'sessions.cancelled': (zh: '已取消', en: 'Cancelled'),
  'sessions.statusUnknown': (zh: '状态未知', en: 'Status unknown'),
};

extension SessionInboxCopy on AppCopy {
  String attentionWatchTitle(SessionAttentionWatch watch) =>
      watch.alias?.isNotEmpty == true
      ? watch.alias!
      : text(
          'sessions.generatedSessionTitle',
          args: {'id': watch.expectedSessionId},
        );

  String attentionDiagnostic(Object error) {
    if (!isEnglish) return error.toString();
    final raw = error is StateError ? error.message : error.toString();
    return switch (raw) {
      '关注记录无法恢复；原始文件将在下次保存前备份。' => text('sessions.diagnostic.restore'),
      '请先初始化会话关注记录' => text('sessions.diagnostic.initialize'),
      '会话列表读取失败。' => text('sessions.diagnostic.list'),
      '最多关注 8 个会话' => text('sessions.diagnostic.limit'),
      '该路径的会话标识已变化；请先移除旧关注' => text('sessions.diagnostic.identity'),
      '关注记录尚未初始化，无法保存。' => text('sessions.diagnostic.uninitialized'),
      '关注记录保存失败；本次提醒未发送。' => text('sessions.diagnostic.save'),
      '关注记录最终保存失败，请重试退出' => text('sessions.diagnostic.finalSave'),
      _ => error.toString(),
    };
  }
}
