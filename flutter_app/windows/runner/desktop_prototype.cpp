#include "desktop_prototype.h"
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <vector>

namespace desktop_prototype {
namespace {
constexpr wchar_t kOwnerClass[] = L"CodexTimeZone.StageA.Owner";
constexpr wchar_t kPetClass[] = L"CodexTimeZone.StageA.Pet";
constexpr wchar_t kHostClass[] = L"CodexTimeZone.StageA.TestHost";
constexpr UINT kTray = WM_APP + 71;
constexpr UINT kRestore = WM_APP + 72;
constexpr int kWidth = 240, kHeight = 160;
constexpr UINT kShow = 100, kHide = 101, kReset = 102, kExit = 103;
struct State {
  HWND owner = nullptr, pet = nullptr, host = nullptr;
  bool tray = false, dragging = false;
  POINT drag{};
  int petClicks = 0, hostClicks = 0, restores = 0;
  std::filesystem::path report;
  UINT taskbarCreated = 0;
};
State* current = nullptr;  // All callbacks execute on this UI thread.

std::wstring Suffix() {
  wchar_t path[32768]{};
  GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
  // Path-scoped identity isolates the prototype from installed launchers.
  std::uint64_t hash = 14695981039346656037ULL;
  for (const auto ch : std::wstring(path)) {
    hash ^= static_cast<std::uint64_t>(towlower(ch)); hash *= 1099511628211ULL;
  }
  DWORD session = 0; ProcessIdToSessionId(GetCurrentProcessId(), &session);
  return std::to_wstring(session) + L"." + std::to_wstring(hash);
}

void Report() {
  auto& s = *current;
  if (s.report.empty()) return;
  RECT r{}; GetWindowRect(s.pet, &r);
  DWORD foregroundPid = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &foregroundPid);
  const auto temporary = s.report.wstring() + L".tmp";
  {
    std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
    out << "{\"pid\":" << GetCurrentProcessId()
        << ",\"petClicks\":" << s.petClicks << ",\"hostClicks\":" << s.hostClicks
        << ",\"restores\":" << s.restores << ",\"tray\":" << (s.tray ? "true" : "false")
        << ",\"visible\":" << (IsWindowVisible(s.pet) ? "true" : "false")
        << ",\"foregroundPid\":" << foregroundPid
        << ",\"hostForeground\":" << (GetForegroundWindow() == s.host ? "true" : "false")
        << ",\"petForeground\":" << (GetForegroundWindow() == s.pet ? "true" : "false")
        << ",\"petRect\":[" << r.left << ',' << r.top << ',' << r.right << ',' << r.bottom << "]}";
  }
  MoveFileExW(temporary.c_str(), s.report.c_str(), MOVEFILE_REPLACE_EXISTING);
}

bool InstallTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = current->owner;
  icon.uID = 1; icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTray; icon.hIcon = LoadIconW(nullptr, IDI_INFORMATION);
  wcscpy_s(icon.szTip, L"Codex Stage A | DEMO 72% left | no account queries");
  current->tray = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  return current->tray;
}

void ResetPosition() {
  RECT area{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0);
  int x = area.right - kWidth - 32, y = area.bottom - kHeight - 48;
  if (current->host) {
    RECT host{}; GetWindowRect(current->host, &host); x = host.left + 100; y = host.top + 100;
  }
  SetWindowPos(current->pet, HWND_TOPMOST, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
}

bool DrawPet() {
  // A real premultiplied-alpha DIB: zero-alpha pixels are not mouse targets.
  // Original geometric placeholder; no downloaded character assets.
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = kWidth; info.bmiHeader.biHeight = -kHeight;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!screen || !dc || !bitmap || !pixels) {
    if (bitmap) DeleteObject(bitmap); if (dc) DeleteDC(dc); if (screen) ReleaseDC(nullptr, screen);
    return false;
  }
  auto data = static_cast<std::uint32_t*>(pixels);
  for (int y = 0; y < kHeight; ++y) for (int x = 0; x < kWidth; ++x) {
    const auto ellipse = [](int px, int py, int cx, int cy, int rx, int ry) {
      const double dx = static_cast<double>(px - cx) / rx;
      const double dy = static_cast<double>(py - cy) / ry; return dx * dx + dy * dy <= 1;
    };
    std::uint32_t color = 0;
    if (ellipse(x,y,118,94,66,43) || ellipse(x,y,54,74,24,14) || ellipse(x,y,53,103,21,13)) color = 0xff66bfe8;
    if (ellipse(x,y,131,112,41,17)) color = 0xffcbeaf4;
    if (ellipse(x,y,150,85,5,7)) color = 0xff182d49;
    // Small quota gauge; all displayed values are fixture data.
    if (x >= 77 && x <= 174 && y >= 141 && y <= 147) color = x < 147 ? 0xff6bd4ad : 0xff43526b;
    data[y * kWidth + x] = color;
  }
  auto old = SelectObject(dc, bitmap);
  SIZE size{kWidth,kHeight}; POINT source{}; RECT r{}; GetWindowRect(current->pet, &r);
  POINT destination{r.left,r.top}; BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
  const bool ok = UpdateLayeredWindow(current->pet, screen, &destination, &size, dc,
                                      &source, 0, &blend, ULW_ALPHA) != FALSE;
  SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr, screen);
  return ok;
}

