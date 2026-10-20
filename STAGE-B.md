# 阶段 B：真实用量与桌面常驻

## 分支与启动

- 阶段 A 已保留为本地提交 `b3a7ddc`，分支 `feat/desktop-monitor-stage-a`。
- 阶段 B 在独立分支 `feat/desktop-monitor-stage-b` 开发，工作目录沿用 `desktop-monitor-stage-a`。
- 双击 `Start-Stage-B.cmd` 启动隔离的 `environment/stage-b-portable/`，默认每 2 分钟查询额度。
- 双击 `Stop-Stage-B.cmd` 正常退出同一路径下的隔离监控；退出请求会等待正在进行的查询清理，不使用强制终止。
- 关闭主窗口会隐藏到托盘，后台仍监控。托盘或桌宠右键菜单提供打开主窗口、立即刷新、暂停/恢复、显示/隐藏桌宠、复位与退出。
- 再次启动同一隔离版本恢复已有主窗口。普通启动不带 `--desktop-monitor` 时维持原有关闭即退出行为。
- 原桌面程序和现有配置未替换，当前 Codex 不需要重启。

## 数据链路

`AccountUsageController` 是唯一查询调度者。主窗口直接订阅控制器，`DesktopMonitor` 将同一快照通过 MethodChannel 发布给原生托盘与桌宠；原生窗口不再创建查询或定时请求。

自动查询沿用本地已登录 Codex 的 `app-server`，调用 initialize、account/read、account/rateLimits/read，再核对账号。不会直接读取 auth.json 或处理 OAuth token。手动详细查询仍可读取 account/usage/read；后台轻量查询明确跳过该方法。

返回的窗口按实际时长展示，不固定假定账号有 5 小时窗口。桌宠和托盘优先显示 `codex` 额度池中已知窗口的最低剩余比例；其他独立额度池仍可在主窗口查看。未知额度显示未知，不补成 0。数字是剩余额度百分比，不换算为 token。

## 调度、缓存与失败

- 默认 2 分钟；主窗口可选 1、2、5、10 分钟，当前进程内生效。
- 同时只允许一个查询。手动刷新、托盘刷新和定时刷新共用互斥状态。
- 下一次定时查询从上一次查询结束后计时，主窗口隐藏不会取消控制器。
- 失败后延迟为 `max(刷新间隔, min(30 分钟, 30 秒 × 2^(连续失败次数-1)))`。
- 手动刷新不能绕过失败等待；成功后清零失败次数并恢复正常周期。
- **缓存仅保存在当前进程内**；网络失败保留最近成功快照，标记过期和上次观测，桌宠变灰。重启后重新查询，不把账号数据写入磁盘缓存。
- 账号身份改变时不沿用旧账号统计；登录失效与查询中账号切换时清空旧缓存。切换查询来源会废弃迟到结果。
- 轻量额度查询只在身份一致时保留先前手动查询的 token 统计；额度更新时间与详细统计时间分开保存在模型中。
- 所有账号查询失败返回固定的脱敏错误；限流归入失败退避。当前 RPC 没有透传 HTTP Retry-After 头，本阶段不声称支持服务端未提供的等待元数据。
- 退出先暂停调度并等待本轮查询完成；Rust 为每个查询子进程设置独立 kill-on-close Job，异常结束隔离程序时也只清理自己的查询进程。

## 验证记录

原始记录位于 `environment/stage-b-evidence/`，不提交私人运行数据。

| 检查 | 结果 |
| --- | --- |
| Flutter 静态检查 | 无问题 |
| Flutter 回归及新增监控测试 | 67 项通过 |
| 原生后端 | 30 项通过；1 项已有安装诊断忽略；1 项旧权限测试单独核对基线 |
| 轻量查询 | fixture 遇到 account/usage/read 即失败，轻量测试通过 |
| 缓存与退避 | 假时钟测试验证 30→60 秒退避、缓存保留、恢复清零和手动请求不能绕过等待 |
| 并发与身份 | 验证自动/手动互斥、来源变化丢弃迟到结果、账号变化清除旧统计 |
| 查询进程所有权 | Job 关闭清理自己的模拟子进程、超时清理测试通过 |
| 真实 app-server | 隔离 10 秒验收版连续成功查询，主窗口不可见时 revision/attempts 继续增加 |
| 默认构建 | 独立默认 2 分钟版本成功构建并取得真实额度；另在本机实际切换间隔和关闭主窗口验收 |
| 关闭后真实刷新 | `default-before-close.json` 的 revision=1；`default-after-close.json` 为同一 PID、mainVisible=false、revision=2 |
| 单实例修正 | 捕获并修复 Flutter Create 前调用 Destroy 导致锁提前释放的问题；修正后重复启动 Count=1、第二实例 Exit=0 |
| 主窗口恢复 | 修正后实际关闭窗口再重复启动，恢复同一个窗口和进程；`corrected-restore.json` |
| 正常退出 | 最终交付版取得真实额度后，通过 `--desktop-monitor --monitor-exit` 退出；请求进程与监控进程退出码均为 0，剩余实例为 0；`delivery-exit.json` |

`hidden-refresh-observed.json` 记录 10 秒测试版同一 PID 的第 4 个成功快照、`mainVisible=false`、`failures=0`。这份构建仅用于短时验收，不作为默认交付版。

原有 `windows::repair::tests::missing_identity_returns_a_repair_offer_without_running_the_child` 在当前包身份宿主环境下失败；在未修改的旧 `release-v0.2.3` 源码中复跑，同样报“新进程的程序包身份与所选客户端不一致”。记录在 `baseline-repair-test.log`。本次没有通过修改权限修复逻辑来隐藏此失败，也没有执行真实客户端安装诊断。

`live-pet.jpg` 仅保存桌宠区域，不含主窗口的账号与网络信息。完整窗口截图只用于交互验收，没有另存到交付物。

最终清单为 `acceptance-summary.json`，交付 EXE/DLL 哈希为 `delivery-hashes.json`。测试期间的旧候选版本曾按精确路径和新建 PID 清理；最终交付版本已另外完成正常退出验收。

## 构建与打包

使用已有本机工具链（仅进程环境变量）：

```powershell
. ..\source\environment\toolchains\use-toolchains.ps1
$env:CARGO_TARGET_DIR = Join-Path (Get-Location) 'environment\stage-b-cargo'
cargo build --offline --release --manifest-path native\launcher_core\Cargo.toml
Push-Location flutter_app
flutter build windows --release --no-pub
Pop-Location
.\scripts\package-desktop-monitor.ps1
```

打包脚本只复制运行时、Flutter assets 和当前阶段 B DLL，不复制旧日志、账号信息或用户配置。独立目录内产生的 context.log 是本次运行诊断。

## 当前边界

- 桌宠仍使用阶段 A 的原创静态占位鲸鱼，本阶段新增真实数字、额度条和过期变灰；复杂角色动画、提醒气泡与素材工坊属于后续阶段。
- 尚未验收跨显示器 DPI、休眠唤醒、长期资源占用或 macOS 原生桌面层。
- 账号级别的额度是快照，无法由此推断具体聊天是否正在工作、任务是否完成。
- 尚未替换原程序或推送 GitHub。
