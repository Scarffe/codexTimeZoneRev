#ifndef RUNNER_PRODUCTION_TRAY_MENU_H_
#define RUNNER_PRODUCTION_TRAY_MENU_H_
#include <windows.h>
#include <oleacc.h>
#include <array>
#include <cstdint>
#include "ui_copy.h"

namespace production_tray {
struct Commands { UINT open, refresh, pause, exit; };
struct Appearance {
  std::uint32_t surface = 0xfff0f3f0, selected = 0xffd6e3e5;
  std::uint32_t accent = 0xff326b74, danger = 0xffae3541;
  std::uint32_t text = 0xff202833, border = 0xffd0d9d7;
};
bool IsArgb(std::int64_t value);
// Native popup mechanics and command dispatch remain with TrackPopupMenu.
// This stack owner outlives the menu loop and all MSAA item/name pointers.
class StyledMenu final {
 public:
  StyledMenu(const Commands& commands, bool paused,
             const Appearance& appearance = {}, UINT dpi = 96,
             bool use_system_menu = false,
             ui_copy::Language language = ui_copy::Language::zh);
  ~StyledMenu();
  StyledMenu(const StyledMenu&) = delete;
  StyledMenu& operator=(const StyledMenu&) = delete;
  HMENU get() const { return menu_; }
  bool styled() const { return styled_; }
  static bool Measure(MEASUREITEMSTRUCT* measure);
  static bool Draw(DRAWITEMSTRUCT* draw);
 private:
  struct Item {
    MSAAMENUINFO accessibility;  // MSAA contract: MUST be the first member.
    UINT command;
    const wchar_t* label;
    bool separator;
    StyledMenu* owner;
  };
  static Item* Registered(ULONG_PTR data, UINT command);
  bool Create(const Commands& commands, bool paused, bool styled);
  void Release();
  int Scale(int logical) const;
  HMENU menu_ = nullptr;
  HFONT font_ = nullptr;
  HBRUSH surface_ = nullptr, selection_ = nullptr, border_ = nullptr;
  Appearance appearance_;
  UINT dpi_;
  ui_copy::Language language_;
  UINT width_ = 0;
  bool styled_ = false;
  std::array<Item, 5> items_{};
  StyledMenu* next_ = nullptr;
  static thread_local StyledMenu* registered_;
};
}  // namespace production_tray
#endif
