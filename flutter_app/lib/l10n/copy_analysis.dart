import '../services/session_activity_timeline.dart';
import '../services/session_measurement_quality.dart';
import 'app_copy.dart';
import 'copy_types.dart';

const analysisMessages = <String, AppMessage>{
  'analysis.diagnostic.restoreSelection': (
    zh: '无法恢复上次选择，请重新选择会话。',
    en: 'Could not restore the last selection. Select a session again.',
  ),
  'analysis.diagnostic.saveSelection': (
    zh: '会话选择保存失败；本次采集继续。',
    en: 'Could not save the session selection; current collection continues.',
  ),
  'analysis.diagnostic.identityChanged': (
    zh: '所选路径的会话标识已变化，请重新选择',
    en: 'The session identity at the selected path changed. Select it again.',
  ),
  'analysis.diagnostic.restoreRhythm': (
    zh: '活动缓存读取失败，可重读本地日志重建',
    en: 'Activity cache could not be read. Reread local logs to rebuild it.',
  ),
  'analysis.diagnostic.saveRhythm': (
    zh: '活动缓存保存失败',
    en: 'Activity cache could not be saved',
  ),
  'analysis.diagnostic.sourceIdentity': (
    zh: '来源路径和会话身份不能为空',
    en: 'Source path and session identity are required',
  ),
  'analysis.diagnostic.sourceLimit': (
    zh: '最多选择8个会话来源',
    en: 'Select up to 8 session sources',
  ),
  'analysis.diagnostic.catchingUp': (
    zh: '日志仍在追赶，请重读',
    en: 'The log is still catching up. Reread it.',
  ),
  'analysis.diagnostic.sourceMismatch': (
    zh: '会话来源身份不匹配，请重新选择',
    en: 'Session source identity mismatch. Select the source again.',
  ),
  'analysis.diagnostic.updating': (
    zh: '日志更新中，请重读',
    en: 'The log is updating. Reread it.',
  ),
  'analysis.diagnostic.readHistory': (
    zh: '会话历史读取失败',
    en: 'Session history could not be read',
  ),

  'analysis.quality.verified': (zh: '已核验', en: 'Verified'),
  'analysis.quality.reported_only': (
    zh: '日志报告值 · 未充分核验',
    en: 'Log-reported · Not fully verified',
  ),
  'analysis.quality.conflict': (zh: '证据冲突', en: 'Conflicting evidence'),
  'analysis.quality.unsupported': (
    zh: '暂不支持核验',
    en: 'Verification unsupported',
  ),
  'analysis.quality.incomplete': (
    zh: '核验信息不完整',
    en: 'Incomplete verification evidence',
  ),
  'analysis.quality.unknownReason': (
    zh: '核验信息不完整，暂无法核验',
    en: 'Verification evidence is incomplete; verification is unavailable',
  ),
  'analysis.quality.source': (
    zh: '所选 Codex 会话 · 本地只读日志',
    en: 'Selected Codex session · Local read-only log',
  ),
  'analysis.quality.missing_usage': (zh: '缺少回合用量', en: 'Missing turn usage'),
  'analysis.quality.invalid_usage': (
    zh: '回合用量格式无效',
    en: 'Invalid turn usage format',
  ),
  'analysis.quality.missing_duration': (
    zh: '缺少完整回合耗时',
    en: 'Missing complete turn duration',
  ),
  'analysis.quality.invalid_duration': (
    zh: '完整回合耗时无效',
    en: 'Invalid complete turn duration',
  ),
  'analysis.quality.missing_identity': (
    zh: '缺少可核对的会话或回合标识',
    en: 'Missing verifiable session or turn identity',
  ),
  'analysis.quality.missing_request_evidence': (
    zh: '缺少逐请求用量证据',
    en: 'Missing usage evidence for individual requests',
  ),
  'analysis.quality.usage_mismatch': (
    zh: '请求用量与回合用量不一致',
    en: 'Request usage does not match turn usage',
  ),
  'analysis.quality.invalid_bounds': (
    zh: '计时范围无法核对',
    en: 'Timing bounds cannot be verified',
  ),
  'analysis.quality.conflicting_terminal': (
    zh: '回合结束记录存在冲突',
    en: 'Conflicting terminal turn records',
  ),
  'analysis.quality.conflicting_usage': (
    zh: '重复用量记录存在冲突',
    en: 'Conflicting duplicate usage records',
  ),
  'analysis.quality.conflicting_item': (
    zh: '重复响应内容存在冲突',
    en: 'Conflicting duplicate response records',
  ),
  'analysis.quality.unsupported_token_schema': (
    zh: '当前日志用量格式暂不支持核验',
    en: 'Verification does not support this log usage format',
  ),
  'analysis.quality.no_completed_turn': (
    zh: '尚无已结束回合',
    en: 'No terminal turn yet',
  ),
  'analysis.quality.incomplete_history': (
    zh: '会话历史尚未完整读取',
    en: 'Session history has not been fully read',
  ),
  'analysis.state.unselected': (zh: '未选择会话', en: 'No session selected'),
  'analysis.state.failed': (
    zh: '状态未知 · 读取失败',
    en: 'Status unknown · Read failed',
  ),
  'analysis.state.catchingUp': (
    zh: '状态未知 · 正在读取历史',
    en: 'Status unknown · Reading history',
  ),
  'analysis.state.running': (zh: '回合进行中', en: 'Turn running'),
  'analysis.state.completed': (zh: '回合已结束', en: 'Turn ended'),
  'analysis.state.cancelled': (zh: '已取消', en: 'Cancelled'),
  'analysis.state.unknown': (zh: '状态未知', en: 'Status unknown'),
  'analysis.activityTimeUnknown': (zh: '活动时间未知', en: 'Activity time unknown'),
  'analysis.timeline.available': (
    zh: '日志项活动可重叠；时间轴为秒级边界的近似窗口。',
    en: 'Logged item activity may overlap; the timeline is an approximate window with second-level boundaries.',
  ),
  'analysis.timeline.unavailable': (
    zh: '时间线不可用：旧版内核、缺少数据或格式无法核验；上方耗时汇总仍可独立使用。',
    en: 'Timeline unavailable: older engine, missing data or unverifiable format. The timing summary above remains independently usable.',
  ),
  'analysis.timeline.missing_start': (zh: '缺少开始时间', en: 'Missing start time'),
  'analysis.timeline.missing_end': (zh: '缺少结束时间', en: 'Missing end time'),
  'analysis.timeline.reversed': (zh: '起止倒序', en: 'End precedes start'),
  'analysis.timeline.zero_duration': (
    zh: '零时长（不绘制条形）',
    en: 'Zero duration (bar not drawn)',
  ),
  'analysis.timeline.outside_bounds': (zh: '超出回合窗口', en: 'Outside turn window'),
  'analysis.timeline.missing_turn_bounds': (
    zh: '缺少回合边界',
    en: 'Missing turn boundaries',
  ),
  'analysis.timeline.overflow': (
    zh: '时间超出可核验范围',
    en: 'Time exceeds verifiable range',
  ),
  'analysis.timeline.unknownReason': (
    zh: '其他无法核验的时间信息',
    en: 'Other unverifiable timing information',
  ),
  'analysis.value': (zh: '数值', en: 'Value'),
  'analysis.secondaryValue': (zh: '补充数值', en: 'Secondary value'),
  'analysis.unknown': (zh: '未知', en: 'Unknown'),
  'analysis.sessionInformation': (zh: '会话信息', en: 'Session information'),
  'analysis.sourceProject': (zh: '来源项目', en: 'Source project'),
  'analysis.unknownNoSuccessfulRead': (
    zh: '未知（尚未成功读取）',
    en: 'Unknown (no successful read)',
  ),
  'analysis.session': (zh: '会话', en: 'Session'),
  'analysis.awaitingVerification': (zh: '等待核验', en: 'Awaiting verification'),
  'analysis.sessionID': (zh: '会话 ID', en: 'Session ID'),
  'analysis.log': (zh: '日志', en: 'Log'),
  'analysis.notSelected': (zh: '未选择', en: 'Not selected'),
  'analysis.currentTurn': (zh: '当前回合', en: 'Current turn'),
  'analysis.lastTurnIdentity': (zh: '上轮身份', en: 'Last-turn identity'),
  'analysis.logWriteTime': (zh: '日志写入时间', en: 'Log write time'),
  'analysis.lastSuccessfulRead': (zh: '最近成功读取', en: 'Last successful read'),
  'analysis.noSuccessfulRead': (zh: '尚未成功读取', en: 'No successful read'),
  'analysis.measurementSource': (zh: '统计来源', en: 'Measurement source'),
  'analysis.unavailable': (zh: '不可用', en: 'Unavailable'),
  'analysis.logReportedValueNotFullyVerified': (
    zh: '日志报告值 · 未充分核验：{p0}{p1}',
    en: 'Log-reported value · Not fully verified: {p0}{p1}',
  ),
  'analysis.listRefreshFailed': (zh: '列表刷新失败', en: 'List refresh failed'),
  'analysis.selectionSaveRestore': (
    zh: '选择保存/恢复',
    en: 'Selection save/restore',
  ),
  'analysis.readFailed': (zh: '读取失败', en: 'Read failed'),
  'analysis.sessionTurns': (
    zh: '会话 {p0} · {p1} · {p2} · {p3}：{p4} 回合',
    en: 'Session {p0} · {p1} · {p2} · {p3}: {p4} turns',
  ),
  'analysis.matched': (zh: '一致', en: 'Matched'),
  'analysis.mismatched': (zh: '不一致', en: 'Mismatched'),
  'analysis.notVerifiable': (zh: '不可核对', en: 'Not verifiable'),
  'analysis.recordedResponsesTotalOutputTokensTurnTotal': (
    zh: '已记录响应：{p0} 次 · 输出合计：{p1} tokens · 与回合总数：{p2}',
    en: 'Recorded responses: {p0} · Total output: {p1} tokens · Turn total match: {p2}',
  ),
  'analysis.unclassifiedTime': (
    zh: '未归类时间：{p0}',
    en: 'Unclassified time: {p0}',
  ),
  'analysis.outputReasoningTokens': (
    zh: '{p0} · 输出 {p1} · 推理 {p2} tokens',
    en: '{p0} · Output {p1} · Reasoning {p2} tokens',
  ),
  'analysis.timingDataIncompleteOrUnverifiable': (
    zh: '计时数据不完整或不可核验',
    en: 'Timing data incomplete or unverifiable',
  ),
  'analysis.positioned': (zh: '可定位', en: 'Positioned'),
  'analysis.offsetMsNRecordedStartRecordedEndUnix': (
    zh: '{p0} · 偏移 {p1} → {p2} ms · {p3}\n记录开始：{p4} · 记录结束：{p5} · Unix epoch 毫秒',
    en: '{p0} · Offset {p1} → {p2} ms · {p3}\nRecorded start: {p4} · Recorded end: {p5} · Unix epoch milliseconds',
  ),
  'analysis.itemsOmitted': (zh: '省略 {p0} 项', en: '{p0} items omitted'),
  'analysis.sessionTurnStatistics': (
    zh: '会话回合统计',
    en: 'Session turn statistics',
  ),
  'analysis.recentSessions': (zh: '最近会话', en: 'Recent sessions'),
  'analysis.sessionInformationAndDiagnostics': (
    zh: '会话信息与诊断',
    en: 'Session information and diagnostics',
  ),
  'analysis.listingSessions': (zh: '正在列出会话', en: 'Listing sessions'),
  'analysis.refreshLocalSessionList': (
    zh: '刷新本机会话列表',
    en: 'Refresh local session list',
  ),
  'analysis.stopSessionCollection': (
    zh: '停止会话采集',
    en: 'Stop session collection',
  ),
  'analysis.theCollectedSessionIsOutsideTheRecent': (
    zh: '当前采集会话不在最近列表中；仍继续采集，可选择其他会话。',
    en: 'The collected session is outside the recent list. Collection continues; another session can be selected.',
  ),
  'analysis.sessionIdentityAwaitingVerification': (
    zh: '会话身份等待核验',
    en: 'Session identity awaiting verification',
  ),
  'analysis.unknownProject': (zh: '未知项目', en: 'Unknown project'),
  'analysis.sessionStatus': (zh: '会话状态：{p0}', en: 'Session status: {p0}'),
  'analysis.readingHistoryNoRecentCompletedTurnAvailable': (
    zh: '正在读取历史 · 尚无可用最近完成回合',
    en: 'Reading history · No recent completed turn available',
  ),
  'analysis.recentlyCompletedNoSample': (
    zh: '最近完成 · 暂无样本',
    en: 'Recently completed · No sample',
  ),
  'analysis.recentlyCompletedIncludesToolsAndWaiting': (
    zh: '最近完成 · 含工具与等待',
    en: 'Recently completed · Includes tools and waiting',
  ),
  'analysis.sampleQuality': (zh: '样本质量：{p0}', en: 'Sample quality: {p0}'),
  'analysis.listRefreshFailedSeeInformationForDiagnostics': (
    zh: '列表刷新失败 · 信息中查看诊断',
    en: 'List refresh failed · See information for diagnostics',
  ),
  'analysis.sessionReadFailedSeeInformationForDiagnostics': (
    zh: '会话读取失败 · 信息中查看诊断',
    en: 'Session read failed · See information for diagnostics',
  ),
  'analysis.selectASessionTheCurrentConversationIs': (
    zh: '请选择会话；不会自动猜测当前对话。',
    en: 'Select a session; the current conversation is never guessed automatically.',
  ),
  'analysis.turnAverage': (zh: '回合均值', en: 'Turn average'),
  'analysis.outputIncludesReasoning': (
    zh: '输出 · 含推理',
    en: 'Output · Includes reasoning',
  ),
  'analysis.firstModelTokenWait': (
    zh: '首模型 token 等待',
    en: 'First model token wait',
  ),
  'analysis.mayIncludeReasoning': (zh: '可能含推理', en: 'May include reasoning'),
  'analysis.completeTurn': (zh: '完整回合', en: 'Complete turn'),
  'analysis.firstModelTokenUnavailableExceedsCompleteTurn': (
    zh: '首模型 token 不可用：超过完整回合耗时',
    en: 'First model token unavailable: exceeds complete turn duration',
  ),
  'analysis.currentSession': (zh: '当前会话', en: 'Current session'),
  'analysis.independentAPI': (zh: '独立 API', en: 'Independent API'),
  'analysis.independentAPIBenchmark': (
    zh: '独立 API 测速',
    en: 'Independent API benchmark',
  ),
  'analysis.independentSourceClientObservations': (
    zh: '独立来源 · 客户端观测',
    en: 'Independent source · Client observations',
  ),
  'analysis.notYetImplemented': (zh: '待实现', en: 'Not yet implemented'),
  'analysis.m2OfflineEngineVerifiedLiveAPIAnd': (
    zh: 'M2 离线内核已验收；真实接口与测速界面待实现',
    en: 'M2 offline engine verified; live API and benchmark interface not yet implemented',
  ),
  'analysis.thisViewUsesSeparateTestRequestsAnd': (
    zh: '这里将使用单独的测试请求与结果，不使用当前会话日志作为 API 结果。',
    en: 'This view uses separate test requests and results. Current-session logs do not supply API results.',
  ),
  'analysis.noSamples': (zh: '暂无样本', en: 'No samples'),
  'analysis.recentTurns': (zh: '最近回合', en: 'Recent turns'),
  'analysis.metric': (zh: '指标', en: 'Metric'),
  'analysis.duration': (zh: '耗时', en: 'Duration'),
  'analysis.terminalStatus': (zh: '结束状态', en: 'Terminal status'),
  'analysis.chart': (zh: '图形', en: 'Chart'),
  'analysis.line': (zh: '折线', en: 'Line'),
  'analysis.bars': (zh: '柱形', en: 'Bars'),
  'analysis.turnRange': (zh: '回合范围', en: 'Turn range'),
  'analysis.turns': (zh: '8 条', en: '8 turns'),
  'analysis.turns2': (zh: '16 条', en: '16 turns'),
  'analysis.turns3': (zh: '64 条', en: '64 turns'),
  'analysis.loggedTerminalStatusTurns': (
    zh: '日志终结状态 · {p0} 条',
    en: 'Logged terminal status · {p0} turns',
  ),
  'analysis.logReportedDurationCancelledGapsAreUnknown': (
    zh: '日志报告耗时 · × 取消 · 缺口为未知',
    en: 'Log-reported duration · × Cancelled · Gaps are unknown',
  ),
  'analysis.completed': (zh: '完成', en: 'Completed'),
  'analysis.cancelled': (zh: '取消', en: 'Cancelled'),
  'analysis.turn': (zh: '回合 {p0} · {p1}', en: 'Turn {p0} · {p1}'),
  'analysis.turns4': (zh: '回合', en: 'turns'),
  'analysis.terminalStatusSelectedRange': (
    zh: '结束状态 · 所选范围',
    en: 'Terminal status · Selected range',
  ),
  'analysis.turnOrder': (zh: '回合顺序', en: 'Turn order'),
  'analysis.configurationComparison': (
    zh: '配置对比',
    en: 'Configuration comparison',
  ),
  'analysis.outputTokens': (zh: '输出 token', en: 'Output tokens'),
  'analysis.completeTurnDuration': (zh: '完整回合耗时', en: 'Complete turn duration'),
  'analysis.turnCount': (zh: '回合数', en: 'Turn count'),
  'analysis.verifiedGroupsSessionModelReasoningEffortService': (
    zh: '已核验分组 · 会话 / 模型 / 推理强度 / 服务层级',
    en: 'Verified groups · Session / Model / Reasoning effort / Service tier',
  ),
  'analysis.turnsGroupAggregate': (
    zh: '{p0} · {p1} 回合 · 分组汇总',
    en: '{p0} · {p1} turns · Group aggregate',
  ),
  'analysis.coverageUnverifiable': (zh: '覆盖不可核验', en: 'Coverage unverifiable'),
  'analysis.lastTurnActivity': (zh: '上轮活动', en: 'Last-turn activity'),
  'analysis.view': (zh: '视图', en: 'View'),
  'analysis.intervals': (zh: '区间', en: 'Intervals'),
  'analysis.categoryDuration': (zh: '分类时长', en: 'Category duration'),
  'analysis.coverage': (zh: '覆盖', en: 'Coverage'),
  'analysis.recentlyCompleted': (
    zh: '最近完成 · {p0}',
    en: 'Recently completed · {p0}',
  ),
  'analysis.relativeLogWindowBoundaryResolutionAboutS': (
    zh: '相对日志窗口 · 边界精度约 1 s',
    en: 'Relative log window · Boundary resolution about 1 s',
  ),
  'analysis.unionWithinEachCategoryCategoriesMayOverlap': (
    zh: '各类内部并集 · 类别可能重叠',
    en: 'Union within each category · Categories may overlap',
  ),
  'analysis.approximateLogCoverage': (
    zh: '近似日志覆盖',
    en: 'Approximate log coverage',
  ),
  'analysis.unclassifiedWaiting': (
    zh: '未归类 ≠ 等待',
    en: 'Unclassified ≠ waiting',
  ),
  'analysis.partialLog': (zh: '部分日志', en: 'Partial log'),
  'analysis.totalOutputIncludesReasoning': (
    zh: '总输出 · 含推理',
    en: 'Total output · Includes reasoning',
  ),
  'analysis.reasoning': (zh: '推理', en: 'Reasoning'),
  'analysis.nonReasoningOutputReasoning': (
    zh: '非推理输出 + 推理',
    en: 'Non-reasoning output + Reasoning',
  ),
  'analysis.lastTurnResponsesRecentResponses': (
    zh: '上轮响应 · 最近响应',
    en: 'Last-turn responses · Recent responses',
  ),
  'analysis.outputComposition': (zh: '输出构成', en: 'Composition'),
  'analysis.totalOutput': (zh: '总输出', en: 'Total output'),
  'analysis.usageMatchedUpToRecentResponses': (
    zh: '用量一致 · 最近最多 12 条',
    en: 'Usage matched · Up to 12 recent responses',
  ),
  'analysis.usageMismatchedLogReportedFacts': (
    zh: '用量不一致 · 日志报告事实',
    en: 'Usage mismatched · Log-reported facts',
  ),
  'analysis.notVerifiableLogReportedFacts': (
    zh: '不可核对 · 日志报告事实',
    en: 'Not verifiable · Log-reported facts',
  ),
  'analysis.response': (zh: '响应 {p0}', en: 'Response {p0}'),
  'analysis.responseOrder': (zh: '响应顺序', en: 'Response order'),
  'analysis.nonReasoningOutput': (zh: '非推理输出', en: 'Non-reasoning output'),
  'analysis.activityTimelineLastTurn': (
    zh: '活动时间线 · 上轮',
    en: 'Activity timeline · Last turn',
  ),
  'analysis.responseUsageDoesNotMatchTheTurn': (
    zh: '响应用量与回合总数不一致',
    en: 'Response usage does not match the turn total',
  ),
  'analysis.overlapUnclassifiedDoesNotIdentifyWaiting': (
    zh: '重叠 {p0} · 未归类 {p1}（非等待判定）',
    en: 'Overlap {p0} · Unclassified {p1} (does not identify waiting)',
  ),
  'analysis.timingAndDefinitions': (zh: '耗时与口径', en: 'Timing and definitions'),
  'analysis.readOnlyTimingAnalysisLastTurn': (
    zh: '只读耗时分析 · 上轮',
    en: 'Read-only timing analysis · Last turn',
  ),
  'analysis.unavailableExceedsCompleteTurnDuration': (
    zh: '不可用（超过完整回合耗时）',
    en: 'Unavailable (exceeds complete turn duration)',
  ),
  'analysis.firstModelTokenWait2': (
    zh: '首模型 token 等待：{p0}',
    en: 'First model token wait: {p0}',
  ),
  'analysis.turnDurationAfterFirstModelToken': (
    zh: '首模型 token 后的回合耗时：{p0}',
    en: 'Turn duration after first model token: {p0}',
  ),
  'analysis.theFirstModelTokenMayBeReasoning': (
    zh: '首模型 token 可能属于推理，并不保证是可见正文；其后仍可包含工具、等待和其他活动，不代表纯生成时长。',
    en: 'The first model token may be reasoning rather than visible text. Later time can include tools, waiting and other activity; it is not pure generation time.',
  ),
  'analysis.messageItemsReasoningItems': (
    zh: '消息项：{p0} · 推理项：{p1}',
    en: 'Message items: {p0} · Reasoning items: {p1}',
  ),
  'analysis.toolItemsOtherItems': (
    zh: '工具项：{p0} · 其他项：{p1}',
    en: 'Tool items: {p0} · Other items: {p1}',
  ),
  'analysis.activityIntervalUnionCrossCategoryOverlap': (
    zh: '活动区间合并：{p0} · 类别间重叠：{p1}',
    en: 'Activity interval union: {p0} · Cross-category overlap: {p1}',
  ),
  'analysis.overlapsAreMergedWithinEachCategoryCategories': (
    zh: '各类别内部已合并重叠，类别之间仍可能重叠，不能直接相加。未归类时间不等于模型生成或等待时间。',
    en: 'Overlaps are merged within each category. Categories may still overlap and cannot be added directly. Unclassified time is not model generation or waiting time.',
  ),
  'analysis.collectionLimitReached': (
    zh: '，已达采集上限',
    en: ', collection limit reached',
  ),
  'analysis.missingReversedItemsZeroDurationOutsideBounds': (
    zh: '缺失/倒序 {p0} 项，零时长 {p1} 项，越界 {p2} 项，缺少身份 {p3} 条{p4}。',
    en: 'Missing/reversed {p0} items, zero duration {p1}, outside bounds {p2}, missing identity {p3}{p4}.',
  ),
  'analysis.timingComesFromLoggedItemBoundariesTurn': (
    zh: '时间来自日志项起止记录，回合边界仅秒级；尚无完整流式计时，模型生成速度不可用。',
    en: 'Timing comes from logged item boundaries; turn boundaries have second-level resolution. Full streaming timing is unavailable, so model generation speed is unavailable.',
  ),
  'analysis.recentResponseUsageUpTo': (
    zh: '最近响应用量（最多 12 条）',
    en: 'Recent response usage (up to 12)',
  ),
  'analysis.lastCompletedSelectedTurnLoggedIntervalsAbout': (
    zh: '最近完成的所选回合 · 日志区间 · 约 1 s 精度',
    en: 'Last completed selected turn · Logged intervals · About 1 s resolution',
  ),
  'analysis.fourCategoriesMayOverlapShadingMarksApproximate': (
    zh: '四类可重叠 · 阴影为近似边界',
    en: 'Four categories may overlap · Shading marks approximate boundaries',
  ),
  'analysis.partialSourceOnlyRecordedFactsAreShown': (
    zh: '来源不完整：仅展示已记录事实',
    en: 'Partial source: only recorded facts are shown',
  ),
  'analysis.turnBoundariesAreUnverifiableTextFactsAre': (
    zh: '缺少可核验回合边界，仅列出文字事实，不绘制位置。',
    en: 'Turn boundaries are unverifiable. Text facts are retained; positions are not drawn.',
  ),
  'analysis.rawActivityRecords': (zh: '原始活动记录', en: 'Raw activity records'),
  'analysis.theFourCategoriesCanOverlapAndCannot': (
    zh: '四类可重叠，不能相加为回合阶段；空白不代表等待或网络耗时。',
    en: 'The four categories can overlap and cannot be added into turn phases. Blank space does not identify waiting or network time.',
  ),
  'analysis.showingItemsChronologicallyOmittedAggregatesStillUse': (
    zh: '按时间先后展示 {p0} 项，省略 {p1} 项；汇总仍使用全部有效项。',
    en: 'Showing {p0} items chronologically; {p1} omitted. Aggregates still use all valid items.',
  ),
  'analysis.coverageCannotBeInterpretedNoBlankSpace': (
    zh: '覆盖范围无法解释：不计算空白占比，也不推断未显示区间的活动。',
    en: 'Coverage cannot be interpreted: no blank-space proportion is calculated and no activity is inferred for hidden intervals.',
  ),
  'analysis.theApproximateWindowDiffersFromActualTurn': (
    zh: '近似窗口与实际回合耗时不同；首尾阴影为边界不确定区（各至多 1.000 s）。',
    en: 'The approximate window differs from actual turn duration. Start/end shading marks boundary uncertainty (up to 1.000 s each).',
  ),
  'analysis.textRecordsScrollableBoundariesAreUnixEpoch': (
    zh: '对应文字记录（可滚动）：记录起止为 Unix epoch 毫秒；偏移相对于近似窗口；未绘制项保留原因。',
    en: 'Text records (scrollable): boundaries are Unix epoch milliseconds; offsets are relative to the approximate window; undrawn items retain their reasons.',
  ),
  'analysis.offset': (zh: '偏移 {p0} → {p1}', en: 'Offset {p0} → {p1}'),
  'analysis.notDrawn': (zh: ' · 未绘制', en: ' · Not drawn'),
  'analysis.recordedStartRecordedEndUnixEpochMilliseconds': (
    zh: '{p0} · 记录开始：{p1} · 记录结束：{p2} · Unix epoch 毫秒\n{p3} · 项时长 {p4}{p5}{p6}',
    en: '{p0} · Recorded start: {p1} · Recorded end: {p2} · Unix epoch milliseconds\n{p3} · Item duration {p4}{p5}{p6}',
  ),
  'analysis.message': (zh: '消息', en: 'Message'),
  'analysis.tool': (zh: '工具', en: 'Tool'),
  'analysis.other': (zh: '其他', en: 'Other'),
  'analysis.approximateTimelineOfFourLogCategoriesActivity': (
    zh: '四类日志项近似时间轴，活动可重叠；详见下方对应文字记录',
    en: 'Approximate timeline of four log categories; activity may overlap. See the corresponding text records below.',
  ),
  'analysis.items': (zh: '{p0} 项', en: '{p0} items'),
  'analysis.sApproximateWindow': (
    zh: '{p0} s · 近似窗口',
    en: '{p0} s · Approximate window',
  ),
  'analysis.session2': (zh: '会话 {p0}', en: 'Session {p0}'),
  'analysis.sources': (zh: '来源 {p0}/8', en: 'Sources {p0}/8'),
  'analysis.rereadLocalLogs': (zh: '重读本地日志', en: 'Reread local logs'),
  'analysis.cancelRead': (zh: '取消读取', en: 'Cancel read'),
  'analysis.timeRange': (zh: '统计范围', en: 'Time range'),
  'analysis.lastHours': (zh: '近 24 小时', en: 'Last 24 hours'),
  'analysis.lastDays': (zh: '近 7 天', en: 'Last 7 days'),
  'analysis.lastDays2': (zh: '近 30 天', en: 'Last 30 days'),
  'analysis.clearHourFilter': (zh: '清除小时筛选', en: 'Clear hour filter'),
  'analysis.restoringCache': (zh: '正在恢复缓存…', en: 'Restoring cache…'),
  'analysis.completedCancelledSamplesRecordedActivity': (
    zh: '完成 {p0} · 取消 {p1} · 样本 {p2} · 已记录活动 {p3}',
    en: 'Completed {p0} · Cancelled {p1} · Samples {p2} · Recorded activity {p3}',
  ),
  'analysis.cacheNeedsReread': (zh: '缓存待重读 · ', en: 'Cache needs reread · '),
  'analysis.truncated': (zh: ' · 已截断', en: ' · Truncated'),
  'analysis.unknownTimePartial': (
    zh: '{p0}时间未知 {p1} · 部分 {p2}{p3}',
    en: '{p0}Unknown time {p1} · Partial {p2}{p3}',
  ),
  'analysis.lastRead': (zh: '上次读取 {p0}', en: 'Last read {p0}'),
  'analysis.hourFilter': (zh: '小时筛选：{p0}', en: 'Hour filter: {p0}'),
  'analysis.readError': (zh: '读取错误：{p0}', en: 'Read error: {p0}'),
  'analysis.cacheError': (zh: '缓存错误：{p0}', en: 'Cache error: {p0}'),
  'analysis.listing': (zh: '正在列出…', en: 'Listing…'),
  'analysis.listAvailableLocalSessions': (
    zh: '列出可用本地会话',
    en: 'List available local sessions',
  ),
  'analysis.sourceList': (zh: '来源列表：{p0}', en: 'Source list: {p0}'),
  'analysis.explicitSourceSelection': (
    zh: '明确选择来源',
    en: 'Explicit source selection',
  ),
  'analysis.addSource': (zh: '加入来源', en: 'Add source'),
  'analysis.remove': (zh: '移除', en: 'Remove'),
  'analysis.addExplicitSourcesToShowSessionRhythm': (
    zh: '明确加入来源后显示会话节奏',
    en: 'Add explicit sources to show session rhythm',
  ),
  'analysis.source': (zh: '来源 {p0} · {p1}', en: 'Source {p0} · {p1}'),
  'analysis.statusCompleteTurnFirstModelToken': (
    zh: '状态 {p0} · 完整回合 {p1} · 首模型 token {p2}',
    en: 'Status {p0} · Complete turn {p1} · First model token {p2}',
  ),
  'analysis.recorded': (zh: '已记录', en: 'Recorded'),
  'analysis.partial': (zh: ' · 部分', en: ' · Partial'),
  'analysis.activityTimeResolution': (
    zh: '活动{p0}{p1} · 时间精度 {p2}',
    en: 'Activity {p0}{p1} · Time resolution {p2}',
  ),
  'analysis.openSourceAnalysis': (zh: '打开来源分析', en: 'Open source analysis'),
  'analysis.notTerminal': (zh: '未终结', en: 'Not terminal'),
  'analysis.chartArrowKeysInspectEnterSelects': (
    zh: '图表：方向键检查，回车选择',
    en: 'Chart: arrow keys inspect, Enter selects',
  ),
  'analysis.dayHourActivityHeatmap': (
    zh: '日 × 小时 · 活动热力',
    en: 'Day × hour · Activity heatmap',
  ),
  'analysis.heatmapMetric': (zh: '热力指标', en: 'Heatmap metric'),
  'analysis.completedCount': (zh: '完成数', en: 'Completed count'),
  'analysis.cancelledCount': (zh: '取消数', en: 'Cancelled count'),
  'analysis.activityTime': (zh: '活动时间', en: 'Activity time'),
  'analysis.paleNoRecordUnknownUnderlinePartial': (
    zh: '浅色：无记录 / 未知 · 底线：部分',
    en: 'Pale: no record / unknown · Underline: partial',
  ),
  'analysis.hoverArrowsInspectClickEnterFilters': (
    zh: '悬停 / 方向键查看 · 点击 / 回车筛选',
    en: 'Hover / arrows inspect · Click / Enter filters',
  ),
  'analysis.completedCancelledActivity': (
    zh: '完成 {p0} · 取消 {p1} · 活动 {p2}',
    en: 'Completed {p0} · Cancelled {p1} · Activity {p2}',
  ),
  'analysis.unselectedHourValuesHidden': (
    zh: '未选小时 · 数值已隐藏',
    en: 'Unselected hour · Values hidden',
  ),
  'analysis.sessionActivityLanes': (zh: '会话活动泳道', en: 'Session activity lanes'),
  'analysis.activityUnknownTurnCanBeInspected': (
    zh: '活动未知 · 可检查回合',
    en: 'Activity unknown · Turn can be inspected',
  ),
  'analysis.hoverArrowsInspectClickEnterSelects': (
    zh: '悬停 / 方向键查看 · 点击 / 回车选中',
    en: 'Hover / arrows inspect · Click / Enter selects',
  ),
  'analysis.completeTurnDurationBoxPlotAndSamples': (
    zh: '完整回合耗时 · 箱线与样本',
    en: 'Complete turn duration · Box plot and samples',
  ),
  'analysis.fewerThanSamplesPointsOnly': (
    zh: '样本不足 5 个 · 仅显示点',
    en: 'Fewer than 5 samples · Points only',
  ),
  'analysis.samplesMedian': (
    zh: '样本 {p0} · 中位数 {p1}{p2}',
    en: 'Samples {p0} · Median {p1}{p2}',
  ),
  'analysis.closeChartValues': (zh: '关闭图表数值', en: 'Close chart values'),
  'analysis.chartValues': (zh: '图表数值', en: 'Chart values'),
  'analysis.close': (zh: '关闭', en: 'Close'),
  'analysis.inspectValues': (zh: '查看数值', en: 'Inspect values'),
  'analysis.inspectValuesForTheFullRecord': (
    zh: '完整内容请查看数值',
    en: 'Inspect values for the full record',
  ),
  'analysis.noDrawableData': (zh: '暂无可绘制数据', en: 'No drawable data'),
  'analysis.independentQuotaRingsItemsEachWithA': (
    zh: '独立额度环图，{p0} 项，每项分母 100%，未知不计为零。',
    en: 'Independent quota rings, {p0} items, each with a 100% denominator. Unknown is not zero.',
  ),
  'analysis.categoryDotChartAggregateGroupsOnePoint': (
    zh: '分类点图，{p0} 个汇总组，每组一个点，单位 {p1}，未知保留缺口。',
    en: 'Category dot chart, {p0} aggregate groups, one point per group, unit {p1}. Unknown values remain gaps.',
  ),
  'analysis.categoryAggregates': (
    zh: '分类汇总 · {p0}',
    en: 'Category aggregates · {p0}',
  ),
  'analysis.cancelled2': (zh: '取消 ×', en: 'Cancelled ×'),
  'analysis.lineChart': (zh: '折线图', en: 'Line chart'),
  'analysis.horizontalBarChart': (zh: '横条图', en: 'Horizontal bar chart'),
  'analysis.columnChart': (zh: '柱形图', en: 'Column chart'),
  'analysis.itemsKnownValuesUnit': (
    zh: '{p0}，{p1} 项，{p2} 项有已知值，单位 {p3}。{p4}',
    en: '{p0}, {p1} items, {p2} known values, unit {p3}. {p4}',
  ),
  'analysis.noDrawableCoverageData': (
    zh: '暂无可绘制覆盖数据',
    en: 'No drawable coverage data',
  ),
  'analysis.observed': (zh: '已观测 {p0}', en: 'Observed {p0}'),
  'analysis.unclassified': (zh: '未归类 {p0}', en: 'Unclassified {p0}'),
  'analysis.windowTotal': (zh: '窗口合计 {p0}', en: 'Window total {p0}'),
  'analysis.observedUnclassified': (
    zh: '已观测 / 未归类',
    en: 'Observed / Unclassified',
  ),
  'analysis.windowTotal2': (zh: '窗口合计 {p0}。', en: 'Window total {p0}.'),
  'analysis.observed2': (zh: '已观测', en: 'Observed'),
  'analysis.unclassified2': (zh: '未归类', en: 'Unclassified'),
  'analysis.nnotDrawn': (zh: '\n未绘制：{p0}', en: '\nNot drawn: {p0}'),
  'analysis.offsetItemDurationNRecordedStartRecordedEnd': (
    zh: '{p0} · 偏移 {p1} → {p2} · 项时长 {p3}\n记录开始：{p4} · 记录结束：{p5} · Unix epoch 毫秒{p6}',
    en: '{p0} · Offset {p1} → {p2} · Item duration {p3}\nRecorded start: {p4} · Recorded end: {p5} · Unix epoch milliseconds{p6}',
  ),
  'analysis.noDrawableActivityRecords': (
    zh: '暂无可绘制活动记录',
    en: 'No drawable activity records',
  ),
  'analysis.loggedActivityRecordsPositionedWindowActivityMay': (
    zh: '{p0} 条日志活动记录，{p1} 条可定位。窗口 {p2}。活动可重叠；空白不代表等待。',
    en: '{p0} logged activity records, {p1} positioned. Window {p2}. Activity may overlap; blank space does not identify waiting.',
  ),
  'analysis.missingTurnBoundariesOnlyRecordedFactsAre': (
    zh: '缺少回合边界，仅保留已记录事实。',
    en: 'Missing turn boundaries; only recorded facts are retained.',
  ),
  'analysis.relativeWindowTimeS': (
    zh: '相对窗口时间 (s)',
    en: 'Relative window time (s)',
  ),
  'analysis.cannotPosition': (zh: '无法定位', en: 'Cannot position'),
  'analysis.loggedActivityMayOverlapBlankSpaceDoes': (
    zh: '日志活动可重叠；空白不代表等待。',
    en: 'Logged activity may overlap; blank space does not identify waiting.',
  ),
  'analysis.partialSource': (zh: '来源不完整', en: 'Partial source'),
  'analysis.sessionRhythm': (zh: '会话节奏', en: 'Session rhythm'),
  'analysis.historicalSourceAnalysisCachedTurnContext': (
    zh: '历史来源分析 · 缓存回合上下文',
    en: 'Historical source analysis · Cached turn context',
  ),
  'analysis.sessionOriginalTurn': (
    zh: '{p0} · 会话 {p1} · 原回合 {p2}',
    en: '{p0} · Session {p1} · Original turn {p2}',
  ),
  'analysis.originalSourceIdentityHasNotBeenVerified': (
    zh: '原来源尚未通过身份核验；不会替换为其他会话。',
    en: 'Original source identity has not been verified; another session will not replace it.',
  ),
  'analysis.theLatestSampleMatchesTheHistoricalTurn': (
    zh: '最近样本与历史回合一致。',
    en: 'The latest sample matches the historical turn.',
  ),
  'analysis.theHistoricalTurnChartsCannotBeReplayed': (
    zh: '历史回合五图不可回放；下方显示此来源当前可用的观测。',
    en: 'The historical turn charts cannot be replayed; current observations for this source appear below.',
  ),
  'analysis.closeHistoricalContext': (
    zh: '关闭历史上下文',
    en: 'Close historical context',
  ),
  'analysis.originalReminder': (zh: '原提醒：{p0}', en: 'Original reminder: {p0}'),
  'analysis.sessionOriginalTurn2': (
    zh: '会话 {p0} · 原回合 {p1}',
    en: 'Session {p0} · Original turn {p1}',
  ),
  'analysis.theLatestSampleMatchesTheOriginalReminder': (
    zh: '最近样本与原提醒回合一致。',
    en: 'The latest sample matches the original reminder turn.',
  ),
  'analysis.theOriginalReminderTurnSampleIsUnavailable': (
    zh: '原提醒回合的完整样本不可用或已更新；下方显示此来源当前可用的观测。',
    en: 'The original reminder turn sample is unavailable or updated; current observations for this source appear below.',
  ),
  'analysis.closeReminderContext': (
    zh: '关闭提醒上下文',
    en: 'Close reminder context',
  ),
  'analysis.accountQuotaIndependentSource': (
    zh: '账号额度 · 独立来源',
    en: 'Account quota · Independent source',
  ),
  'analysis.eachWindowIsMeasuredSeparatelyAccountsAre': (
    zh: '各窗口分别计量 · 不从会话日志推断账号',
    en: 'Each window is measured separately · Accounts are not inferred from session logs',
  ),
  'analysis.quotaSource': (zh: '额度来源', en: 'Quota source'),
  'analysis.addAnAccountOnTheAccountQuota': (
    zh: '请在账号额度页添加账号',
    en: 'Add an account on the Account quota page',
  ),
  'analysis.quotaType': (zh: '额度类型', en: 'Quota type'),
  'analysis.quotaView': (zh: '额度视图', en: 'Quota view'),
  'analysis.remaining': (zh: '剩余', en: 'Remaining'),
  'analysis.used': (zh: '已用', en: 'Used'),
  'analysis.untilReset': (zh: '距重置', en: 'Until reset'),
  'analysis.quotaSource2': (zh: '额度来源：{p0}', en: 'Quota source: {p0}'),
  'analysis.latestQuotaObservation': (
    zh: '最近额度观测：{p0}',
    en: 'Latest quota observation: {p0}',
  ),
  'analysis.quotaUnavailableQueryInTheAccountQuota': (
    zh: '额度信息暂不可用 · 可在账号额度工作区查询',
    en: 'Quota unavailable · Query in the Account quota workspace',
  ),
  'analysis.localSessionLogsIndependentOfAccountQuota': (
    zh: '本地会话日志 · 独立于账号额度与 API 测速',
    en: 'Local session logs · Independent of account quota and API benchmarks',
  ),
};

