# Flutter + Forui 桌面重制版

执行方案与进度见仓库根目录 `FLUTTER_MIGRATION_PLAN.md`。本分支已移除旧 Vue/Tauri 工程；原生实现位于 `native/launcher_core/src/platform`，图标沿用原项目。Windows 交付形式为包含完整资源的便携 ZIP。

## 环境

- Flutter 3.47.5 / Dart 3.13.4
- Forui 0.27.0（精确锁定，依赖见 pubspec.lock）
- Rust stable，以及 Windows Visual Studio C++ 桌面工具链 / macOS Xcode
- 当前 Windows SDK 路径：`E:\development\flutter`
- Pub 缓存：`E:\development\flutter-pub-cache`
- Windows 脚本使用 PowerShell 7；不需要把 Flutter 加入系统 PATH。

## Windows

在仓库根目录运行：

```powershell
.\scripts\flutter-windows.ps1 -Action doctor
.\scripts\flutter-windows.ps1 -Action test
.\scripts\flutter-windows.ps1 -Action preview
.\scripts\flutter-windows.ps1 -Action run
.\scripts\flutter-windows.ps1 -Action build
.\scripts\test-native-windows.ps1
```

`preview` 使用固定演示数据，不保存配置、不查询网络、不启动外部应用、不写剪贴板。正式 `run` 使用原生 DLL 和真实后端，启动界面即会读取设置并查询公网信息，与旧版一致。

Release 产物位于 `flutter_app/build/windows/x64/runner/Release`，便携 ZIP 位于 `environment/artifacts/CodexTimeZone-Flutter-windows-x64.zip`。运行 `codex_timezone.exe`；必须保留整个目录，不能只复制 EXE。

开发与构建脚本会编译 Rust 并捆绑 `codex_timezone_core.dll`，CMake 同时安装 MSVC 可再分发运行库。其他 SDK 位置可传入 `-FlutterSdk`。如果直接运行 `flutter run`，需先编译核心并设置 `CODEX_TZ_NATIVE_LIBRARY` 为 DLL 的绝对路径，否则应用会显示缺少原生组件并禁用保存/启动。

原生验收脚本在 `environment/native-acceptance-<唯一标识>` 下创建测试客户端和配置，验证真实进程启动及环境变量，不启动实际 Codex。Cargo/Rustc 需在 PATH；本机路径为 `E:\development\Rust\cargo\bin`。

## macOS（待实机验证）

```bash
bash scripts/flutter-macos.sh test
bash scripts/flutter-macos.sh preview
bash scripts/flutter-macos.sh run
bash scripts/flutter-macos.sh build
```

脚本需从包含完整仓库的 macOS 环境运行，并确保 Flutter / Cargo 在 PATH。原生库编译为宿主架构；本轮没有声明 universal binary 支持。

应用需要访问外部客户端、脚本、应用配置及快捷方式，因此不启用 App Sandbox，与桌面启动器的用途一致。脚本产物仅作本地 ad-hoc 签名；对外分发须另行完成 Developer ID 签名、公证与目标机器回归。

## 配置兼容

- Windows：主程序旁的 `data/settings.json`，与 Flutter 的 data 资源共存；搬迁旧版时复制该文件，不覆盖 Flutter 资源。
- macOS：继续使用 `~/Library/Application Support/com.fei-away.codextimezone/settings.json`。
- 字段、旧字段别名、BOM 及 Windows 旧目录迁移由原后端处理。
- Flutter 主题与网络缓存使用独立偏好键；本轮不迁移旧 WebView localStorage。首次打开跟随系统主题，并重新查询网络。
- ZIP 打包只包含应用资产，排除构建目录中可能存在的用户设置和日志。

## 验证与限制

窗口图标、RTSS 应用排除与原生亚克力背景详见根目录 `WINDOWS_APPEARANCE.md`。默认开启亚克力；可使用 `codex_timezone.exe --solid-background` 回退实色背景。RTSS 排除是本机配置，不会随安装包在其他电脑自动生效。

已通过 Rust 核心 10 项测试、Dart 静态检查和 Flutter 29 项测试。隔离原生验收通过旧格式读取、保存、中文带空格路径、启动测试进程、子进程 TZ、清理 ELECTRON_RUN_AS_NODE、重复启动拦截、损坏配置保护和恢复；临时目录内的 Windows 快捷方式已通过 COM 回读目标检查。

Windows 网络请求使用 WinHTTP 读取系统静态代理并解析 PAC/WPAD，Dart 执行可取消的 HTTP 请求。已用本地 PAC 服务及 HTTP 代理验证路由、重定向、取消与超时。macOS 改用 URLSession 系统网络通道，Dart 通道测试通过，Swift 实现尚待 macOS 构建和实机验证。Windows 当前不支持 SOCKS 或需要认证的代理，此类场景不能视作与旧 WebView 等价。

文件选择取消/成功、等待时防重复操作、剪贴板写入回读和失败提示已通过注入依赖的 UI 测试，未将这些测试等同于操作系统界面实测。

`.github/workflows/flutter-desktop.yml` 提供手动触发的 Windows/macOS 检查与打包；工作流尚未在远端运行，不发布正式版本。

界面测试覆盖浅深主题、1280×900 / 760×900 / 600×800，无溢出。生成截图：

```powershell
$env:PUB_CACHE = 'E:\development\flutter-pub-cache'
$env:CAPTURE_UI = '1'
Set-Location flutter_app
& 'E:\development\flutter\bin\flutter.bat' test test/page_test.dart
```

截图输出到 `build/ui-review`，Windows 测试使用系统微软雅黑，不在仓库中分发系统字体。

尚待专项验收：

- Windows 实际 Codex 与 Dream Skin 联动，以及文件选择器、剪贴板的系统交互。
- macOS 构建、系统交互、签名、公证及所有真实启动行为。
- 在用户实际代理配置下对比旧 WebView 出口；Windows SOCKS/认证代理兼容性尚未完成。
- 旧 WebView 主题与缓存不自动迁移；核心 settings.json 兼容不受影响。

上述验收完成前仍按开发版本交付；旧版源码可从 Git 历史恢复。
