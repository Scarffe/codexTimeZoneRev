# CodexTimeZone：最近功能对标与缺口研究

研究时间：2026-10-24 05:16 UTC，即洛杉矶 2026-10-23 22:16。基线为 `desktop-monitor-stage-a` 的 `5897a8200cbc5a150e1a5afa199f1e1325c93ad1`。本文是研究建议，不是已批准的实现方案。

**最值得补的不是另一套图表，而是“多账户独立观测 + 多会话待处理队列 + 可解释的额度历史”。账户切换可以做，但应单独立项；它涉及凭据写入、续期竞争及已运行客户端的生效边界，不能伪装成查看额度的附属按钮。**

## 1. 本地现状：已有功能不重复推荐

已只读检查当前 README、docs/monitoring.md、相关 Dart/Rust 文件清单，以及 `AccountUsageController`、`account_usage.rs`、桌面发布与提醒入口：

- 已有：时区启动与时间预览、MSIX 包身份兼容、账户额度手动/自动刷新、托盘、低额度提醒与周期静音、选定本地会话的只读采集与完成提醒、最近回合/配置/活动时间线/响应图、来源与核验说明、减少动态效果、离线 Chat/Responses 回放。
- 账户控制器持有单个 `AccountUsage? data`，查询启动当前发现的 CLI app-server，读取当前登录身份、额度与可选累计用量；前后身份不一致时拒绝结果。未发现多账户目录/登记表、逐账户查询调度或活动账户切换事务。
- 会话列表可搜索并明确选择一个主会话；未发现同时监控多会话的待处理队列。现有文档明确：旧通知只定位当前选择，不恢复发生提醒时的旧会话。
- 目前累计与最近一天 token 是观测事实；文档明确没有完整每日投影时不制造趋势。当前“最近回合”不是跨项目/跨日用量账本。
- 真实 API 执行未开放。离线回放已存在，应作为验证基础，不应再次包装成新增能力。

本地依据：[README](../../README.md)、[监控说明](../../docs/monitoring.md)、[账户控制器](../../flutter_app/lib/state/account_usage_controller.dart)、[原生账户查询](../../native/launcher_core/src/account_usage.rs)。上述“未发现”限定于这次文档及窄范围源码核对，不代表穷尽式全库证明。

## 2. 七个值得参考的活跃仓库

表内“最近推送”是 GitHub REST 的 `pushed_at`，不是发布日期；“最新发布”是发布 API 的 `published_at`。UTC 10 月 24 日凌晨对应洛杉矶 10 月 23 日晚间，不能因日期跨日把它称为未来更新。所有仓库在本次 API 查询中均非 archived。详细时间、当前提交和 URL 保存在 [github-sources.json](github-sources.json)。

