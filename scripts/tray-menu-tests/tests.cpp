#include "production_tray_menu.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace {
int checks = 0, failures = 0;
void Check(bool value, const char* name) {
  ++checks;
  if (!value) { ++failures; std::cerr << "FAIL: " << name << '\n'; }
}
const production_tray::Commands commands{104, 105, 106, 103};
const UINT ids[] = {104, 105, 106, 0, 103};
const wchar_t* labels[] = {L"打开主窗口", L"立即刷新额度", L"自动刷新", L"", L"退出程序"};
MENUITEMINFOW Info(HMENU menu, UINT index) {
  MENUITEMINFOW item{}; item.cbSize = sizeof(item);
  item.fMask = MIIM_ID | MIIM_FTYPE | MIIM_STATE | MIIM_DATA;
  Check(GetMenuItemInfoW(menu, index, TRUE, &item) != FALSE, "native item query succeeds");
  return item;
}
COLORREF Color(std::uint32_t argb) { return RGB((argb >> 16) & 255, (argb >> 8) & 255, argb & 255); }
struct Surface {
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP bitmap = nullptr;
  HGDIOBJ old = nullptr;
  void* pixels = nullptr;
  int width, height;
  Surface(int w, int h) : width(w), height(h) {
    BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w; info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (bitmap) old = SelectObject(dc, bitmap);
  }
  ~Surface() { if (old) SelectObject(dc, old); if (bitmap) DeleteObject(bitmap); if (dc) DeleteDC(dc); }
};
bool SavePng(const Surface& surface, const std::filesystem::path& path) {
  using Microsoft::WRL::ComPtr;
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return false;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  if (FAILED(factory->CreateStream(&stream)) || FAILED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, nullptr)) || FAILED(frame->Initialize(nullptr)) ||
      FAILED(frame->SetSize(surface.width, surface.height))) return false;
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame->SetPixelFormat(&format)) || format != GUID_WICPixelFormat32bppBGRA) return false;
  auto* bytes = static_cast<BYTE*>(surface.pixels);
  for (int i = 3; i < surface.width * surface.height * 4; i += 4) bytes[i] = 255;
  if (FAILED(frame->WritePixels(surface.height, surface.width * 4, surface.width * surface.height * 4,
                               static_cast<BYTE*>(surface.pixels)))) return false;
  return SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
}
MEASUREITEMSTRUCT Measure(HMENU menu, UINT index) {
  const auto item = Info(menu, index);
  MEASUREITEMSTRUCT measured{}; measured.CtlType = ODT_MENU;
  measured.itemID = item.wID; measured.itemData = item.dwItemData;
  Check(production_tray::StyledMenu::Measure(&measured), "registered native item measures");
  return measured;
}
DRAWITEMSTRUCT DrawInfo(HMENU menu, UINT index, HDC dc, RECT row, UINT state) {
  const auto item = Info(menu, index);
  DRAWITEMSTRUCT draw{}; draw.CtlType = ODT_MENU; draw.itemID = item.wID;
  draw.itemData = item.dwItemData; draw.hwndItem = reinterpret_cast<HWND>(menu);
  draw.hDC = dc; draw.rcItem = row; draw.itemAction = ODA_DRAWENTIRE; draw.itemState = state;
  return draw;
}
int CountColor(HDC dc, const RECT& rect, COLORREF color) {
  int count = 0;
  for (int y = rect.top; y < rect.bottom; ++y)
    for (int x = rect.left; x < rect.right; ++x) if (GetPixel(dc, x, y) == color) ++count;
  return count;
}
void MenuContract() {
  for (bool paused : {false, true}) {
    production_tray::StyledMenu owner(commands, paused);
    const auto menu = owner.get();
    Check(menu && owner.styled(), "real themed native popup allocated without display");
    if (!menu) continue;
    Check(GetMenuItemCount(menu) == 5, "four actions and one separator only");
    for (UINT index = 0; index < 5; ++index) {
      const auto item = Info(menu, index);
      wchar_t text[128]{}; GetMenuStringW(menu, index, text, 128, MF_BYPOSITION);
      Check(item.wID == ids[index], "command mapping and order preserved");
      Check(std::wstring(text) == labels[index], "accessible MIIM_STRING label retained");
      Check(((item.fType & MFT_SEPARATOR) != 0) == (index == 3), "single separator immediately before exit");
      Check((item.fType & MFT_OWNERDRAW) != 0, "theme menu actions use owner draw");
      if (index != 3) Check((item.fState & (MFS_DISABLED | MFS_GRAYED)) == 0, "all four actions remain enabled");
      Check(((item.fState & MFS_CHECKED) != 0) == (index == 2 && !paused), "autorefresh check tracks enabled state");
      const auto* accessibility = reinterpret_cast<const MSAAMENUINFO*>(item.dwItemData);
      Check(accessibility && accessibility->dwMSAASignature == MSAA_MENU_SIG, "MSAA menu signature is first data member");
      Check(accessibility && accessibility->cchWText == wcslen(labels[index]) &&
            std::wstring(accessibility->pszWText) == labels[index], "MSAA accessible label and length retained");
    }
  }
  production_tray::StyledMenu fallback(commands, false, {}, 96, true);
  Check(fallback.get() && !fallback.styled(), "system fallback creates usable ordinary HMENU");
  for (UINT index = 0; index < 5; ++index) {
    const auto item = Info(fallback.get(), index);
    Check(!(item.fType & MFT_OWNERDRAW) && item.dwItemData == 0, "system fallback has no custom item callbacks");
    wchar_t text[128]{}; GetMenuStringW(fallback.get(), index, text, 128, MF_BYPOSITION);
    Check(item.wID == ids[index] && std::wstring(text) == labels[index], "system fallback preserves routes and labels");
  }
  Check(production_tray::IsArgb(0) && production_tray::IsArgb(0xffffffffLL), "ARGB accepts unsigned bounds");
  Check(!production_tray::IsArgb(-1) && !production_tray::IsArgb(0x100000000LL), "ARGB rejects out of range input");
}
void ForeignMessages() {
  MEASUREITEMSTRUCT stale{}; HMENU destroyed = nullptr;
  {
    production_tray::StyledMenu owner(commands, false);
    destroyed = owner.get(); stale = Measure(owner.get(), 0);
    auto wrong = stale; wrong.itemData = 1;
    Check(!production_tray::StyledMenu::Measure(&wrong), "foreign invalid address rejected before dereference");
    wrong = stale; wrong.CtlType = ODT_BUTTON;
    Check(!production_tray::StyledMenu::Measure(&wrong), "non-menu control message rejected");
    wrong = stale; wrong.itemID = 999;
    Check(!production_tray::StyledMenu::Measure(&wrong), "registered data with mismatched command rejected");
    Surface surface(176, 28);
    auto draw = DrawInfo(owner.get(), 0, surface.dc, {0,0,176,28}, 0);
    draw.hwndItem = reinterpret_cast<HWND>(static_cast<ULONG_PTR>(1));
    Check(!production_tray::StyledMenu::Draw(&draw), "foreign HMENU rejected");
    draw.hwndItem = reinterpret_cast<HWND>(owner.get()); draw.itemData = 1;
    Check(!production_tray::StyledMenu::Draw(&draw), "foreign draw data rejected before dereference");
    draw.itemData = stale.itemData; draw.itemID = 999;
    Check(!production_tray::StyledMenu::Draw(&draw), "draw command must match registered data");
  }
  Check(!IsMenu(destroyed), "RAII destroys native HMENU");
  Check(!production_tray::StyledMenu::Measure(&stale), "dismissed item callback is unregistered");
  Check(!production_tray::StyledMenu::Measure(nullptr) && !production_tray::StyledMenu::Draw(nullptr), "null messages rejected");
}
void PaintContract(const std::filesystem::path& output) {
  const production_tray::Appearance palettes[] = {
    // Literal current DashboardPalette roles: panel/selected/accent/danger/text/border.
    {0xfff0f3f0,0xffd6e3e5,0xff356d7d,0xffad5060,0xff273b3d,0xffc6d1cd},
    {0xff232d31,0xff31484f,0xff8ab7c5,0xffe7a1ae,0xffd5e0df,0xff40504f}};
  for (int theme = 0; theme < 2; ++theme) for (UINT dpi : {96u,144u,192u}) {
    const auto& palette = palettes[theme];
    production_tray::StyledMenu owner(commands, false, palette, dpi);
    const auto measured = Measure(owner.get(), 0);
    const int rowHeight = dpi == 96 ? 28 : dpi == 144 ? 42 : 56;
    const int separatorHeight = dpi == 96 ? 8 : dpi == 144 ? 12 : 16;
    const int width = static_cast<int>(measured.itemWidth);
    const int gap = MulDiv(16,dpi,96), totalHeight = rowHeight * 4 + separatorHeight;
    Check(measured.itemHeight == static_cast<UINT>(rowHeight), "compact logical 28px row scales at owner DPI");
    Check(width >= MulDiv(176,dpi,96) && width <= MulDiv(260,dpi,96), "measured label width stays in target bounds");
    Check(Measure(owner.get(),3).itemHeight == static_cast<UINT>(separatorHeight), "compact separator scales at DPI");
    Surface surface(width * 2 + gap, totalHeight);
    Check(surface.dc && surface.bitmap && surface.pixels, "offscreen memory DIB allocated");
    RECT all{0,0,surface.width,surface.height}; FillRect(surface.dc, &all, GetSysColorBrush(COLOR_WINDOW));
    for (int column = 0; column < 2; ++column) {
      int top = 0;
      for (UINT index = 0; index < 5; ++index) {
        const int height = index == 3 ? separatorHeight : rowHeight;
        const int left = column * (width + gap);
        UINT state = column ? ODS_DISABLED | ODS_GRAYED : index == 1 ? ODS_SELECTED | ODS_FOCUS : index == 2 ? ODS_CHECKED : 0;
        RECT row{left,top,left+width,top+height};
        auto draw = DrawInfo(owner.get(),index,surface.dc,row,state);
        Check(production_tray::StyledMenu::Draw(&draw), "native draw paints actual menu item into memory DC");
        Check(GetPixel(surface.dc,left+width/2,top+height-1) == Color(index == 4 ? palette.border : palette.surface), "row paints supplied theme surface");
        if (!column && index == 1)
          Check(GetPixel(surface.dc,left+width/2,top+MulDiv(4,dpi,96)) == Color(palette.selected), "selected inset paints theme selection token");
        if (!column && index == 2)
          Check(CountColor(surface.dc,row,Color(palette.accent)) > 0, "checked automatic refresh paints visible theme accent");
        if (!column && index == 4)
          Check(CountColor(surface.dc,row,Color(palette.danger)) > 0, "exit paints supplied subtle danger token");
        if (column && index != 3)
          Check(CountColor(surface.dc,row,Color(palette.text)) == 0, "disabled items do not paint enabled foreground");
        top += height;
      }
    }
    if (!output.empty()) {
      auto path = output / (std::string("task3-offscreen-") + (theme ? "dark-" : "light-") + std::to_string(dpi) + "dpi.png");
      Check(SavePng(surface,path), "actual GDI offscreen paint saved as PNG");
    }
  }
}
void ResourceContract() {
  // Warm font/GDI process caches before measuring our per-menu resources.
  for (int i = 0; i < 3; ++i) {
    production_tray::StyledMenu menu(commands,false);
    production_tray::StyledMenu nested(commands,false,{},144);
    Measure(menu.get(),0); Measure(nested.get(),0);
  }
  GdiFlush();
  const DWORD gdi = GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS);
  const DWORD user = GetGuiResources(GetCurrentProcess(),GR_USEROBJECTS);
  for (int i = 0; i < 100; ++i) {
    production_tray::StyledMenu menu(commands, i % 2 != 0);
    Check(menu.get() && menu.styled(), "repeated allocation remains styled");
    production_tray::StyledMenu nested(commands,false,{},144);
    Check(Measure(menu.get(),0).itemHeight == 28 && Measure(nested.get(),0).itemHeight == 42, "multiple live menus retain separate registered measurements");
  }
  GdiFlush();
  const auto afterGdi = GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS);
  std::cout << "GDI objects before=" << gdi << " after=" << afterGdi << '\n';
  Check(afterGdi == gdi, "100 menu lifetimes release all GDI fonts and brushes");
  Check(GetGuiResources(GetCurrentProcess(),GR_USEROBJECTS) == user, "100 menu lifetimes release USER menu handles");
}
}
int wmain(int argc, wchar_t** argv) {
  const HRESULT com = CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
  Check(SUCCEEDED(com), "offscreen PNG encoder COM initialized");
  const std::filesystem::path output = argc > 1 ? argv[1] : L"";
  if (!output.empty()) std::filesystem::create_directories(output);
  MenuContract(); ForeignMessages(); PaintContract(output); ResourceContract();
  if (SUCCEEDED(com)) CoUninitialize();
  std::cout << checks << " checks, " << failures << " failures\n";
  return failures ? 1 : 0;
}
