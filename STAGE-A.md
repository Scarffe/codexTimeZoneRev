# 阶段 A：桌面监控原型

## 开发基线

- 上游：`https://github.com/iUshio/codexTimeZoneRev`。
- 本次实时核对并 fetch 的 main：`8c1daf4b7148a129de81d69f5b3a9b38f9f7c8b1`。
- 独立分支：`feat/desktop-monitor-stage-a`。
- 独立目录：`desktop-monitor-stage-a`。旧 `source` 的未提交改动、旧发布分支和桌面运行程序未替换。

## 运行与构建

双击本目录 `Start-Stage-A.cmd`：显示托盘和独立透明鲸鱼窗口。

双击 `Start-Stage-A-Test.cmd`：额外打开独立点击测试窗口，便于观察透明区域和焦点。

右击鲸鱼可打开与托盘共用的菜单：显示、隐藏、复位、退出。正常显示、点击、拖拽与重复启动不激活鲸鱼；用户主动打开菜单时需要菜单焦点。

这是模拟数据原型，托盘的 `DEMO 72%` 和鲸鱼下方进度条都是固定样例。没有网络请求、账号读取、启动 Codex、账号切换、开机自启、配置写入或 ACL 修改。

重新构建独立原型：

```powershell
.\scripts\build-desktop-prototype.ps1
```

完整 Flutter runner 已接入 `--desktop-prototype` 参数：先走已有 `package_context::Prepare`，之后进入同一原型模块，不初始化 Flutter 页面或原生用量后端。普通启动流程不变。

独立原型也复用同一包身份引导实现。`--preview` 使用上游既有的引导跳过机制，仅供隔离 UI 验证。不要把 `--verify-launch` 用作桌宠测试，它属于原有客户端启动检查。

## 实现边界

- `desktop_prototype.cpp/.h`：Win32 托盘、窗口、原始预乘 alpha 位图、拖动、菜单、单实例。
- 原创几何鲸鱼由代码绘制，没有直接复制第三方角色或素材。
- `WS_EX_LAYERED` + `UpdateLayeredWindow` 提供逐像素透明；零 alpha 区域由 Windows 命中测试穿透。
- `WS_EX_NOACTIVATE`、`MA_NOACTIVATE`、`SW_SHOWNOACTIVATE` 和 `SWP_NOACTIVATE` 维持非激活交互。
- 单实例标识按可执行文件路径和 Windows 会话区分；重复调用只通知已有原型恢复显示。
- 锁在包身份 Prepare 返回后才建立，外层引导进程不占锁，避免父进程阻塞被引导的 UI。
- 第一阶段的锁仅作用于原型模式；普通 Flutter 主窗口的全局常驻生命周期在阶段 B 接入。
- `--prototype-test-host` 创建本程序自己的普通窗口；不会把点击测试投向用户应用。
- 可选 `--prototype-report=<绝对路径>` 每 200ms 记录窗口可见性、前台身份、点击计数与恢复次数；这是开发诊断，非用量轮询。

Win-CodexBar 的职责划分和鲸鱼项目的交互问题用于设计参考；本阶段未引入它们的 Tauri/Electron 运行时或拷贝源代码。

## 本机验收结果

| 检查 | 结果与证据 |
| --- | --- |
| 独立原型编译 | MSVC `/W4 /WX /EHsc` Release 通过 |
| 完整启动器编译 | `flutter build windows --release --no-pub` 通过 |
| 静态检查 | `flutter analyze --no-pub` 无问题 |
| 原有 Flutter 回归 | 61 个测试通过 |
| 引导契约 | 原有 quoting / identity / internal-argument C++ 契约通过 |
| 初次显示不抢焦点 | 完整 runner 初始快照中前台仍为既有 Codex PID；petForeground=false |
| 透明区域真实点击 | 完整 runner 的 hostClicks 从 0 变 1，petClicks 保持 0 |
| 实体真实点击 | 完整 runner 的 petClicks 从 0 变 1，hostClicks 保持 1，hostForeground=true |
| 拖动 | 独立原型移动 40×20 像素，前台保持测试窗口 |
| 菜单隐藏及恢复 | visible=false 后重复启动恢复 true，原 PID 不变 |
| 位置复位 | 独立原型恢复原始窗口坐标 |
| 重复实例 | preview 与已验证包身份路径的第二实例均正常退出，已有实例收到恢复通知 |
| 托盘 | Shell_NotifyIcon 注册成功；显示/隐藏/复位/退出通过共用菜单实测 |
| 既有 Codex | 前后 15 个 ChatGPT/Codex Desktop 进程的 PID 和 UTC 启动时间逐一一致 |
| 清理 | 本次独立原型及完整 runner 测试实例均通过菜单正常退出 |

原始验收文件在 `environment/stage-a-evidence/`（本机诊断，不提交 Git）：

- `integrated-initial.json`、`integrated-duplicate.json`。
- `integrated-transparent-click.json`、`integrated-pet-click.json`。
- `after-hide.json`、`after-restore-hidden.json`、`after-drag.json`、`after-reset.json`。
- `prototype-preview.jpg`：仅含中性测试窗口与原创占位鲸鱼。
- `codex-before.json` / `codex-after.json` / `acceptance-summary.json`：进程保留核验。

## 尚未验收或不在本阶段范围

- 本次包身份路径实际记录为 `context_verified`；没有把它声称为一次从无包身份桌面启动到跨进程引导的完整实测。原有引导契约通过，外层与 UI 的锁顺序已核查。
- 通知区域实际图标鼠标点击、Explorer 重启后图标恢复尚未单独实测；托盘注册及共用菜单已验证。
- 多显示器、DPI 切换、休眠唤醒、远程桌面、长期性能均为 NOT_RUN。
- 无真实额度、自动刷新、提醒状态机、角色动画、素材导入或位置持久化。
- 本阶段交付给阶段 B 的结论：本机上可采用原生透明辅助窗口；真实输入证明了零 alpha 命中穿透和非激活交互。不能由此推断所有显卡、缩放与多屏环境均通过。

## 完整构建环境说明

使用现有本地 Flutter 3.47.5 和已缓存依赖。因系统未开启开发者模式，仅在此 worktree 的生成目录建立插件 junction 指向原有本地 pub-cache；未改动系统设置或 Flutter SDK。生成目录和构建产物均忽略，不作为源码提交。
