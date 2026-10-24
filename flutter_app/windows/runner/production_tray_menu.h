#ifndef RUNNER_PRODUCTION_TRAY_MENU_H_
#define RUNNER_PRODUCTION_TRAY_MENU_H_

#include <windows.h>

namespace production_tray {
// Supplied by the existing owner; its WM_COMMAND dispatch remains authoritative.
struct Commands { UINT open, refresh, pause, exit; };

inline HMENU Build(const Commands& commands, bool paused) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return nullptr;
  const bool complete =
      AppendMenuW(menu, MF_STRING, commands.open, L"打开主窗口") &&
      AppendMenuW(menu, MF_STRING, commands.refresh, L"立即刷新额度") &&
      AppendMenuW(menu, MF_STRING | (paused ? 0 : MF_CHECKED), commands.pause, L"自动刷新") &&
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) &&
      AppendMenuW(menu, MF_STRING, commands.exit, L"退出程序");
  if (!complete) { DestroyMenu(menu); return nullptr; }
  return menu;
}
}  // namespace production_tray

#endif  // RUNNER_PRODUCTION_TRAY_MENU_H_
