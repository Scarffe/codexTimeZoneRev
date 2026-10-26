#ifndef RUNNER_UI_COPY_H_
#define RUNNER_UI_COPY_H_

#include <string>

namespace ui_copy {
enum class Language { zh, en };

inline Language ParseLanguage(const std::string& code) {
  return code == "en" ? Language::en : Language::zh;
}

struct Copy {
  const wchar_t* window_title;
  const wchar_t* menu_open;
  const wchar_t* menu_refresh;
  const wchar_t* menu_automatic;
  const wchar_t* menu_exit;
  const wchar_t* quota_title;
  const wchar_t* turn_title;
  const wchar_t* background_title;
  const wchar_t* background_body;
  const wchar_t* test_quota;
  const wchar_t* test_session;
};

inline const Copy& For(Language language) {
  static constexpr Copy chinese{
      L"Codex 时区启动器", L"打开主窗口", L"立即刷新额度", L"自动刷新", L"退出程序",
      L"Codex 额度提醒", L"Codex 回合提醒", L"Codex 后台运行",
      L"窗口已隐藏，监控仍在后台运行。双击托盘恢复，托盘菜单可退出。",
      L"测试注入：额度提醒", L"测试注入：回合提醒"};
  static constexpr Copy english{
      L"Codex Time Zone Launcher", L"Open main window", L"Refresh quota now",
      L"Automatic refresh", L"Exit application", L"Codex quota alert",
      L"Codex turn alert", L"Codex running in background",
      L"The window is hidden. Monitoring continues in the background. Double-click the tray icon to restore it, or use the tray menu to exit.",
      L"Test injection: quota alert", L"Test injection: turn alert"};
  return language == Language::en ? english : chinese;
}
}  // namespace ui_copy
#endif
