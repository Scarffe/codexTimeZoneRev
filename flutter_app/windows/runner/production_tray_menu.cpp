#include "production_tray_menu.h"
#include <algorithm>
#include <cstddef>
#include <cwchar>
#include <type_traits>

namespace production_tray {
namespace {
COLORREF Color(std::uint32_t argb) {
  return RGB((argb >> 16) & 255, (argb >> 8) & 255, argb & 255);
}
bool HighContrast() {
  HIGHCONTRASTW contrast{};
  contrast.cbSize = sizeof(contrast);
  // Unknown accessibility state is a reason to retain the system menu.
  return !SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) ||
         (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
}
}
thread_local StyledMenu* StyledMenu::registered_ = nullptr;
bool IsArgb(std::int64_t value) { return value >= 0 && value <= 0xffffffffLL; }
int StyledMenu::Scale(int logical) const { return MulDiv(logical, static_cast<int>(dpi_), 96); }

StyledMenu::StyledMenu(const Commands& commands, bool paused,
                       const Appearance& appearance, UINT dpi, bool use_system_menu,
                       ui_copy::Language language)
    : appearance_(appearance), dpi_(dpi ? dpi : 96), language_(language) {
  static_assert(std::is_standard_layout_v<Item>);
  static_assert(offsetof(Item, accessibility) == 0);
  bool ready = !use_system_menu && !HighContrast();
  if (ready) {
    // Match the system menu face but use a compact, DPI-scaled logical 12px font.
    NONCLIENTMETRICSW metrics{};
    metrics.cbSize = sizeof(metrics);
    ready = SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0) != FALSE;
    if (ready) {
      metrics.lfMenuFont.lfHeight = -Scale(12);
      font_ = CreateFontIndirectW(&metrics.lfMenuFont);
      surface_ = CreateSolidBrush(Color(appearance_.surface));
      selection_ = CreateSolidBrush(Color(appearance_.selected));
      border_ = CreateSolidBrush(Color(appearance_.border));
      ready = font_ && surface_ && selection_ && border_;
    }
  }
  if (ready && Create(commands, paused, true)) {
    styled_ = true;
    next_ = registered_;
    registered_ = this;
    return;
  }
  Release();
  if (!Create(commands, paused, false)) Release();
}
StyledMenu::~StyledMenu() {
  if (styled_) {
    auto** link = &registered_;
    while (*link && *link != this) link = &(*link)->next_;
    if (*link) *link = next_;
  }
  Release();
}
void StyledMenu::Release() {
  // DestroyMenu may still inspect item data and the background brush.
  if (menu_) { DestroyMenu(menu_); menu_ = nullptr; }
  if (font_) { DeleteObject(font_); font_ = nullptr; }
  if (surface_) { DeleteObject(surface_); surface_ = nullptr; }
  if (selection_) { DeleteObject(selection_); selection_ = nullptr; }
  if (border_) { DeleteObject(border_); border_ = nullptr; }
}
bool StyledMenu::Create(const Commands& commands, bool paused, bool styled) {
  menu_ = CreatePopupMenu();
  if (!menu_) return false;
  const UINT ids[] = {commands.open, commands.refresh, commands.pause, 0, commands.exit};
  const auto& copy = ui_copy::For(language_);
  const wchar_t* labels[] = {copy.menu_open, copy.menu_refresh, copy.menu_automatic, L"", copy.menu_exit};
  int widest = 0;
  if (styled) {
    HDC dc = CreateCompatibleDC(nullptr);
    if (!dc) return false;
    const auto old = SelectObject(dc, font_);
    bool measured = old && old != HGDI_ERROR;
    for (const auto* label : labels) {
      SIZE size{};
      if (!GetTextExtentPoint32W(dc, label, static_cast<int>(wcslen(label)), &size)) measured = false;
      widest = std::max(widest, static_cast<int>(size.cx));
    }
    if (old && old != HGDI_ERROR) SelectObject(dc, old);
    DeleteDC(dc);
    if (!measured) return false;
    width_ = static_cast<UINT>(std::clamp(widest + Scale(64), Scale(176), Scale(260)));
    MENUINFO info{};
    info.cbSize = sizeof(info);
    info.fMask = MIM_BACKGROUND | MIM_STYLE;
    info.hbrBack = surface_;
    info.dwStyle = MNS_NOCHECK;
    if (!SetMenuInfo(menu_, &info)) return false;
  }
  for (UINT i = 0; i < 5; ++i) {
    auto& entry = items_[i];
    entry.accessibility = {MSAA_MENU_SIG, static_cast<DWORD>(wcslen(labels[i])), const_cast<wchar_t*>(labels[i])};
    entry.command = ids[i]; entry.label = labels[i]; entry.separator = i == 3; entry.owner = this;
    MENUITEMINFOW item{};
    item.cbSize = sizeof(item);
    item.fMask = MIIM_ID | MIIM_FTYPE | MIIM_STATE;
    item.wID = ids[i];
    item.fType = (i == 3 ? MFT_SEPARATOR : MFT_STRING) | (styled ? MFT_OWNERDRAW : 0);
    item.fState = i == 2 && !paused ? MFS_CHECKED : MFS_UNCHECKED;
    if (i != 3) {
      item.fMask |= MIIM_STRING;
      item.dwTypeData = const_cast<wchar_t*>(labels[i]);
      item.cch = static_cast<UINT>(wcslen(labels[i]));
    }
    if (styled) { item.fMask |= MIIM_DATA; item.dwItemData = reinterpret_cast<ULONG_PTR>(&entry); }
    if (!InsertMenuItemW(menu_, i, TRUE, &item)) return false;
  }
  return true;
}
StyledMenu::Item* StyledMenu::Registered(ULONG_PTR data, UINT command) {
  // Never dereference data until it matches our live storage. Plugin messages
  // may carry arbitrary integers, stale pointers or their own owner-draw data.
  for (auto* menu = registered_; menu; menu = menu->next_) {
    for (auto& item : menu->items_) {
      if (data == reinterpret_cast<ULONG_PTR>(&item) && command == item.command) return &item;
    }
  }
  return nullptr;
}
bool StyledMenu::Measure(MEASUREITEMSTRUCT* measure) {
  if (!measure || measure->CtlType != ODT_MENU) return false;
  const auto* item = Registered(measure->itemData, measure->itemID);
  if (!item) return false;
  measure->itemWidth = item->owner->width_;
  measure->itemHeight = item->owner->Scale(item->separator ? 8 : 28);
  return true;
}
bool StyledMenu::Draw(DRAWITEMSTRUCT* draw) {
  if (!draw || draw->CtlType != ODT_MENU || !draw->hDC) return false;
  const auto* item = Registered(draw->itemData, draw->itemID);
  if (!item || reinterpret_cast<HMENU>(draw->hwndItem) != item->owner->menu_) return false;
  const auto& menu = *item->owner;
  const int saved = SaveDC(draw->hDC);
  if (!saved) return false;
  const auto px = [&](int value) { return menu.Scale(value); };
  const HDC dc = draw->hDC;
  RECT row = draw->rcItem;
  FillRect(dc, &row, menu.surface_);
  const bool disabled = (draw->itemState & (ODS_DISABLED | ODS_GRAYED)) != 0;
  const bool selected = (draw->itemState & ODS_SELECTED) != 0;
  if (item->separator) {
    RECT line{row.left + px(10), row.top + px(3), row.right - px(10), row.top + px(3) + px(1)};
    FillRect(dc, &line, menu.border_);
  } else {
    RECT inset = row; InflateRect(&inset, -px(4), -px(2));
    if (selected) {
      SelectObject(dc, GetStockObject(NULL_PEN));
      SelectObject(dc, menu.selection_);
      RoundRect(dc, inset.left, inset.top, inset.right, inset.bottom, px(8), px(8));
    }
    const auto color = disabled ? Color(menu.appearance_.border) :
        Color(item == &menu.items_[4] ? menu.appearance_.danger : menu.appearance_.text);
    SetBkMode(dc, TRANSPARENT); SetTextColor(dc, color); SelectObject(dc, menu.font_);
    RECT text = row; text.left += px(34); text.right -= px(28);
    DrawTextW(dc, item->label, -1, &text, DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX);
    SelectObject(dc, GetStockObject(DC_PEN)); SetDCPenColor(dc, color);
    SelectObject(dc, GetStockObject(NULL_BRUSH));
    const int x = row.left + px(13), y = (row.top + row.bottom) / 2 - px(5);
    const auto line = [&](int ax, int ay, int bx, int by) {
      MoveToEx(dc, x + px(ax), y + px(ay), nullptr); LineTo(dc, x + px(bx), y + px(by));
    };
    if (item == &menu.items_[0]) {
      Rectangle(dc, x, y, x + px(11), y + px(10)); line(0, 3, 11, 3);
    } else if (item == &menu.items_[1]) {
      Arc(dc, x, y, x + px(11), y + px(11), x + px(9), y + px(1), x + px(11), y + px(6));
      line(9, 1, 12, 1); line(12, 1, 12, 4);
    } else if (item == &menu.items_[2]) {
      Ellipse(dc, x, y, x + px(11), y + px(11)); line(5, 2, 5, 5); line(5, 5, 8, 7);
    } else {
      line(1, 0, 1, 10); line(1, 0, 5, 0); line(1, 10, 5, 10);
      line(5, 5, 12, 5); line(9, 2, 12, 5); line(12, 5, 9, 8);
    }
    if (draw->itemState & ODS_CHECKED) {
      SetDCPenColor(dc, disabled ? color : Color(menu.appearance_.accent));
      const int cx = row.right - px(21), cy = (row.top + row.bottom) / 2;
      MoveToEx(dc, cx, cy, nullptr); LineTo(dc, cx + px(3), cy + px(3)); LineTo(dc, cx + px(9), cy - px(4));
    }
    if ((draw->itemState & ODS_FOCUS) && !(draw->itemState & ODS_NOFOCUSRECT)) {
      InflateRect(&inset, -px(1), -px(1)); DrawFocusRect(dc, &inset);
    }
  }
  RECT left = row, right = row;
  left.right = left.left + px(1); right.left = right.right - px(1);
  FillRect(dc, &left, menu.border_); FillRect(dc, &right, menu.border_);
  if (item == &menu.items_.front() || item == &menu.items_.back()) {
    RECT edge = row;
    if (item == &menu.items_.front()) edge.bottom = edge.top + px(1);
    else edge.top = edge.bottom - px(1);
    FillRect(dc, &edge, menu.border_);
  }
  RestoreDC(dc, saved);
  return true;
}
}  // namespace production_tray
