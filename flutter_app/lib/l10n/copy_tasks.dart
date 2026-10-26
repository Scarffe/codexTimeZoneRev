import 'copy_types.dart';

const taskMessages = <String, AppMessage>{
  'tasks.tab': (zh: '独立任务', en: 'Independent tasks'),
  'tasks.attentionTab': (zh: '关注事项', en: 'Attention'),
  'tasks.title': (zh: '独立账号新任务', en: 'New independent account task'),
  'tasks.subtitle': (
    zh: '先准备，再明确启动；任务输出独立于本地会话图表。',
    en: 'Prepare first, then explicitly start. Task output stays separate from local session charts.',
  ),
  'tasks.mode': (zh: '任务模式', en: 'Task mode'),
  'tasks.mode.offline_preview': (zh: '合成预览', en: 'Synthetic preview'),
  'tasks.mode.official': (zh: '独立官方任务', en: 'Independent official task'),
  'tasks.previewNotice': (
    zh: '合成来源与目录，不读取账号，也不发送模型请求。',
    en: 'Synthetic sources and workspace; no account reads or model requests.',
  ),
  'tasks.officialNotice': (
    zh: '启动将使用明确选择的专用来源创建新线程；不会恢复当前 Codex。',
    en: 'Start creates a new thread using the explicitly selected managed source.',
  ),
  'tasks.source': (zh: '明确来源', en: 'Explicit source'),
  'tasks.previewA': (zh: '合成来源 A', en: 'Synthetic source A'),
  'tasks.previewB': (zh: '合成来源 B', en: 'Synthetic source B'),
  'tasks.noSources': (
    zh: '请先在账号工作区添加并登录专用来源。',
    en: 'Add and sign in to a managed source in Accounts first.',
  ),
  'tasks.workspace': (zh: '现有工作目录', en: 'Existing workspace directory'),
  'tasks.chooseWorkspace': (zh: '选择文件夹', en: 'Choose folder'),
  'tasks.model': (zh: '模型标识', en: 'Model identifier'),
  'tasks.prompt': (zh: '任务内容（仅本次会话）', en: 'Task prompt (this session only)'),
  'tasks.sandbox': (zh: '沙箱权限', en: 'Sandbox'),
  'tasks.sandbox.read-only': (zh: '只读（默认）', en: 'Read only (default)'),
  'tasks.sandbox.workspace-write': (
    zh: '允许写入工作目录',
    en: 'Allow workspace writes',
  ),
  'tasks.prepare': (zh: '准备不可变草稿', en: 'Prepare immutable draft'),
  'tasks.preparing': (zh: '正在准备…', en: 'Preparing…'),
  'tasks.start': (zh: '明确启动任务', en: 'Start prepared task'),
  'tasks.cancel': (zh: '取消任务', en: 'Cancel task'),
  'tasks.clear': (zh: '清理记录', en: 'Clear record'),
  'tasks.empty': (
    zh: '尚无独立任务。编辑和切换页面不会自动启动。',
    en: 'No independent tasks. Editing or changing pages never starts a task.',
  ),
  'tasks.filter': (zh: '任务筛选', en: 'Task filter'),
  'tasks.filter.all': (zh: '全部', en: 'All'),
  'tasks.filter.active': (zh: '活动任务', en: 'Active'),
  'tasks.filter.terminal': (zh: '已结束', en: 'Finished'),
  'tasks.restored': (
    zh: '历史元数据；提示词需重填，不恢复运行所有权。',
    en: 'Restored metadata. Reenter the prompt; no process ownership is restored.',
  ),
  'tasks.cleanupPending': (
    zh: '子进程清理尚未确认；来源仍保持占用。',
    en: 'Process cleanup is unconfirmed; the source remains busy.',
  ),
  'tasks.output': (zh: '会话内输出', en: 'Session output'),
  'tasks.outputTruncated': (zh: '输出已截断。', en: 'Output was truncated.'),
  'tasks.noOutput': (zh: '暂无输出。', en: 'No output yet.'),
  'tasks.approval': (zh: '查看待审批请求', en: 'Review pending approval'),
  'tasks.approvalTitle': (zh: '任务审批', en: 'Task approval'),
  'tasks.accept': (zh: '仅批准本次', en: 'Accept once'),
  'tasks.decline': (zh: '拒绝', en: 'Decline'),
  'tasks.cancelApproval': (zh: '取消请求', en: 'Cancel request'),
  'tasks.input': (zh: '回答待处理问题', en: 'Answer pending questions'),
  'tasks.inputTitle': (zh: '任务需要输入', en: 'Task needs input'),
  'tasks.sendAnswers': (zh: '提交本次回答', en: 'Submit answers'),
  'tasks.answer': (zh: '回答', en: 'Answer'),
  'tasks.otherAnswer': (zh: '其他回答', en: 'Other answer'),
  'tasks.usage': (
    zh: '线程累计 token（输入 / 输出 / 推理）：{input} / {output} / {reasoning}',
    en: 'Reported thread token totals (input / output / reasoning): {input} / {output} / {reasoning}',
  ),
  'tasks.identityObservation': (
    zh: '观察到的账号字段（不构成强身份验证）：{value}',
    en: 'Observed account fields (not strong identity verification): {value}',
  ),
  'tasks.state.prepared': (zh: '草稿已准备', en: 'Draft prepared'),
  'tasks.state.starting': (zh: '正在启动', en: 'Starting'),
  'tasks.state.running': (zh: '运行中', en: 'Running'),
  'tasks.state.awaiting_approval': (zh: '等待审批', en: 'Awaiting approval'),
  'tasks.state.awaiting_input': (zh: '等待输入', en: 'Awaiting input'),
  'tasks.state.cancelling': (zh: '正在取消', en: 'Cancelling'),
  'tasks.state.completed': (zh: '已完成', en: 'Completed'),
  'tasks.state.cancelled': (zh: '已取消', en: 'Cancelled'),
  'tasks.state.failed': (zh: '失败', en: 'Failed'),
  'tasks.state.interrupted': (zh: '已中断', en: 'Interrupted'),
  'tasks.error.invalid_request': (
    zh: '请求或任务归属无效。',
    en: 'Invalid request or task ownership.',
  ),
  'tasks.error.unsupported': (
    zh: '当前环境不支持任务适配器。',
    en: 'The task adapter is unavailable in this environment.',
  ),
  'tasks.error.source_invalid': (
    zh: '请选择有效的专用来源。',
    en: 'Select a valid managed source.',
  ),
  'tasks.error.source_busy': (
    zh: '此来源正被其他操作占用。',
    en: 'This source is busy with another operation.',
  ),
  'tasks.error.workspace_busy': (
    zh: '工作目录与活动写入任务重叠。',
    en: 'The workspace overlaps an active writing task.',
  ),
  'tasks.error.auth_required': (
    zh: '请重新登录所选专用来源。',
    en: 'Sign in to the selected managed source again.',
  ),
  'tasks.error.identity_changed': (
    zh: '来源身份发生变化，请重新核对。',
    en: 'The observed source identity changed. Verify it again.',
  ),
  'tasks.error.isolation_failed': (
    zh: '无法确认独立进程隔离。',
    en: 'Independent process isolation could not be confirmed.',
  ),
  'tasks.error.policy_mismatch': (
    zh: '官方有效策略与请求不一致。',
    en: 'The effective official policy differs from the request.',
  ),
  'tasks.error.cli_changed': (
    zh: '固定 CLI 已变化，请重新核验。',
    en: 'The registered CLI changed. Verify it again.',
  ),
  'tasks.error.startup_failed': (
    zh: '任务子进程启动失败。',
    en: 'The task process failed to start.',
  ),
  'tasks.error.protocol_error': (
    zh: '任务协议响应无效。',
    en: 'The task protocol response was invalid.',
  ),
  'tasks.error.unsupported_request': (
    zh: '任务请求了当前不支持的交互。',
    en: 'The task requested an unsupported interaction.',
  ),
  'tasks.error.cancelled': (zh: '操作已取消。', en: 'The operation was cancelled.'),
  'tasks.error.timeout': (zh: '任务操作超时。', en: 'The task operation timed out.'),
  'tasks.error.disconnected': (
    zh: '任务连接已断开，完成状态未知。',
    en: 'The task connection closed; completion is unknown.',
  ),
  'tasks.error.shutdown': (
    zh: '任务管理器正在退出。',
    en: 'The task manager is shutting down.',
  ),
  'tasks.error.cleanup_failed': (
    zh: '任务清理未确认，可重试退出。',
    en: 'Task cleanup is unconfirmed. Retry shutdown.',
  ),
  'tasks.error.interrupted_previous_process': (
    zh: '上次进程已结束；不会自动恢复。',
    en: 'The previous process ended. This task will not resume automatically.',
  ),
  'tasks.error.unknown': (
    zh: '任务状态暂不可用；未确认完成。',
    en: 'Task status is unavailable; completion is unconfirmed.',
  ),
  'tasks.error.store_failed': (
    zh: '任务元数据保存或读取失败；原文件保留。',
    en: 'Task metadata could not be saved or read; the original file is retained.',
  ),
};