/// Typed display adapters keep collector facts and raw source identifiers intact.
/// Domain services stay locale-neutral and retain their legacy Chinese getters.
extension SessionAnalysisCopy on AppCopy {
  String sessionDiagnostic(String raw) => switch (raw) {
    '无法恢复上次选择，请重新选择会话。' => text('analysis.diagnostic.restoreSelection'),
    '会话选择保存失败；本次采集继续。' => text('analysis.diagnostic.saveSelection'),
    '所选路径的会话标识已变化，请重新选择' => text('analysis.diagnostic.identityChanged'),
    '活动缓存读取失败，可重读本地日志重建' => text('analysis.diagnostic.restoreRhythm'),
    '活动缓存保存失败' => text('analysis.diagnostic.saveRhythm'),
    '来源路径和会话身份不能为空' => text('analysis.diagnostic.sourceIdentity'),
    '最多选择8个会话来源' => text('analysis.diagnostic.sourceLimit'),
    '日志仍在追赶，请重读' => text('analysis.diagnostic.catchingUp'),
    '会话来源身份不匹配，请重新选择' => text('analysis.diagnostic.sourceMismatch'),
    '日志更新中，请重读' => text('analysis.diagnostic.updating'),
    '会话历史读取失败' => text('analysis.diagnostic.readHistory'),
    'Bad state: 所选路径的会话标识已变化，请重新选择' => text(
      'analysis.diagnostic.identityChanged',
    ),
    _ => raw,
  };

