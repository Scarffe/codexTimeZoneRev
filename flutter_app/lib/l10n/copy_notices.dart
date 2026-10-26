import 'copy_types.dart';

const noticeMessages = <String, AppMessage>{
  'notice.exitIncomplete': (
    zh: '退出清理未完成，监控已停止；请再次选择退出以重试。',
    en: 'Exit cleanup is incomplete and monitoring has stopped. Choose Exit again to retry.',
  ),
  'notice.refreshing': (zh: '正在刷新', en: 'Refreshing'),
  'notice.stale': (zh: '缓存已过期', en: 'Stale observation'),
  'notice.unavailable': (zh: '不可用', en: 'Unavailable'),
  'notice.paused': (zh: '已暂停', en: 'Paused'),
  'notice.monitoring': (zh: '自动监控', en: 'Monitoring'),
  'notice.window': (zh: '额度', en: 'Quota'),
  'notice.windowMinutes': (zh: '{count} 分钟额度', en: '{count}-minute quota'),
  'notice.windowHours': (zh: '{count} 小时额度', en: '{count}-hour quota'),
  'notice.windowDays': (zh: '{count} 天额度', en: '{count}-day quota'),
  'notice.windowWeek': (zh: '周额度', en: 'Weekly quota'),
  'notice.resetUnknown': (zh: '重置时间未知', en: 'Reset time unknown'),
  'notice.resetAwaiting': (
    zh: '已到重置时间 · 等待查询确认',
    en: 'Reset is due · Awaiting a fresh query',
  ),
  'notice.reset': (
    zh: '{time} 重置 · {relative}',
    en: 'Resets {time} · {relative}',
  ),
  'notice.quotaSummary': (
    zh: '{name} · 剩余 {value} · {status}',
    en: '{name} · {value} remaining · {status}',
  ),
  'notice.lowQuota': (
    zh: '{name} · 额度偏低，请查看剩余额度。',
    en: '{name} · Quota is low. Check the remaining quota.',
  ),
  'notice.selectedCompleted': (
    zh: '所选会话的回合已结束',
    en: 'The selected session turn completed',
  ),
  'notice.completed': (zh: '{name} · 回合已结束', en: '{name} · Turn completed'),
  'notice.session.none': (zh: '未选择会话', en: 'No session selected'),
  'notice.session.unavailable': (
    zh: '状态未知 · 读取失败',
    en: 'Unknown · Read failed',
  ),
  'notice.session.history': (
    zh: '状态未知 · 正在读取历史',
    en: 'Unknown · Reading history',
  ),
  'notice.session.running': (zh: '回合进行中', en: 'Turn running'),
  'notice.session.completed': (zh: '回合已结束', en: 'Turn completed'),
  'notice.session.cancelled': (zh: '已取消', en: 'Cancelled'),
  'notice.session.unknown': (zh: '状态未知', en: 'Unknown'),
  'notice.turnRate': (
    zh: '回合平均吞吐：{value}',
    en: 'Turn-average throughput: {value}',
  ),
};
