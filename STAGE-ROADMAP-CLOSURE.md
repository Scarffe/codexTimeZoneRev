# rc26：路线收口与中英界面

本阶段从 rc25 (`87c495c`) 分出 `feature/roadmap-closure`。范围由 [自主路线](AUTONOMOUS-ROADMAP.md) 固定：保留已完成的启动器、六工作区、多账号、关注收件箱、当前会话五图、U1/U2 和独立离线测速，补齐中英文界面及排版。未恢复桌宠、真实任务或热切换，也不添加研究提案中的每日 token 账本。

## 使用

- 默认中文，顶部语言按钮可切换 English。正常版保存语言选择；明确标注的合成体验版仅本次生效。
- 三套配色及明暗模式保持原设计。Windows 使用 Segoe UI Variable Text，中文优先回退 Microsoft YaHei UI / Microsoft YaHei；不宣称字体存在人人一致的舒适结论。英文行距 1.45，中文 1.5，选择器随语言调整宽度。
- 用户别名、会话标题、路径、模型/工作区标识与来源原文保持不变。应用自有操作、状态、图例、说明及通知标题提供双语。
- 切换语言不重新登录、不换监控来源、不重读日志、不重新发提醒。说明窗口保留打开状态及选中内容；真实样本或来源替换仍按原规则关闭过期说明。
- 新包使用独立目录和 `Start-Candidate.cmd`。默认关闭自动刷新与提醒，不携带 rc22/rc24 的认证、缓存或日志，也不覆盖旧候选。正常版手动登录和额度查询会联网；合成版仅使用内存测试来源。

## 已完成与未验证的区别

本轮使用合成来源、自动化渲染、原生窗口/菜单隐藏夹具和发布构建验收；没有发送真实模型请求，没有操作当前 Codex 或用户桌面。验证日志、截图、包清单与保护回执保存在 `environment/roadmap-closure-20261025-a/`，最终结果见该目录 `VALIDATION-REPORT.md`。

人工项目仍为 **HUMAN_REQUIRED / NOT_RUN**：真实双账号和续期、自然系统通知点击、真实多屏/混合 DPI、真实休眠恢复等。以前已做的单账号官方登录/额度/隐藏监控/重启证据继续有效，但不扩张成这些未做项目已通过。K3 真实任务、运行中的账号热切换、H2.3 流式入口与 M4 真实 API 测速继续暂缓。

Rust 核心未改动时按精确组件树及 DLL 哈希复用已验证构建；新的 Windows runner 单独发布构建。已记录的旧 Rust 全库 Clippy / 格式基线不在本阶段无关重构。

## English quick guide

Use the language control in the header to choose English. The regular candidate remembers your choice; the clearly marked synthetic demo keeps changes in memory. Your aliases, session titles, paths and source data remain unchanged. Switching language preserves monitoring owners, selected data, draft settings and open inspectors without producing new requests or duplicate alerts.

The three existing color families retain light and dark variants. Launch this independent directory with `Start-Candidate.cmd`. Monitoring is off by default; no credentials or real logs are bundled. The regular build retains the launcher's existing IP/geolocation lookup at startup, as well as explicit login and quota queries. The synthetic build uses memory-only sources and preview network data. Live model requests and account hot switching remain unavailable in this delivery.
