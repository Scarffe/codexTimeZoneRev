#include "production_tray_menu.h"
#include <iostream>
#include <string>

namespace {
int checks = 0, failures = 0;
void Check(bool value, const char* name) {
  ++checks;
  if (!value) { ++failures; std::cerr << "FAIL: " << name << '\n'; }
}
}

int main() {
  // Existing runner IDs are deliberately passed through, never renumbered.
  const production_tray::Commands commands{104, 105, 106, 103};
  for (const bool paused : {false, true}) {
    HMENU menu = production_tray::Build(commands, paused);
    Check(menu != nullptr, "real native popup menu allocated without display");
    if (!menu) continue;
    Check(GetMenuItemCount(menu) == 5, "four actions and one separator only");
    const UINT ids[] = {104, 105, 106, 0, 103};
    const wchar_t* labels[] = {L"打开主窗口", L"立即刷新额度", L"自动刷新", L"", L"退出程序"};
    for (UINT index = 0; index < 5; ++index) {
      wchar_t text[128]{};
      MENUITEMINFOW item{};
      item.cbSize = sizeof(item);
      item.fMask = MIIM_ID | MIIM_FTYPE | MIIM_STATE | MIIM_STRING;
      item.dwTypeData = text;
      item.cch = 128;
      Check(GetMenuItemInfoW(menu, index, TRUE, &item) != FALSE, "native item query succeeds");
      Check(item.wID == ids[index], "command mapping and order preserved");
      Check(std::wstring(text) == labels[index], "concise native action label");
      Check(((item.fType & MFT_SEPARATOR) != 0) == (index == 3), "single separator immediately before exit");
      if (index != 3) Check((item.fState & (MFS_DISABLED | MFS_GRAYED)) == 0, "all four actions enabled with no disabled status row");
      Check(((item.fState & MFS_CHECKED) != 0) == (index == 2 && !paused), "autorefresh check tracks enabled state");
    }
    Check(DestroyMenu(menu) != FALSE, "native menu released");
  }
  std::cout << checks << " checks, " << failures << " failures\n";
  return failures ? 1 : 0;
}