  String sessionQualityLabel(SessionMeasurementQuality quality) => text(
    'analysis.quality.${const {'verified', 'reported_only', 'conflict', 'unsupported'}.contains(quality.status) ? quality.status : 'incomplete'}',
  );

  Iterable<String> sessionQualityReasons(
    SessionMeasurementQuality quality,
    Map<String, dynamic>? data,
  ) {
    if (!isEnglish) return quality.reasons;
    final codes = <String>{};
    for (final raw in [
      data?['quality'],
      data?['last'] is Map ? data!['last']['quality'] : null,
    ]) {
      if (raw is Map && raw['reasons'] is List) {
        codes.addAll((raw['reasons'] as List).whereType<String>());
      }
    }
    if (codes.isEmpty) {
      return quality.reasons.isEmpty
          ? const []
          : [text('analysis.quality.unknownReason')];
    }
    return codes
        .map(
          (code) => text(
            AppCopy.messages.containsKey('analysis.quality.$code')
                ? 'analysis.quality.$code'
                : 'analysis.quality.unknownReason',
          ),
        )
        .toSet();
  }

  String sessionSourceLabel(SessionMeasurementQuality quality) =>
      quality.sourceLabel == analysisMessages['analysis.quality.source']!.zh
      ? text('analysis.quality.source')
      : quality.sourceLabel;

