import 'copy_types.dart';

const AppMessages runtimeMessages = {
  'runtime.title': (zh: '当前 Codex 运行账号', en: 'Account for running Codex'),
  'runtime.connect': (
    zh: '连接当前 Codex（不重启）',
    en: 'Connect running Codex · no restart',
  ),
  'runtime.useSource': (
    zh: '用于当前 Codex · {alias}',
    en: 'Use for running Codex · {alias}',
  ),
  'runtime.cancel': (zh: '取消准备', en: 'Cancel preparation'),
  'runtime.reconcile': (zh: '重新核验', en: 'Reconcile identity'),
  'runtime.refresh': (zh: '更新状态', en: 'Refresh status'),
  'runtime.working': (zh: '正在处理', en: 'Working'),
  'runtime.unbound': (zh: '尚未绑定监控来源', en: 'No monitoring source attached'),
  'runtime.retainedUnknown': (
    zh: '运行账号仍保留 · 其他来源',
    en: 'Running account retained · another source',
  ),
  'runtime.currentAlias': (
    zh: '当前运行账号 · {alias}',
    en: 'Running account · {alias}',
  ),
  'runtime.retainedAlias': (
    zh: '已保留账号 · {alias}',
    en: 'Retained account · {alias}',
  ),
  'runtime.otherSource': (zh: '其他已连接来源', en: 'Another connected source'),
  'runtime.requestedAlias': (
    zh: '待核验目标 · {alias}',
    en: 'Requested account · {alias}',
  ),
  'runtime.loginFirst': (
    zh: '请先在账号来源完成官方登录',
    en: 'Sign in through the account source first.',
  ),
  'runtime.inFlight': (
    zh: '在途请求可能沿用原账号',
    en: 'In-flight requests may keep using the previous account.',
  ),
  'runtime.synthetic': (
    zh: '合成演示 · 不改变真实账号',
    en: 'Synthetic preview · real accounts stay unchanged',
  ),
  'runtime.phase.disconnected': (zh: '未连接', en: 'Disconnected'),
  'runtime.phase.connecting': (zh: '正在连接', en: 'Connecting'),
  'runtime.phase.unattached': (zh: '已连接 · 未绑定', en: 'Connected · unattached'),
  'runtime.phase.preparing': (zh: '正在准备', en: 'Preparing'),
  'runtime.phase.awaiting_confirmation': (
    zh: '等待身份确认',
    en: 'Awaiting identity confirmation',
  ),
  'runtime.phase.active': (zh: '身份观察一致', en: 'Identity observation matches'),
  'runtime.phase.unresolved': (zh: '切换待核验', en: 'Switch needs reconciliation'),
  'runtime.phase.target_exited': (zh: 'Codex 已退出', en: 'Codex exited'),
  'runtime.error.auth': (
    zh: '此来源需要重新登录',
    en: 'This source needs to sign in again.',
  ),
  'runtime.error.busy': (
    zh: '账号来源忙，请稍后重试',
    en: 'The source is busy. Try again shortly.',
  ),
  'runtime.error.target': (
    zh: '未找到可连接的 Codex',
    en: 'No supported running Codex was found.',
  ),
  'runtime.error.unsupported': (
    zh: '当前 Codex 版本暂不支持连接',
    en: 'This Codex version does not support attachment.',
  ),
  'runtime.error.configuration': (
    zh: '来源环境已变化，请重新核验',
    en: 'The source environment changed. Reconcile again.',
  ),
  'runtime.error.pending': (
    zh: '结果尚未确认，请重新核验',
    en: 'The outcome is not confirmed. Reconcile identity.',
  ),
  'runtime.error.retry': (
    zh: '暂时无法确认状态，请稍后重试',
    en: 'Status could not be confirmed. Try again shortly.',
  ),
  'runtime.error.cancelled': (
    zh: '已取消尚未发送的准备',
    en: 'Unsent preparation was cancelled.',
  ),
};
