#include <windows.h>
#include <iostream>
#include <memory>
#include <string>
#include "../production_tray_menu.h"

#include "../ui_copy.h"

namespace {
int failures = 0;
void Check(bool condition, const char* name) {
  std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
  if (!condition) ++failures;
}
void CheckMenu(const std::string& code, bool paused, bool system) {
  const production_tray::Commands commands{104, 105, 106, 103};
  production_tray::StyledMenu menu(commands, paused, {}, 144, system,
                                   ui_copy::ParseLanguage(code));
  Check(menu.get() && GetMenuItemCount(menu.get()) == 5,
        "exactly four commands and one separator");
  const wchar_t* english[] = {L"Open main window", L"Refresh quota now",
      L"Automatic refresh", L"", L"Exit application"};
  const wchar_t* chinese[] = {L"打开主窗口", L"立即刷新额度", L"自动刷新", L"", L"退出程序"};
  const UINT ids[] = {104, 105, 106, 0, 103};
  for (UINT i = 0; i != 5; ++i) {
    wchar_t text[128]{};
    MENUITEMINFOW item{};
    item.cbSize = sizeof(item);
    item.fMask = MIIM_ID | MIIM_STATE | MIIM_FTYPE | MIIM_STRING | MIIM_DATA;
    item.dwTypeData = text; item.cch = 128;
    const bool read = GetMenuItemInfoW(menu.get(), i, TRUE, &item) != FALSE;
    Check(read && item.wID == ids[i], "localized menu retains command ID");
    Check(read && std::wstring(text) == (code == "en" ? english[i] : chinese[i]),
          "localized menu exposes readable label");
    Check(read && ((item.fType & MFT_SEPARATOR) != 0) == (i == 3), "separator is not an action");
    Check(read && ((item.fState & MFS_CHECKED) != 0) == (i == 2 && !paused),
          "only enabled automatic refresh is checked");
    if (menu.styled()) {
      const auto* accessible = reinterpret_cast<const MSAAMENUINFO*>(item.dwItemData);
      Check(accessible && accessible->dwMSAASignature == MSAA_MENU_SIG &&
          std::wstring(accessible->pszWText) == (code == "en" ? english[i] : chinese[i]),
          "owner-drawn menu exposes the same localized accessible name");
      MEASUREITEMSTRUCT measure{};
      measure.CtlType = ODT_MENU; measure.itemID = item.wID; measure.itemData = item.dwItemData;
      Check(production_tray::StyledMenu::Measure(&measure) && measure.itemWidth >= 264,
            "localized owner-drawn item keeps a DPI-scaled measured width");
    }
  }
  if (system) Check(!menu.styled(), "system fallback retains native mechanics");
}
}
int main() {
  const auto foreground = GetForegroundWindow();
  for (const auto* code : {"zh", "en", "unsupported"})
    for (bool paused : {false, true})
      for (bool system : {false, true}) CheckMenu(code, paused, system);
  Check(GetForegroundWindow() == foreground, "menu construction never foregrounds any window");
  std::cout << "failures=" << failures << '\n';
  return failures ? 1 : 0;
}