void ShowPet() {
  ShowWindow(current->pet, SW_SHOWNOACTIVATE);
  SetWindowPos(current->pet, HWND_TOPMOST, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
  Report();
}

LRESULT CALLBACK PetProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto& s = *current;
  switch (msg) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_LBUTTONDOWN: {
      ++s.petClicks; s.dragging = true; GetCursorPos(&s.drag); SetCapture(hwnd); Report(); return 0;
    }
    case WM_MOUSEMOVE:
      if (s.dragging) {
        POINT p{}; GetCursorPos(&p); RECT r{}; GetWindowRect(hwnd,&r);
        SetWindowPos(hwnd,HWND_TOPMOST,r.left+p.x-s.drag.x,r.top+p.y-s.drag.y,0,0,SWP_NOSIZE|SWP_NOACTIVATE);
        s.drag=p;
      } return 0;
    case WM_LBUTTONUP: s.dragging=false; ReleaseCapture(); Report(); return 0;
    case WM_CAPTURECHANGED: s.dragging=false; return 0;
    case WM_RBUTTONUP: PostMessageW(s.owner,kTray,0,WM_RBUTTONUP); return 0;
    case WM_CLOSE: ShowWindow(hwnd,SW_HIDE); Report(); return 0;
  }
  return DefWindowProcW(hwnd,msg,wp,lp);
}

LRESULT CALLBACK HostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_LBUTTONDOWN: ++current->hostClicks; Report(); InvalidateRect(hwnd,nullptr,TRUE); return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{}; HDC dc=BeginPaint(hwnd,&paint); RECT rect{}; GetClientRect(hwnd,&rect);
      FillRect(dc,&rect,reinterpret_cast<HBRUSH>(COLOR_WINDOW+1));
      SetBkMode(dc,TRANSPARENT);
      std::wstring text=L"Stage A INPUT TEST HOST (fixture data only)\n\n"
          L"Blue whale: click/drag without activating it.\n"
          L"Empty pixels inside its rectangle: clicks reach this host.\n"
          L"Tray: show / hide / reset / exit. No Codex operations.\n\nHost clicks: " + std::to_wstring(current->hostClicks);
      rect.left+=16; rect.top+=16; DrawTextW(dc,text.c_str(),-1,&rect,DT_LEFT|DT_TOP);
      EndPaint(hwnd,&paint); return 0;
    }
    case WM_CLOSE: ShowWindow(hwnd,SW_HIDE); return 0;
  }
  return DefWindowProcW(hwnd,msg,wp,lp);
}