| 仓库 | 最近推送 UTC / 洛杉矶日期 | 最新正式发布（UTC） | 许可证核对 | 最有用的借鉴 |
| --- | --- | --- | --- | --- |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | 2026-10-24 03:41:49 / 10-23 | [v0.80.0 · 10-23 02:36](https://github.com/steipete/CodexBar/releases/tag/v0.80.0) | [MIT](https://github.com/steipete/CodexBar/blob/main/LICENSE) | 查看账户与系统账户分开；额度历史/消耗节奏；服务状态 |
| [nesszer/Win-CodexBar](https://github.com/nesszer/Win-CodexBar) | 2026-10-24 02:43:28 / 10-23 | [v0.70.0 · 10-03 14:14](https://github.com/nesszer/Win-CodexBar/releases/tag/v0.70.0) | [MIT](https://github.com/nesszer/Win-CodexBar/blob/main/LICENSE) | Windows DPAPI、多账户缓存、悬浮条、逐来源提醒与节奏 |
| [farion1231/cc-switch](https://github.com/farion1231/cc-switch) | 2026-10-23 15:54:34 / 10-23 | [v4.0.19 · 10-23 12:49](https://github.com/farion1231/cc-switch/releases/tag/v4.0.19) | [MIT](https://github.com/farion1231/cc-switch/blob/main/LICENSE) | 切换预览、配置备份、项目配置、历史统计与日志阅读 |
| [ccusage/ccusage](https://github.com/ccusage/ccusage) | 2026-10-24 03:34:12 / 10-23 | [v20.0.42 · 10-23 14:38](https://github.com/ccusage/ccusage/releases/tag/v20.0.42) | [LICENSE 正文为 MIT](https://github.com/ccusage/ccusage/blob/main/LICENSE)，API 为 NOASSERTION | 本地跨日/会话/模型账本、日期分组与时区、价格离线缓存 |
| [SilkageNet/codex-switch](https://github.com/SilkageNet/codex-switch) | 2026-10-23 15:03:31 / 10-23 | [v0.4.1 · 10-23 15:04](https://github.com/SilkageNet/codex-switch/releases/tag/v0.4.1) | [MIT](https://github.com/SilkageNet/codex-switch/blob/main/LICENSE) | 窄范围账户工具：隔离查询、逐账户缓存、切换锁与恢复日志 |
| [JustinTervala/monitor](https://github.com/JustinTervala/monitor) | 2026-10-12 19:54:30 / 10-12 | [v0.3.0 · 10-01 18:04](https://github.com/JustinTervala/monitor/releases/tag/v0.3.0) | [MIT](https://github.com/JustinTervala/monitor/blob/main/LICENSE) | 待审核/运行/已读队列、准确回到原任务、分组与分叉树、通知去重 |
| [arvivares/statusline](https://github.com/arvivares/statusline) | 2026-10-21 11:57:12 / 10-21 | [v0.1.40 · 10-14 22:17，产品仍 Beta](https://github.com/arvivares/statusline/releases/tag/v0.1.40) | [MIT](https://github.com/arvivares/statusline/blob/main/LICENSE) | 只同步最小额度快照、手机组件、端到端加密、显式订阅通知 |

名称已实时消歧：原 `Finesssee/Win-CodexBar` 目前重定向到 `nesszer/Win-CodexBar`；ccusage 已在 `ccusage/ccusage` 组织下。不要把 `jspann21/codex-bar` 或 `ZyyoungM/Codexbar-win` 当成同一个 Windows 移植。

### CodexBar：最值得学的是“观测身份”与“生效身份”分开

当前 Codex 文档支持独立账户行，每行保留自己的额度、年龄和错误；刷新一行/全部不会改变被跟随的账户或提升为 System。可配置现有 profile home；选择卡片不复制凭据、不重启守护进程。System promotion 是另一操作，并有可能中断工作。原生令牌来源也明确不由 CodexBar直接把续期令牌写回共享 auth.json。其额度消耗线基于已记录快照，并展示采样时间与均匀使用参考线。**本项目可以借用身份与缓存模型，不能因此承诺完整官方协议或照搬 macOS 凭据行为。** [账户与来源文档](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)、[功能说明](https://github.com/steipete/CodexBar#features)

### Win-CodexBar：Windows 的提醒与轻量外观参考

当前文档有常驻浮条、额度节奏、服务状态、逐提供方阈值、可关闭的费用统计、隐私化账户名、脱敏诊断与无密钥的偏好导出。Codex 账户提供 Ambient/Managed 身份标记，设置包含 Refresh usage、Switch、Restart Codex Desktop，存储由 DPAPI 保护。Overview 可以只读缓存展开各账户，尚无快照时显示空态；并非所有账户展示都等于已查询。**本项目的托盘与提醒已具备，真正新增的部分是多账户来源与缓存、可选浮条和更少打扰的状态提示。** v0.70.0 发布与当前 main 的功能范围应分开验收。[README](https://github.com/nesszer/Win-CodexBar#what-the-app-does)、[配置与账户说明](https://github.com/nesszer/Win-CodexBar/blob/main/docs/CONFIGURATION.md)、[窗口与节奏](https://github.com/nesszer/Win-CodexBar/blob/main/docs/PROVIDERS.md)

### CC Switch：配置事务值得学，代理路由不宜跟着引入

它已发展为配置、供应商、订阅账户、MCP/Skills、会话阅读和跨日用量管理器；切换前可看配置结果，并自动备份。也有本地代理、协议转换和失败转移，这些会改变真实请求路径。Codex 的模型/聚合列表变化可能要求重启共享 daemon，仓库明确提示可能中断任务。**本项目优先参考“预览—有界改动—备份—检测冲突”，不要为了账户管理顺带加入代理、自动轮换或配置同步。** [功能与边界](https://github.com/farion1231/cc-switch#features)、[重启说明](https://github.com/farion1231/cc-switch#faq)

### ccusage：历史统计与时区是更贴近本项目的增量

从本地日志生成日/周/月/会话及模型报告，支持日期过滤、JSON、自定义路径、离线价格和时区分组。适合参考增量索引、归档会话覆盖与成本来源标签。**日志 token 不等于账户额度；API 等值估算不等于订阅实付，跨提供方的不同单位也不能相加。** 当前根 LICENSE 已检查为 MIT，修正仅凭 API NOASSERTION 就断定未知许可证的做法；复用具体文件仍需保留声明并核对文件归属。[README](https://github.com/ccusage/ccusage#features)、[LICENSE](https://github.com/ccusage/ccusage/blob/main/LICENSE)

### SilkageNet/codex-switch：最直接的账户边界反例

README 说明每个已保存账户可用独立临时 CODEX_HOME 查询，串行刷新、失败保留上次成功值与错误；实际切换用锁、compare-before-replace 和恢复日志，只改变认证投影。**但同一文档也说明，查询可能持久化正式续期的凭据，并对活动账户安全同步 auth.json，因此“未切账户”不等于“凭据文件零写”。** 新增 account wake 会发送真实最小请求并消耗额度，完全不属于只读监控。Windows 文档要求可独立启动的 Codex CLI；本项目自有 MSIX 兼容流程须独立验证，不继承该工具的路径结论。[无切换查询](https://github.com/SilkageNet/codex-switch#usage-without-switching)、[切换改动范围](https://github.com/SilkageNet/codex-switch#what-a-switch-changes)

### Monitor：让用户知道“哪件事需要我”，不只知道“用了多少”

它把工作流分为 Needs review、Running、Read，允许跨任务分组、休眠、本地归档、分叉关系与回到原任务；新完成、输入请求、审批和错误能通知，初始历史与重连不补发。它依赖 Mac 本地数据库/内部 IPC 与可选 hooks，版本兼容有限；Stop 不能单独证明完成。其延迟 handoff summary 会另开真实模型请求，不能作为无余额功能推荐。**适合参考元数据待办队列、准确通知归属与去重，不能直接照搬内部 IPC 或未经授权装 hooks。** [使用与通知](https://github.com/JustinTervala/monitor#use)、[集成限制](https://github.com/JustinTervala/monitor#integration-limits)

### Statusline：离开电脑后的额度可见性

桌面、iOS、Android/组件共用额度快照，通过独立 publisher/pairing/reader 权限及 AES-GCM 同步，避免把账号凭据与对话交给 relay。恢复额度通知是显式可选。**这是远期方向：带来设备配对、移动端、服务器、密钥生命周期与分发成本；当前 Windows desktop-only 发现仍标记待验证，产品 Beta 与正式 GitHub release 标签不是一回事。** 本项目没有手机查看需求时，先做本地能力更划算。[README 与边界](https://github.com/arvivares/statusline#how-it-works)、[v0.1.40 发布](https://github.com/arvivares/statusline/releases/tag/v0.1.40)

## 3. 真实缺口与优先级

| 优先级 | 建议增量 | 对用户的具体价值 | 开始实现前需要证明的边界 |
| --- | --- | --- | --- |
| P0 | 多账户/工作区**观测目录**：别名、来源、逐账户快照、错误与更新时间 | 同页回答哪个账号可用、多久重置；查看 B 不影响正在用 A | 区分界面选中、查询目标、客户端活动身份；身份稳定键包含 workspace；共享额度池只在有明确标识时合并；不把两账户百分比相加 |
| P0 | 多会话**待处理队列**，先从显式添加/固定的本地日志开始 | 同时跑几件事时，看到哪项完成或需人操作；通知能回到准确会话 | 不因 mtime 推断运行；“等待审批”仅在有确定事件时显示；通知保存原 session/turn 身份；旧通知不误跳当前选择；不自动恢复/发送消息 |
| P1 | 本地每日/项目/模型用量账本，增量扫描与可选归档覆盖 | 看清资源去哪了，定位重复长上下文与缓存消耗 | 累计 token 快照去重；历史缺口显式呈现；按固定时区重分组可复算；成本估算注明价格版本及订阅/接口口径 |
| P1 | 额度观测历史 + 节奏参考/保守预测 + 自适应刷新 | 从“还剩 30%”升级为“按近况是否容易先耗尽” | 至少有足够独立快照；重置/账户/方案变化切段；样本不足不给预测；标为估计，不把未知额度当 100%；服务状态不充当当前请求根因 |
| P1 | 指向原事件的通知收件箱、逐会话静音与重连去重 | 现有通知不再成为一闪而过、无法核对的文本 | 每条有来源、事件身份、发生/读取时间与已过期标签；不重放历史；不向外发送内容 |
| P2 | 真实账户切换，和 API provider 切换分开 | 降低反复登录摩擦 | 先做独立设计：OS 密钥库、续期冲突、并发写者、备份恢复、活动进程生效说明；不自动停止/重启当前 Codex，不把刷新变成切换 |
| P2 | 可选小浮条/跨设备最小快照 | 全屏工作或离开座位时仍看见额度 | 浮条可复用现有快照、无额外查询；跨设备另定隐私/密钥与部署范围 |

**账户路线建议：先 P0 观测，再讨论 P2 切换。** 第一阶段甚至可只做“已有来源的最后快照比较”；新账户登记/认证导入、真实跨账户查询、凭据续期与活动登录写入不因这份报告自动获得授权。若后续采用官方 app-server 查询，必须区分“只发只读业务方法”与“CLI 内部认证是否会续期写盘”，单独验证并在方案中说明，不能承诺未经证明的绝对零写。

MVP 建议一次只做前两项中的一项，优先多账户观测；多提供方、代理路由、自动账号轮换、手机同步、内容摘要都应后置。对比工具的动效/状态栏可取灵感，但当前产品已有充足图表与动效，增加图形数量不会补足账户和任务归属。

## 4. 三个可形成自身特色的提案

以下是结合本项目现有时区启动、严格测量边界和离线回放提出的设计组合；它们是建议，不宣称全球首创，也不把来源仓库未提及当作从未实现的证明。

1. **“下一次启动会怎样”准备卡。** 同屏显示当前运行实例的已知身份、时区与来源，以及启动草稿里下一进程将用的时区/账户/profile/provider；只展示经过核对的差异，未知留空。配一条按目标时区和本地时区对齐的重置日历，跨夏令时边界明确标识。实际价值是防止“界面已选 B，现有 Codex 就已变 B”的误解；点击查看永远不执行切换或重启。它把时区启动器的核心优势用到新账户功能上。

2. **“读数为什么变了”证据卡。** 对额度突然归零、重置时间跳变、日志字段升级后速度消失等现象，给出前后快照来源、身份/方案/窗口变化、数据年龄和具体不可核验原因。提供对应的合成回放演示，而不是猜测服务商、网络或模型故障。实际价值是让更新后的异常可解释、可复现；导出诊断前仅生成本地白名单预览，不包含 auth、prompt、回答、命令正文。

3. **“今天这项任务能否排进去”容量排演。** 用户自行输入预计持续时间或历史同类任务范围，系统用已观测额度历史和重置点，展示保守/中性两种情景及数据不足位置；加入本地/目标时区的工作日边界。它只做本地计算，不向模型试跑、不启动闲置窗口、不声称额度百分比能精确换算 token。实际价值是决定现在开始长任务还是等重置；这是情景估计，应可完全关闭。

## 5. 研究方法与交付边界

- 发现候选使用互联网搜索；结论仅采用仓库 README、docs、LICENSE、GitHub REST 仓库/commit/release 原始结果，不依赖第三方榜单、DeepWiki 或搜索片段。
- PowerShell 的匿名 GitHub 请求受本机代理套接字限制，web 的 api.github.com open 也不可用，改用现有 GitHub connector 的只读 public fetch 得到原始 REST；没有登录、授权更改、下载二进制或安装工具。
- 维护日期证明仓库近期活跃，不证明稳定性、安全性或 Windows 适配成熟。功能以当前 main 文档为主，发布表单独列出最近 release；不能把当前 main 的全部功能声称都已进入最新安装包。
- 本轮只新增这份研究文档与来源元数据。没有改产品代码、读取真实账户、覆盖凭据、启动/重启客户端、装 hooks、开启 telemetry 或发送模型请求。

