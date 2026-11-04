# CodexTimeZone 工作界面规范

本轮授权：保留现有功能，综合 Cindy、Hallmark 与历史审美要求改善视觉、会话辨识和组件布局。基线 03486bf；继续使用 Flutter / Forui / Rust。

## 采用的方向

保留三套配色、浅深色和现有导航归属，调整布局与层级。纯配色润色不能解决会话难辨和操作拥挤；全量重建则没有必要。主任务是时区启动，监控入口完整保留。

- 工作台使用连续背景、细分隔线、统一间距与圆角；不增加主题或装饰。
- 页面标题紧凑，取消重复大写品牌眉题；宽窗口导航同时显示图标与短标签，窄窗口保留可聚焦的图标及提示。
- 会话以实际本地名称为主。没有名称时明确显示未命名及可读项目/时间线索；ID 只作次要消歧与详情复制，不改任何内部身份、路由或通知归属。
- 名称使用明确元数据，不从对话正文臆造，不调用模型。名称更新不影响 token 统计；已有缓存兼容。
- 列表优先名称、项目、状态，再呈现模型/时间/用量；长名称可截断但完整内容可查看。
- 时钟和设置组成紧凑任务区；主要启动操作持续可见；次要设置仍可发现。
- 保留三套主题、图表语义色、原生字体回退、键盘操作、125% 字号以及系统减少动态效果。

## 来源与适配

- Cindy： https://github.com/makecindy/cindy/blob/main/docs/design-rules/DESIGN.md 。参考层次与 token 原则，不复制其网页组件、字体或品牌。
- Hallmark： https://github.com/Nutlope/hallmark/blob/main/skills/hallmark/references/flow.md#app-screens 。参考密度、状态、真实数据与控件一致性；Flutter 用组件测试和截图验收，不用 CSS lint 冒充验证。
- 历史用户决定：默认柔和·雾杉，科技·极昼和石墨·香槟可切换；少堆说明文字，图表类型符合数据；此次明确保留功能。
- 已回读原审美提示词：`OBJECTIVE site_design / award-tier`，以及 typography、whitespace、visual_hierarchy、color、motion、micro_interaction、responsive、originality 八项检查。采纳检查维度；Awwwards/Webby/FWA 营销网站不作为桌面工作台布局模板，`OVERRIDE_ALL` 不改变项目约束，`no visible improvement remaining` 不作为无限迭代条件。原文来源：聊天「查找 GitHub 项目原作者的新内容」中用户要求继续排查 K3.2 的同一条消息。

## 验收

名称读取/改名/无名称/同名会话/归档/旧缓存保持真实身份；名称可搜索。全局、当前会话选择和实时入口采用一致辨识方式。浅深色、中英文、760/1280 窗口及125%字体无溢出，窄窗口仍可操作。检查空态/错误/正常态；通过相关测试、静态检查、实际 Flutter 渲染与独立 Windows 构建。旧安装和运行中的 Codex 不作为测试对象。