LRESULT CALLBACK OwnerProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto& s=*current;
  if (msg == s.taskbarCreated && s.taskbarCreated) { InstallTray(); return 0; }
  if (msg == kRestore) { ++s.restores; ShowPet(); return 0; }
  switch (msg) {
    case WM_TIMER: Report(); return 0;
    case kTray:
      if (lp == WM_LBUTTONUP || lp == WM_LBUTTONDBLCLK) { ShowPet(); return 0; }
      if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU) {
        HMENU menu=CreatePopupMenu();
        AppendMenuW(menu,MF_STRING,kShow,L"Show pet (DEMO)");
        AppendMenuW(menu,MF_STRING,kHide,L"Hide pet");
        AppendMenuW(menu,MF_STRING,kReset,L"Reset position");
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        AppendMenuW(menu,MF_STRING,kExit,L"Exit Stage A prototype");
        POINT p{}; GetCursorPos(&p);
        // Menus require foreground ownership; ordinary pet show/click never does.
        SetForegroundWindow(hwnd);
        auto command=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,p.x,p.y,0,hwnd,nullptr);
        DestroyMenu(menu); PostMessageW(hwnd,WM_NULL,0,0);
        if (command) PostMessageW(hwnd,WM_COMMAND,command,0);
      } return 0;
    case WM_COMMAND:
      switch (LOWORD(wp)) {
        case kShow: ShowPet(); break;
        case kHide: ShowWindow(s.pet,SW_HIDE); Report(); break;
        case kReset: ResetPosition(); ShowPet(); break;
        case kExit: DestroyWindow(hwnd); break;
      } return 0;
    case WM_CLOSE: DestroyWindow(hwnd); return 0;
    case WM_DESTROY: {
      NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=hwnd; icon.uID=1;
      if (s.tray) Shell_NotifyIconW(NIM_DELETE,&icon);
      KillTimer(hwnd,1); PostQuitMessage(0); return 0;
    }
  }
  return DefWindowProcW(hwnd,msg,wp,lp);
}

bool Register(const wchar_t* name,WNDPROC proc) {
  WNDCLASSW cls{}; cls.lpfnWndProc=proc; cls.hInstance=GetModuleHandleW(nullptr);
  cls.lpszClassName=name; cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);
  return RegisterClassW(&cls) || GetLastError()==ERROR_CLASS_ALREADY_EXISTS;
}
}

bool Requested(const std::vector<std::wstring>& args) {
  return std::find(args.begin(),args.end(),L"--desktop-prototype")!=args.end();
}

int Run(const std::vector<std::wstring>& args) {
  const auto identity=Suffix();
  const auto ownerTitle=L"CodexTimeZone.StageA."+identity;
  HANDLE mutex=CreateMutexW(nullptr,FALSE,(L"Local\\CodexTimeZone.StageA."+identity).c_str());
  if (!mutex) return 2;
  const bool existing=GetLastError()==ERROR_ALREADY_EXISTS;
  if (existing) {
    // The package-bootstrap parent never owns this mutex. Only the final UI does.
    HWND owner=nullptr;
    for (int i=0;i<40 && !owner;++i) { owner=FindWindowW(kOwnerClass,ownerTitle.c_str()); if(!owner) Sleep(50); }
    if(owner) PostMessageW(owner,kRestore,0,0);
    CloseHandle(mutex); return owner ? 0 : 3;
  }
  State state{}; current=&state;
  for (const auto& arg:args) {
    constexpr wchar_t prefix[]=L"--prototype-report=";
    if(arg.rfind(prefix,0)==0) state.report=arg.substr(std::size(prefix)-1);
  }
  state.taskbarCreated=RegisterWindowMessageW(L"TaskbarCreated");
  if (!Register(kOwnerClass,OwnerProc)||!Register(kPetClass,PetProc)||!Register(kHostClass,HostProc)) {
    CloseHandle(mutex); current=nullptr; return 4;
  }
  state.owner=CreateWindowExW(WS_EX_TOOLWINDOW,kOwnerClass,ownerTitle.c_str(),WS_POPUP,
                              0,0,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  const bool testHost=std::find(args.begin(),args.end(),L"--prototype-test-host")!=args.end();
  if(testHost) {
    state.host=CreateWindowExW(0,kHostClass,L"Stage A Click Target",WS_OVERLAPPEDWINDOW,
        160,160,620,430,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    ShowWindow(state.host,SW_SHOWNOACTIVATE);
  }
  state.pet=CreateWindowExW(WS_EX_LAYERED|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,
      kPetClass,L"Stage A Whale - DEMO 72%",WS_POPUP,0,0,kWidth,kHeight,
      nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  int result=0;
  if (!state.owner || !state.pet || (testHost && !state.host) || !InstallTray()) result=5;
  if(!result) { ResetPosition(); if(!DrawPet()) result=6; }
  if(!result) {
    ShowPet(); SetTimer(state.owner,1,200,nullptr);
    MSG message{}; int status=0;
    while((status=static_cast<int>(GetMessageW(&message,nullptr,0,0)))>0) {
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    if(status<0) result=7;
  }
  if(IsWindow(state.pet)) DestroyWindow(state.pet);
  if(IsWindow(state.host)) DestroyWindow(state.host);
  if(IsWindow(state.owner)) DestroyWindow(state.owner);
  CloseHandle(mutex); current=nullptr; return result;
}
}
