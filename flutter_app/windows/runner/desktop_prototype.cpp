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
constexpr UINT kMain = 104, kRefresh = 105, kPause = 106;
struct State {
  HWND owner = nullptr, pet = nullptr, host = nullptr;
  bool tray = false, dragging = false;
  POINT drag{};
  int petClicks = 0, hostClicks = 0, restores = 0;
  std::filesystem::path report;
  UINT taskbarCreated = 0;
  bool live = false, stale = false, paused = false;
  HWND mainWindow = nullptr;
  double remaining = -1;
  int64_t revision = 0, attempts = 0, failures = 0;
  std::wstring caption = L"Codex · 等待用量";
  std::function<void(const std::string&)> action;
};
State* current = nullptr;  // All callbacks execute on this UI thread.
HANDLE monitorMutex = nullptr;

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
        << ",\"revision\":" << s.revision << ",\"attempts\":" << s.attempts
        << ",\"failures\":" << s.failures << ",\"remaining\":" << s.remaining
        << ",\"paused\":" << (s.paused ? "true" : "false")
        << ",\"stale\":" << (s.stale ? "true" : "false")
        << ",\"mainVisible\":" << (IsWindowVisible(s.mainWindow) ? "true" : "false")
        << ",\"petRect\":[" << r.left << ',' << r.top << ',' << r.right << ',' << r.bottom << "]}";
  }
  MoveFileExW(temporary.c_str(), s.report.c_str(), MOVEFILE_REPLACE_EXISTING);
}