  String sessionTitle(Map<String, dynamic> source) {
    final title = source['title'];
    if (title is String && title.trim().isNotEmpty) return title.trim();
    final id =
        source['id'] ??
        (source['path'] as String? ?? '').split(RegExp(r'[\\/]')).last;
    return text('analysis.session2', args: {'p0': id});
  }

  String sessionActivityLabel(Map<String, dynamic> source) {
    final ms = source['modifiedMs'];
    if (ms is! num) return text('analysis.activityTimeUnknown');
    final date = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return isEnglish
        ? dateTime(date, includeSeconds: true)
        : date.toLocal().toString().split('.').first;
  }

  String sessionStateLabel({
    required bool selected,
    required bool readFailed,
    required bool catchingUp,
    required Object? status,
  }) => text(
    !selected
        ? 'analysis.state.unselected'
        : readFailed
        ? 'analysis.state.failed'
        : catchingUp
        ? 'analysis.state.catchingUp'
        : 'analysis.state.${const {'running', 'completed', 'cancelled'}.contains(status) ? status : 'unknown'}',
  );

  String activityCategoryLabel(String category) => text(
    'analysis.${switch (category) {
      'message' => 'message',
      'reasoning' => 'reasoning',
      'tool' => 'tool',
      _ => 'other',
    }}',
  );
  String timelineDescription(SessionActivityTimelineData data) => text(
    data.available
        ? 'analysis.timeline.available'
        : 'analysis.timeline.unavailable',
  );
  String timelineRowLabel(SessionActivityTimelineRow row) =>
      '${activityCategoryLabel(row.category)} #${row.ordinal}';
  String timelineRowReasons(SessionActivityTimelineRow row) => row.reasons
      .map(
        (reason) => text(
          AppCopy.messages.containsKey('analysis.timeline.$reason')
              ? 'analysis.timeline.$reason'
              : 'analysis.timeline.unknownReason',
        ),
      )
      .toSet()
      .join(isEnglish ? '; ' : '；');
}
