import 'copy_types.dart';

const benchmarkMessages = <String, AppMessage>{
  'benchmark.mode': (zh: '数据模式', en: 'Data mode'),
  'benchmark.mode.offline_replay': (zh: '离线回放', en: 'Offline replay'),
  'benchmark.mode.live': (zh: '真实 API · 可选', en: 'Live API · Optional'),
  'benchmark.liveSubtitle': (
    zh: '用户接口 · 客户端观测',
    en: 'User endpoint · Client observations',
  ),
  'benchmark.liveStart': (zh: '发送一次真实请求', en: 'Send one live request'),
  'benchmark.livePolicy': (
    zh: '仅点击启动才发送，可能产生接口费用。密钥、提示词和地址仅保留在本次内存；无自动重试。',
    en: 'Sends only on Start; provider charges may apply. Key, prompt and endpoint stay in memory. No automatic retries.',
  ),
  'benchmark.live.base-url': (
    zh: 'API 前缀地址（如 https://接口/v1）',
    en: 'API prefix URL (for example https://provider/v1)',
  ),
  'benchmark.live.model': (zh: '模型 ID', en: 'Model ID'),
  'benchmark.live.prompt': (zh: '测试提示词', en: 'Test prompt'),
  'benchmark.live.key': (zh: 'API 密钥（仅本次内存）', en: 'API key (memory only)'),
  'benchmark.live.maxTokens': (zh: '最大输出 token', en: 'Maximum output tokens'),
  'benchmark.live.route': (zh: '连接路由', en: 'Connection route'),
  'benchmark.route.system': (
    zh: '系统代理',
    en: 'System proxy',
  ),
  'benchmark.route.direct': (zh: '直连', en: 'Direct'),
  'benchmark.error.liveStart': (
    zh: 'API 测试未能开始；没有可展示的新结果。',
    en: 'The API benchmark could not start; there is no new result.',
  ),
  'benchmark.title': (zh: '独立 API 测速', en: 'Independent API benchmark'),
  'benchmark.subtitle': (
    zh: '离线回放 · 合成数据 · 客户端观测',
    en: 'Offline replay · Synthetic data · Client observations',
  ),
  'benchmark.metric.ttftMs': (
    zh: 'TTFT · 首段响应',
    en: 'TTFT · First response content',
  ),
  'benchmark.metric.ttfoMs': (
    zh: 'TTFO · 首段可见输出',
    en: 'TTFO · First visible output',
  ),
  'benchmark.metric.streamTokensPerSecond': (
    zh: '流式输出速率',
    en: 'Streaming output rate',
  ),
  'benchmark.metric.e2eTokensPerSecond': (zh: '端到端速率', en: 'End-to-end rate'),
  'benchmark.metric.fullResponseTokensPerSecond': (
    zh: '完整响应速率',
    en: 'Full-response rate',
  ),
  'benchmark.formula.ttftMs': (
    zh: '首段内容时间 − 请求开始',
    en: 'First content time − Request start',
  ),
  'benchmark.formula.ttfoMs': (
    zh: '首段可见文本时间 − 请求开始',
    en: 'First visible text time − Request start',
  ),
  'benchmark.formula.streamTokensPerSecond': (
    zh: '(输出 token − 首块 token) / (末段内容 − 首段内容)',
    en: '(Output tokens − First-chunk tokens) / (Last content − First content)',
  ),
  'benchmark.formula.e2eTokensPerSecond': (
    zh: '最终输出 token / (HTTP EOF − 请求开始)',
    en: 'Final output tokens / (HTTP EOF − Request start)',
  ),
  'benchmark.formula.fullResponseTokensPerSecond': (
    zh: '(输出 token − 首块 token) / (HTTP EOF − 首段内容)',
    en: '(Output tokens − First-chunk tokens) / (HTTP EOF − First content)',
  ),
  'benchmark.quality.measured': (zh: '实测延迟', en: 'Measured latency'),
  'benchmark.quality.reported': (zh: '报告计数', en: 'Reported count'),
  'benchmark.quality.estimated': (zh: '估计', en: 'Estimated'),
  'benchmark.quality.unavailable': (zh: '不可用', en: 'Unavailable'),
  'benchmark.state.starting': (zh: '正在保存开始意图', en: 'Saving start intent'),
  'benchmark.state.queued': (zh: '排队', en: 'Queued'),
  'benchmark.state.connecting': (zh: '连接中', en: 'Connecting'),
  'benchmark.state.streaming': (zh: '回放中', en: 'Replaying'),
  'benchmark.state.liveStreaming': (zh: '接收流式输出', en: 'Receiving stream'),
  'benchmark.state.completed': (zh: '已完成', en: 'Completed'),
  'benchmark.state.cancelled': (zh: '已取消', en: 'Cancelled'),
  'benchmark.state.interrupted': (zh: '已中断', en: 'Interrupted'),
  'benchmark.state.failed': (zh: '失败', en: 'Failed'),
  'benchmark.state.idle': (zh: '等待开始', en: 'Ready'),
  'benchmark.noFacts': (zh: '尚无观测事实', en: 'No observations yet'),
  'benchmark.countSource': (zh: '计数来源：{value}', en: 'Count source: {value}'),
  'benchmark.quality': (zh: '质量：{value}', en: 'Quality: {value}'),
  'benchmark.reasons': (zh: '原因：{value}', en: 'Reasons: {value}'),
  'benchmark.method': (
    zh: 'Rust 计算；延迟使用客户端单调时钟。推理计入 output 的子集；协议终态与 HTTP EOF 分开。',
    en: 'Calculated in Rust using the client monotonic clock. Reasoning is a subset of output; protocol completion and HTTP EOF are separate.',
  ),
  'benchmark.restoredSuffix': (
    zh: ' · 已恢复的最后观察',
    en: ' · Restored last observation',
  ),
  'benchmark.cleanupSuffix': (
    zh: ' · 自有任务清理中',
    en: ' · Cleaning up owned replay',
  ),
  'benchmark.elapsed': (zh: '耗时：{value}', en: 'Elapsed: {value}'),
  'benchmark.sampleQuality': (
    zh: '样本质量：{value}',
    en: 'Sample quality: {value}',
  ),
  'benchmark.noResult': (zh: '尚无测试结果', en: 'No results yet'),
  'benchmark.valid': (zh: '样本有效', en: 'Valid sample'),
  'benchmark.invalid': (
    zh: '不可作为成功测速样本',
    en: 'Not a successful benchmark sample',
  ),
  'benchmark.resultSource': (zh: '结果来源：{value}', en: 'Result source: {value}'),
  'benchmark.inspect': (
    zh: '查看{name}公式与原因',
    en: 'Inspect {name}: formula and reasons',
  ),
  'benchmark.offlineOnly': (
    zh: '合成回放不访问真实接口。Ctrl+Enter 开始 · Esc 取消。',
    en: 'Synthetic replay never contacts a provider. Ctrl+Enter to start · Esc to cancel.',
  ),
  'benchmark.restorePolicy': (
    zh: '记录是最后保存的观察，恢复后不会自动补发请求。',
    en: 'Records contain the last saved observation. Restoring never resends requests.',
  ),
  'benchmark.protocol': (zh: '协议', en: 'Protocol'),
  'benchmark.scenario': (zh: '合成场景', en: 'Synthetic scenario'),
  'benchmark.start': (zh: '开始回放', en: 'Start replay'),
  'benchmark.clear': (zh: '清除结果', en: 'Clear result'),
  'benchmark.timeline': (
    zh: '请求事件时间点 · 沿客户端实测耗时定位',
    en: 'Request timeline · Client-observed elapsed time',
  ),
  'benchmark.timing.start': (zh: '请求开始', en: 'Request start'),
  'benchmark.timing.firstContent': (zh: '首段内容', en: 'First content'),
  'benchmark.timing.lastContent': (zh: '末段内容', en: 'Last content'),
  'benchmark.timing.firstVisible': (zh: '首段可见文本', en: 'First visible text'),
  'benchmark.timing.lastVisible': (zh: '末段可见文本', en: 'Last visible text'),
  'benchmark.timing.usage': (zh: 'usage', en: 'usage'),
  'benchmark.timing.done': (zh: '协议终态', en: 'Protocol completion'),
  'benchmark.timing.httpEnd': (zh: 'HTTP EOF', en: 'HTTP EOF'),
  'benchmark.scenario.text_complete': (zh: '完整文本', en: 'Complete text'),
  'benchmark.scenario.reasoning_complete': (
    zh: '含推理的完整响应',
    en: 'Complete response with reasoning',
  ),
  'benchmark.scenario.missing_usage': (zh: '缺少用量', en: 'Missing usage'),
  'benchmark.scenario.truncated': (zh: '中途截断', en: 'Truncated stream'),
  'benchmark.scenario.slow': (zh: '慢速回放', en: 'Slow replay'),
  'benchmark.scenario.failed': (zh: '失败响应', en: 'Failed response'),
  'benchmark.scenario.incomplete': (zh: '未完成响应', en: 'Incomplete response'),
  'benchmark.error.history': (
    zh: '历史记录读取失败；下次保存时备份原文件。',
    en: 'History could not be read; the original file will be backed up on the next save.',
  ),
  'benchmark.error.catalog': (
    zh: '离线场景目录不可用。',
    en: 'The offline scenario catalog is unavailable.',
  ),
  'benchmark.error.save': (
    zh: '最后观察未保存；请检查文件夹写入权限。',
    en: 'The last observation was not saved; check folder write access.',
  ),
  'benchmark.error.start': (
    zh: '离线测试未能开始；没有可展示的新结果。',
    en: 'The offline replay could not start; there is no new result.',
  ),
  'benchmark.error.observe': (
    zh: '状态观察失败；保留最后已观察事实。',
    en: 'Status could not be observed; the last observation is retained.',
  ),
  'benchmark.error.stop': (
    zh: '停止请求未确认；保留最后观察并继续检查清理。',
    en: 'Stopping is unconfirmed; the last observation is retained while cleanup is checked.',
  ),
  'benchmark.error.clear': (
    zh: '结果尚不能清除；等待自有任务完成清理。',
    en: 'The result cannot be cleared until the owned replay has finished cleanup.',
  ),
  'benchmark.error.final': (
    zh: '退出后的最终状态未确认；保留最后观察。',
    en: 'Final status after exit is unconfirmed; the last observation is retained.',
  ),
  'benchmark.error.deadline': (
    zh: '退出清理未在原生时限内确认完成。',
    en: 'Exit cleanup was not confirmed within the native deadline.',
  ),
  'benchmark.error.exit': (
    zh: '退出清理未确认完成。',
    en: 'Exit cleanup is unconfirmed.',
  ),
};