bool InstallTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = current->owner;
  icon.uID = 1; icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTray; icon.hIcon = LoadIconW(nullptr, IDI_INFORMATION);
  wcsncpy_s(icon.szTip, current->live ? current->caption.c_str() : L"Codex Stage A | DEMO 72% left | no account queries", _TRUNCATE);
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
    if(current->live && x>=8 && x<kWidth-8 && y>=3 && y<49) color=0xff202b40;
    if (ellipse(x,y,118,94,66,43) || ellipse(x,y,54,74,24,14) || ellipse(x,y,53,103,21,13)) color = current->live && current->stale ? 0xff89919a : 0xff66bfe8;
    if (ellipse(x,y,131,112,41,17)) color = 0xffcbeaf4;
    if (ellipse(x,y,150,85,5,7)) color = 0xff182d49;
    const double remaining = current->live ? current->remaining : 72;
    if (x >= 77 && x <= 174 && y >= 141 && y <= 147) color = remaining >= 0 && x < 77 + remaining * .98 ? (current->stale ? 0xff89919a : 0xff6bd4ad) : 0xff43526b;
    data[y * kWidth + x] = color;
  }
  auto old = SelectObject(dc, bitmap);
  if(current->live) {
    HFONT font=CreateFontW(-14,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    auto previousFont=SelectObject(dc,font);
    SetBkMode(dc,TRANSPARENT); SetTextColor(dc,RGB(255,255,255));
    RECT label{8,3,kWidth-8,49};
    DrawTextW(dc,current->caption.c_str(),-1,&label,DT_CENTER|DT_WORDBREAK|DT_NOPREFIX);
    for(int y=0;y<49;++y) for(int x=0;x<kWidth;++x) {
      auto& pixel=data[y*kWidth+x]; if(pixel & 0x00ffffff) pixel |= 0xff000000;
    }
    SelectObject(dc,previousFont); DeleteObject(font);
  }
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
  if (msg == kRestore) {
    ++s.restores; ShowPet();
    if(s.live) { ShowWindow(s.mainWindow,SW_RESTORE); SetForegroundWindow(s.mainWindow); }
    return 0;
  }
  switch (msg) {
    case WM_TIMER: Report(); return 0;
    case kTray:
      if (lp == WM_LBUTTONUP || lp == WM_LBUTTONDBLCLK) { ShowPet(); return 0; }
      if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU) {
        HMENU menu=CreatePopupMenu();
        if (s.live) {
          AppendMenuW(menu,MF_STRING,kMain,L"打开主窗口");
          AppendMenuW(menu,MF_STRING,kRefresh,L"立即刷新额度");
          AppendMenuW(menu,MF_STRING,kPause,s.paused ? L"恢复自动刷新" : L"暂停自动刷新");
          AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        }
        AppendMenuW(menu,MF_STRING,kShow,s.live ? L"显示桌宠" : L"Show pet (DEMO)");
        AppendMenuW(menu,MF_STRING,kHide,s.live ? L"隐藏桌宠" : L"Hide pet");
        AppendMenuW(menu,MF_STRING,kReset,s.live ? L"复位桌宠位置" : L"Reset position");
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        AppendMenuW(menu,MF_STRING,kExit,s.live ? L"退出监控" : L"Exit Stage A prototype");
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
        case kMain:
          ShowWindow(s.mainWindow,SW_RESTORE); SetForegroundWindow(s.mainWindow); break;
        case kRefresh: if(s.action) s.action("refresh"); break;
        case kPause: if(s.action) s.action(s.paused ? "resume" : "pause"); break;
        case kExit: if(s.live && s.action) s.action("exit"); else DestroyWindow(hwnd); break;
      } return 0;
    case WM_CLOSE: DestroyWindow(hwnd); return 0;
    case WM_DESTROY: {
      NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=hwnd; icon.uID=1;
      if (s.tray) Shell_NotifyIconW(NIM_DELETE,&icon);
      KillTimer(hwnd,1); if(!s.live) PostQuitMessage(0); return 0;
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

bool ClaimMonitorInstance(bool request_exit) {
  const auto suffix = Suffix();
  monitorMutex = CreateMutexW(nullptr,FALSE,(L"Local\\CodexTimeZone.Monitor." + suffix).c_str());
  if(!monitorMutex) return false;
  if(GetLastError()!=ERROR_ALREADY_EXISTS) {
    if(request_exit) { CloseHandle(monitorMutex); monitorMutex=nullptr; return false; }
    return true;
  }
  HWND owner = nullptr;
  for(int i=0;i<100 && !owner;++i) {
    owner=FindWindowW(kOwnerClass,(L"CodexTimeZone.Monitor."+suffix).c_str());
    if(!owner) Sleep(50);
  }
  if(owner) PostMessageW(owner,request_exit ? WM_COMMAND : kRestore,request_exit ? kExit : 0,0);
  CloseHandle(monitorMutex); monitorMutex=nullptr;
  return false;
}

bool AttachMonitor(HWND main_window, std::function<void(const std::string&)> action) {
  if(current) return false;
  current=new State(); current->live=true; current->mainWindow=main_window;
  int argc=0; auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(argv) {
    for(int i=1;i<argc;++i) { std::wstring arg(argv[i]); constexpr wchar_t prefix[]=L"--monitor-report=";
      if(arg.rfind(prefix,0)==0) current->report=arg.substr(std::size(prefix)-1);
    }
    LocalFree(argv);
  }
  current->action=std::move(action);
  current->taskbarCreated=RegisterWindowMessageW(L"TaskbarCreated");
  if(!Register(kOwnerClass,OwnerProc)||!Register(kPetClass,PetProc)) { DetachMonitor(); return false; }
  current->owner=CreateWindowExW(WS_EX_TOOLWINDOW,kOwnerClass,(L"CodexTimeZone.Monitor."+Suffix()).c_str(),
      WS_POPUP,0,0,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  current->pet=CreateWindowExW(WS_EX_LAYERED|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,
      kPetClass,L"Codex 用量桌宠",WS_POPUP,0,0,kWidth,kHeight,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  if(!current->owner || !current->pet || !InstallTray()) { DetachMonitor(); return false; }
  ResetPosition();
  if(!DrawPet()) { DetachMonitor(); return false; }
  ShowPet(); return true;
}

void PublishMonitor(const std::wstring& text, double remaining, bool stale,
                    bool paused, int64_t revision, int64_t attempts, int64_t failures) {
  if(!current || !current->live) return;
  current->caption=text; current->remaining=std::clamp(remaining,-1.0,100.0);
  current->stale=stale; current->paused=paused; current->revision=revision;
  current->attempts=attempts; current->failures=failures;
  NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=current->owner;
  icon.uID=1; icon.uFlags=NIF_TIP; wcsncpy_s(icon.szTip,text.c_str(),_TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY,&icon);
  SetWindowTextW(current->pet,text.c_str()); DrawPet();
  Report();
}

void DetachMonitor() {
  if(current && current->live) {
    if(IsWindow(current->pet)) DestroyWindow(current->pet);
    if(IsWindow(current->owner)) DestroyWindow(current->owner);
    delete current; current=nullptr;
  }
  if(monitorMutex) { CloseHandle(monitorMutex); monitorMutex=nullptr; }
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
