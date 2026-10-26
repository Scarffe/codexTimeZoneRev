#include <windows.h>
#include <shellapi.h>
#include <iostream>
#include <string>
#include <vector>

namespace {
std::vector<NOTIFYICONDATAW> notifications;
BOOL NativeCaptureNotification(DWORD operation, PNOTIFYICONDATAW icon) {
  if (operation == NIM_MODIFY && (icon->uFlags & NIF_INFO))
    notifications.push_back(*icon);
  return TRUE;
}
}
// Keep the real native producers/state transitions, replacing only the OS
// delivery boundary so an unattended regression never emits desktop notices.
#define Shell_NotifyIconW NativeCaptureNotification
#include "../desktop_prototype.cpp"
#undef Shell_NotifyIconW

namespace {
int failures = 0;
void Check(bool condition, const char* name) {
  std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
  if (!condition) ++failures;
}
void SelectLanguage(HWND window, const std::string& code) {
  desktop_prototype::ConfigureUiLanguage(window, code);
}
std::wstring Title(HWND window) {
  wchar_t text[256]{};
  GetWindowTextW(window, text, 256);
  return text;
}
}
int main() {
  const auto foreground = GetForegroundWindow();
  HWND window = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, L"STATIC",
      L"Codex 时区启动器", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!window) return 2;
  desktop_prototype::State state;
  state.mainWindow = state.owner = window;
  state.live = state.production = state.keepAlive = true;
  state.alertSerial = 4;
  state.sessionAlertSerial = 7;
  state.attentionAlertSerial = 9;
  state.preferencesSerial = 12;
  state.notificationSerial = 13;
  state.notificationAttempts = 2;
  state.notificationText = L"Human alias 原文 /some/path";
  state.pendingNotificationRoute = "attentionDetails";
  desktop_prototype::current = &state;
  SelectLanguage(window, "en");
  Check(Title(window) == L"Codex Time Zone Launcher", "English updates owned HWND display title");
  Check(state.alertSerial == 4 && state.sessionAlertSerial == 7 &&
      state.attentionAlertSerial == 9 && state.preferencesSerial == 12 &&
      state.notificationSerial == 13 && state.notificationAttempts == 2 &&
      notifications.empty(), "language selection never advances or delivers a notification");
  Check(state.notificationText == L"Human alias 原文 /some/path" &&
      state.pendingNotificationRoute == "attentionDetails", "language selection preserves old notice data and route");
  desktop_prototype::HideMonitorMain();
  Check(notifications.size() == 1 &&
      std::wstring(notifications.back().szInfoTitle) == L"Codex running in background" &&
      std::wstring(notifications.back().szInfo) ==
          L"The window is hidden. Monitoring continues in the background. Double-click the tray icon to restore it, or use the tray menu to exit.",
      "new background notice uses English title and native fixed body");
  const auto count = notifications.size();
  const auto serial = state.notificationSerial;
  SelectLanguage(window, "zh");
  SelectLanguage(window, "en");
  desktop_prototype::ConfigureSessionAlert(L"过期回合文本", 7);
  desktop_prototype::ConfigureAttentionAlert(L"过期收件箱文本", 9, 2);
  desktop_prototype::PublishMonitor(L"Human alias 原文", 40, false, false,
      2, 0, 0, L"/some/path", L"old quota", 4);
  Check(notifications.size() == count && state.notificationSerial == serial,
        "switching languages and republishing old serials never replays notices");
  desktop_prototype::Notify(L"User body 原文 /some/path", "quota", 14, "monitorDetails");
  Check(std::wstring(notifications.back().szInfoTitle) == L"Codex quota alert" &&
      std::wstring(notifications.back().szInfo) == L"User body 原文 /some/path",
      "quota title is localized while caller body remains untouched");
  desktop_prototype::Notify(L"Original session title", "attention", 15, "attentionDetails");
  Check(std::wstring(notifications.back().szInfoTitle) == L"Codex turn alert",
        "attention uses English turn alert title");
  SelectLanguage(window, "unsupported");
  desktop_prototype::Notify(L"用户文本", "session", 16, "sessionDetails");
  Check(Title(window) == L"Codex 时区启动器" &&
      std::wstring(notifications.back().szInfoTitle) == L"Codex 回合提醒",
      "unsupported language falls back to Chinese title and notices");
  Check(!IsWindowVisible(window) && GetForegroundWindow() == foreground,
        "language changes keep owned hidden fixture hidden and preserve foreground");
  desktop_prototype::current = nullptr;
  DestroyWindow(window);
  std::cout << "failures=" << failures << '\n';
  return failures ? 1 : 0;
}
