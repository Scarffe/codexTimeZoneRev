# Codex 时区启动器

使用 Flutter + Forui 的 Windows/macOS 桌面启动器，为新启动的 Codex 注入独立时区，不修改操作系统全局时区。应用界面组件使用 Forui，系统文件选择器保留原生交互，应用图标沿用原项目。

## 功能

- IANA 地区时区（自动处理夏令时）及 UTC−12 至 UTC+14 固定偏移。
- 自动发现客户端、选择路径、保存配置、启动检查与桌面快捷方式。
- 本地/目标时间预览、双线路公网信息、缓存、复制 IP 和应用识别时区。
- Dream Skin 兼容入口、跟随系统/浅色/深色主题。
- 兼容旧版 settings.json；Rust 原生后端通过 JSON C ABI 接入 Flutter。

## 开发与构建

环境：Flutter 3.47.5 / Dart 3.13.4、Forui 0.27.0、Rust stable。Windows 需要 Visual Studio C++ 桌面工具链；macOS 需要 Xcode。

Windows 默认使用 `E:\development` 下的工具，无需 Node.js、Tauri 或 WebView2：

```powershell
.\scripts\flutter-windows.ps1 -Action test
.\scripts\flutter-windows.ps1 -Action preview
.\scripts\flutter-windows.ps1 -Action run
.\scripts\flutter-windows.ps1 -Action build
.\scripts\test-native-windows.ps1
```

`preview` 使用演示数据；`run` 使用实际配置与原生功能。可通过 `-FlutterSdk` 指定其他 Flutter SDK 路径。

Windows 便携包：`environment/artifacts/CodexTimeZone-Flutter-windows-x64.zip`。解压后运行 `codex_timezone.exe`，保留整个目录中的 DLL 与 data 资源。用户设置位于程序旁的 `data/settings.json`，打包时不会包含本地用户配置。

macOS 构建：

```bash
bash scripts/flutter-macos.sh test
bash scripts/flutter-macos.sh build
```

macOS 尚待实机验收，构建脚本仅进行本地 ad-hoc 签名，对外发布需要 Developer ID 签名及公证。

## 目录

```text
flutter_app/                  Flutter + Forui 应用、图标、平台 runner 与测试
native/launcher_core/         Rust C ABI、公共逻辑、Windows/macOS 原生实现
scripts/                     开发、验收、打包脚本
.github/workflows/           Flutter 双平台构建工作流
environment/                 本地工具缓存与构建产物（不提交）
```

本分支已移除旧 Vue/MacVue/Tauri 工程及其 Node 构建入口；旧实现可通过 Git 历史查阅。详细步骤与已知限制见 [运行说明](flutter_app/README.md) 和 [迁移记录](FLUTTER_MIGRATION_PLAN.md)。实际 Codex/Dream Skin 联动、部分代理兼容性及 macOS 实机验收仍待完成。
