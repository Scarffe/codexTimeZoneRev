#include "desktop_prototype.h"
#include "pet_geometry.h"
#include "app_instance.h"
#include "resource.h"
#include "window_chrome.h"
#include "production_tray_menu.h"
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")
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
constexpr wchar_t kBubbleClass[] = L"CodexTimeZone.StageC.Bubble";
constexpr UINT kTray = WM_APP + 71;
constexpr UINT kRestore = WM_APP + 72;
constexpr int kWidth = 240, kHeight = 160;
constexpr UINT kEdge=110, kCompact=111, kExpanded=112;
constexpr UINT kShow = 100, kHide = 101, kReset = 102, kExit = 103;
constexpr UINT kMain = 104, kRefresh = 105, kPause = 106;
constexpr UINT kMuteCycle=119, kRoles=125, kReduceMotion=126, kPetTouch=127;
constexpr UINT kPreviewIdle=120,kPreviewRefresh=121,kPreviewLow=122,kPreviewReal=123,kPreviewReduced=124;
constexpr UINT kAlertTest=113;
constexpr UINT kMonitor=128;
constexpr UINT kTestQuota=1123,kTestSession=1124,kTestClick=1125,kTestClose=1126,kTestLegacy=1127,kTestResume=1128;
constexpr UINT kSuspendTest=114,kResumeTest=115,kDpi100=116,kDpi150=117,kDpi200=118;
struct State {
  HWND owner = nullptr, pet = nullptr, host = nullptr;
  bool tray = false, dragging = false, trayIconLoaded = false;
  POINT drag{}, origin{};
  bool moved=false;
  int mode=1;
  UINT dpi=96;
  bool resumeSent=false;
  int suspendMessages=0,resumeMessages=0,resumeActions=0,powerTestInjections=0;
  HPOWERNOTIFY powerRegistration=nullptr;
  std::filesystem::path settings;
  std::wstring detail;
  std::wstring sessionSummary;
  double sessionRate=-1;
  int sessionStatus=0, sessionAlertsShown=0, sessionAlertsSuppressed=0;
  int64_t sessionAlertSerial=0;
  bool sessionBubble=false, sessionAlertKeptFocus=true;
  int sessionFocusChecks=0, sessionBubbleClicks=0;
  std::wstring rolePath,roleName;
  UINT roleWidth=0,roleHeight=0;
  std::vector<std::uint32_t> rolePixels;
  bool reducedMotion=false,powerSuspended=false,animationTimer=false;
  UINT animationInterval=0;
  int animationState=3,animationFrame=0,visualTest=-1,soakStep=-1;
  bool animationSoak=false,testReduced=false,testHidden=false,testSuspended=false;
  uint64_t animationFrames=0,renderCount=0,drawFailures=0;
  ULONGLONG lastAnimationReport=0;
  bool preferredVisible=true,roleEditorOpen=false;
  int64_t preferencesSerial=0;
  int64_t alertSerial=0;
  bool testControls=false;
  HWND bubble=nullptr;
  ULONGLONG bubbleUntil=0;
  std::wstring bubbleText;
  bool companionBubble=false;
  int alertsShown=0, alertTests=0, bubbleDismissals=0;
  int petClicks = 0, hostClicks = 0, restores = 0, selfChecks = 0, selfFailedLine = 0;
  std::filesystem::path report;
  UINT taskbarCreated = 0;
  bool live = false, stale = false, paused = false;
  bool production=false,keepAlive=false,bridgeReady=false,backgroundStart=false;
  int closeRequests=0,backgroundNotices=0,notificationAttempts=0,notificationShellAccepted=0;
  int notificationClicks=0,notificationClickInjections=0,testActionInjections=0;
  bool notificationKeptFocus=true;
  int64_t notificationSerial=0;
  std::string workspace="launcher",notificationKind,notificationClickRoute,pendingNotificationRoute;
  std::wstring notificationText;
  ULONGLONG quotaPriorityUntil=0;
  HWND mainWindow = nullptr;
  double remaining = -1;
  int64_t revision = 0, attempts = 0, failures = 0;
  std::wstring caption = L"Codex · 等待用量";
  std::function<void(const std::string&)> action;
};
State* current = nullptr;  // All callbacks execute on this UI thread.
HANDLE monitorMutex = nullptr;

struct DisplayProbe { std::ofstream* out; int count=0; };
BOOL CALLBACK ProbeMonitor(HMONITOR monitor,HDC,LPRECT,LPARAM parameter) {
  auto& probe=*reinterpret_cast<DisplayProbe*>(parameter);
  MONITORINFO info{}; info.cbSize=sizeof(info);
  if(!GetMonitorInfoW(monitor,&info)) return TRUE;
  HWND window=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,L"STATIC",L"DPI probe",WS_POPUP,
      info.rcWork.left,info.rcWork.top,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  const UINT dpi=window ? GetDpiForWindow(window) : 0;
  if(window) DestroyWindow(window);
  if(probe.count++) *probe.out<<',';
  *probe.out<<"{\"primary\":"<<((info.dwFlags&MONITORINFOF_PRIMARY)?"true":"false")
      <<",\"dpi\":"<<dpi<<",\"rect\":["<<info.rcMonitor.left<<','<<info.rcMonitor.top<<','<<info.rcMonitor.right<<','<<info.rcMonitor.bottom
      <<"],\"workArea\":["<<info.rcWork.left<<','<<info.rcWork.top<<','<<info.rcWork.right<<','<<info.rcWork.bottom<<"]}";
  return TRUE;
}

bool WriteDisplayProbe(const std::filesystem::path& path) {
  std::ofstream out(path); if(!out) return false;
  DisplayProbe probe{&out}; out<<"{\"displays\":[";
  if(!EnumDisplayMonitors(nullptr,nullptr,ProbeMonitor,reinterpret_cast<LPARAM>(&probe))) return false;
  out<<"],\"displayCount\":"<<probe.count<<"}"; return out.good();
}

std::wstring Suffix() {
  wchar_t path[32768]{};
  GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
  // Path-scoped identity isolates the prototype from installed launchers.
  std::uint64_t hash = 14695981039346656037ULL;
  for (const auto ch : std::wstring(path)) {
    hash ^= static_cast<std::uint64_t>(towlower(ch)); hash *= 1099511628211ULL;
  }
  DWORD session = 0; ProcessIdToSessionId(GetCurrentProcessId(), &session);
  return std::to_wstring(session) + L"." + std::to_wstring(hash) + (app_instance::IsolatedProcess()?L".isolated":L"");
}

std::string Json(const std::wstring& value) {
  const int size=WideCharToMultiByte(CP_UTF8,0,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
  std::string utf8(size,'\0'); WideCharToMultiByte(CP_UTF8,0,value.data(),static_cast<int>(value.size()),utf8.data(),size,nullptr,nullptr);
  std::ostringstream out; out<<'"';
  for(unsigned char ch:utf8) {
    if(ch=='"' || ch=='\\') out<<'\\'<<ch;
    else if(ch<32) out<<"\\u"<<std::hex<<std::setw(4)<<std::setfill('0')<<static_cast<unsigned int>(ch)<<std::dec;
    else out<<ch;
  }
  out<<'"'; return out.str();
}
void Report() {
  auto& s = *current;
  if (s.report.empty()) return;
  RECT r{}; GetWindowRect(s.pet, &r);
  DWORD processHandles=0; GetProcessHandleCount(GetCurrentProcess(),&processHandles);
  DWORD foregroundPid = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &foregroundPid);
  const auto temporary = s.report.wstring() + L".tmp";
  {
    std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
    out << "{\"pid\":" << GetCurrentProcessId()
        << ",\"petPaused\":" << (s.production?"true":"false")
        << ",\"workspace\":\"" << s.workspace << "\""
        << ",\"keepAlive\":" << (s.keepAlive?"true":"false")
        << ",\"bridgeReady\":" << (s.bridgeReady?"true":"false")
        << ",\"backgroundStart\":" << (s.backgroundStart?"true":"false")
        << ",\"closePolicy\":\"" << ((s.backgroundStart || s.keepAlive)?"hide":"exit") << "\""
        << ",\"closeRequests\":" << s.closeRequests
        << ",\"backgroundNotices\":" << s.backgroundNotices
        << ",\"notificationAttempts\":" << s.notificationAttempts
        << ",\"notificationShellAccepted\":" << s.notificationShellAccepted
        << ",\"notificationKind\":\"" << s.notificationKind << "\""
        << ",\"notificationText\":" << Json(s.notificationText)
        << ",\"notificationSerial\":" << s.notificationSerial
        << ",\"notificationClickRoute\":\"" << s.notificationClickRoute << "\""
        << ",\"notificationClicks\":" << s.notificationClicks
        << ",\"notificationClickInjections\":" << s.notificationClickInjections
        << ",\"testActionInjections\":" << s.testActionInjections
        << ",\"notificationKeptFocus\":" << (s.notificationKeptFocus?"true":"false")
        << ",\"selfChecks\":" << s.selfChecks
        << ",\"selfFailedLine\":" << s.selfFailedLine
        << ",\"roleLoaded\":" << (!s.rolePixels.empty()?"true":"false")
        << ",\"roleWidth\":" << s.roleWidth << ",\"roleHeight\":" << s.roleHeight
        << ",\"petClicks\":" << s.petClicks << ",\"hostClicks\":" << s.hostClicks
        << ",\"restores\":" << s.restores << ",\"tray\":" << (s.tray ? "true" : "false")
        << ",\"trayIconResource\":" << IDI_TRAY_ICON
        << ",\"trayIconLoaded\":" << (s.trayIconLoaded ? "true" : "false")
        << ",\"nativeChrome\":" << window_chrome::DescribeWindow(s.mainWindow)
        << ",\"visible\":" << (IsWindowVisible(s.pet) ? "true" : "false")
        << ",\"foregroundPid\":" << foregroundPid
        << ",\"hostForeground\":" << (GetForegroundWindow() == s.host ? "true" : "false")
        << ",\"petForeground\":" << (GetForegroundWindow() == s.pet ? "true" : "false")
        << ",\"animationState\":" << (s.visualTest>=0 ? s.visualTest : s.animationState)
        << ",\"animationFrame\":" << s.animationFrame
        << ",\"animationFrames\":" << s.animationFrames
        << ",\"animationTimer\":" << (s.animationTimer ? "true" : "false")
        << ",\"reducedMotion\":" << ((s.reducedMotion || s.testReduced) ? "true" : "false")
        << ",\"animationTest\":" << (s.visualTest>=0 ? "true" : "false")
        << ",\"animationSuspended\":" << ((s.powerSuspended || s.testSuspended) ? "true" : "false")
        << ",\"soakStep\":" << s.soakStep
        << ",\"gdiObjects\":" << GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS)
        << ",\"userObjects\":" << GetGuiResources(GetCurrentProcess(),GR_USEROBJECTS)
        << ",\"handles\":" << processHandles
        << ",\"renders\":" << s.renderCount
        << ",\"drawFailures\":" << s.drawFailures
        << ",\"mode\":" << s.mode
        << ",\"dpi\":" << s.dpi << ",\"actualWindowDpi\":" << GetDpiForWindow(s.pet)
        << ",\"displayCount\":" << GetSystemMetrics(SM_CMONITORS)
        << ",\"suspendMessages\":" << s.suspendMessages << ",\"resumeMessages\":" << s.resumeMessages
        << ",\"powerSubscribed\":" << (s.powerRegistration ? "true" : "false")
        << ",\"resumeActions\":" << s.resumeActions << ",\"powerTestInjections\":" << s.powerTestInjections
        << ",\"alertsShown\":" << s.alertsShown << ",\"alertTests\":" << s.alertTests
        << ",\"bubbleDismissals\":" << s.bubbleDismissals
        << ",\"bubbleVisible\":" << (IsWindowVisible(s.bubble) ? "true" : "false")
        << ",\"sessionStatus\":" << s.sessionStatus
        << ",\"sessionBubbleClicks\":" << s.sessionBubbleClicks
        << ",\"sessionFocusChecks\":" << s.sessionFocusChecks
        << ",\"sessionAlertKeptFocus\":" << (s.sessionAlertKeptFocus?"true":"false")
        << ",\"bubbleForeground\":" << (GetForegroundWindow()==s.bubble?"true":"false")
        << ",\"sessionAlertsShown\":" << s.sessionAlertsShown
        << ",\"sessionAlertsSuppressed\":" << s.sessionAlertsSuppressed
        << ",\"sessionBubble\":" << (s.sessionBubble && IsWindowVisible(s.bubble)?"true":"false")
        << ",\"sessionRate\":" << s.sessionRate
        << ",\"sessionSummaryPresent\":" << (!s.sessionSummary.empty()?"true":"false")
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
  icon.uCallbackMessage = kTray;
  icon.hIcon = reinterpret_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),MAKEINTRESOURCEW(IDI_TRAY_ICON),
      IMAGE_ICON,GetSystemMetrics(SM_CXSMICON),GetSystemMetrics(SM_CYSMICON),LR_SHARED));
  current->trayIconLoaded=icon.hIcon!=nullptr;
  if (!icon.hIcon) return false;
  wcsncpy_s(icon.szTip, current->live ? current->caption.c_str() : L"Codex Stage A | DEMO 72% left | no account queries", _TRUNCATE);
  current->tray = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  return current->tray;
}

bool Notify(const std::wstring& text,const std::string& kind,int64_t serial,const std::string& route) {
  auto& s=*current;
  const HWND foreground=GetForegroundWindow();
  ++s.notificationAttempts; s.notificationText=text; s.notificationKind=kind; s.notificationSerial=serial;
  NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=s.owner; icon.uID=1; icon.uFlags=NIF_INFO;
  icon.dwInfoFlags=NIIF_INFO|NIIF_NOSOUND;
  const wchar_t* title=kind=="quota" ? L"Codex 额度提醒" : (kind=="session" ? L"Codex 回合提醒" : L"Codex 后台运行");
  wcsncpy_s(icon.szInfoTitle,title,_TRUNCATE); wcsncpy_s(icon.szInfo,text.c_str(),_TRUNCATE);
  const bool accepted=Shell_NotifyIconW(NIM_MODIFY,&icon)!=FALSE;
  if(accepted) { ++s.notificationShellAccepted; s.pendingNotificationRoute=route; }
  s.notificationKeptFocus=s.notificationKeptFocus && foreground==GetForegroundWindow();
  Report(); return accepted; // Shell acceptance does not establish physical display.
}
void RestoreMain() {
  ShowWindow(current->mainWindow,SW_RESTORE); SetForegroundWindow(current->mainWindow);
}
void NotificationClick(bool injected) {
  auto& s=*current;
  if(injected) ++s.notificationClickInjections;
  if(s.pendingNotificationRoute.empty()) { Report(); return; }
  ++s.notificationClicks; s.notificationClickRoute=s.pendingNotificationRoute;
  s.pendingNotificationRoute.clear(); s.quotaPriorityUntil=0;
  RestoreMain(); if(s.action) s.action(s.notificationClickRoute); Report();
}

int BaseWidth() { return current->mode==0 ? 88 : (current->mode==2 ? 320 : 240); }
int BaseHeight() { return current->mode==0 ? 72 : (!current->rolePixels.empty() ? (current->mode==2 ? 470 : 320) : (current->mode==2 ? 310 : 160)); }
int Px(int value) { return pet_geometry::Scale(value,current->dpi); }
int Width() { return Px(BaseWidth()); }
int Height() { return Px(BaseHeight()); }

void SavePosition() {
  if(current->production || current->settings.empty()) return;
  RECT r{}; GetWindowRect(current->pet,&r);
  const auto temporary=current->settings.wstring()+L".tmp";
  { std::ofstream out(temporary); out << "1 " << current->mode << ' ' << r.left << ' ' << r.top; }
  MoveFileExW(temporary.c_str(),current->settings.c_str(),MOVEFILE_REPLACE_EXISTING);
}

void Place(bool snap) {
  RECT r{}; GetWindowRect(current->pet,&r);
  MONITORINFO info{}; info.cbSize=sizeof(info);
  if(!GetMonitorInfoW(MonitorFromRect(&r,MONITOR_DEFAULTTONEAREST),&info)) return;
  const auto fitted=pet_geometry::Fit(r,info.rcWork,Width(),Height(),current->mode==0,snap ? Px(24) : 0);
  SetWindowPos(current->pet,HWND_TOPMOST,fitted.left,fitted.top,Width(),Height(),SWP_NOACTIVATE);
}

void ReadPosition() {
  int version=0,mode=1,x=0,y=0;
  std::ifstream in(current->settings);
  if(in>>version>>mode>>x>>y && version==1 && mode>=0 && mode<=2 && abs(static_cast<int64_t>(x))<100000 && abs(static_cast<int64_t>(y))<100000) {
    current->mode=mode;
    SetWindowPos(current->pet,HWND_TOPMOST,x,y,Width(),Height(),SWP_NOACTIVATE);
    Place(false);
  }
}

void LoadPosition() {
  if(!current->live) return;
  wchar_t executable[32768]{}; GetModuleFileNameW(nullptr,executable,32768);
  current->settings=std::filesystem::path(executable).parent_path()/L"pet-position-v1.txt";
  ReadPosition();
}

void ResetPosition() {
  RECT area{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0);
  int x = area.right - Width() - Px(32), y = area.bottom - Height() - Px(48);
  if (current->host) {
    RECT host{}; GetWindowRect(current->host, &host); x = host.left + 100; y = host.top + 100;
  }
  SetWindowPos(current->pet, HWND_TOPMOST, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
}

int VisualState() { return current->visualTest>=0 ? current->visualTest : current->animationState; }
bool AnimationAllowed() {
  const auto& s=*current;
  return !s.production && s.rolePixels.empty() && s.live && !s.reducedMotion && !s.testReduced && !s.powerSuspended &&
    !s.testSuspended && !s.paused && !s.stale && !s.dragging &&
    IsWindowVisible(s.pet) && VisualState()<3;
}
void SyncAnimation() {
  auto& s=*current;
  const UINT interval=VisualState()==1 ? 200u : 500u;
  if(AnimationAllowed()) {
    if(!s.animationTimer || s.animationInterval!=interval) {
      s.animationTimer=SetTimer(s.owner,3,interval,nullptr)!=0;
      s.animationInterval=interval;
    }
  } else {
    KillTimer(s.owner,3); s.animationTimer=false; s.animationInterval=0; s.animationFrame=0;
  }
}

bool DrawPet() {
  ++current->renderCount;
  const int width=Width(),height=Height();
  const int visual=VisualState(),frame=current->animationFrame;
  const bool motion=AnimationAllowed();
  constexpr int bobbing[]={0,1,2,1,0,-1,-2,-1};
  const int bob=motion && visual==0 ? bobbing[frame%8] : 0;
  // A real premultiplied-alpha DIB: zero-alpha pixels are not mouse targets.
  // Original geometric placeholder; no downloaded character assets.
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!screen || !dc || !bitmap || !pixels) {
    if (bitmap) DeleteObject(bitmap); if (dc) DeleteDC(dc); if (screen) ReleaseDC(nullptr, screen);
    ++current->drawFailures; return false;
  }
  auto data = static_cast<std::uint32_t*>(pixels);
  std::vector<int> logicalX(width);
  for(int i=0;i<width;++i) logicalX[i]=MulDiv(i,96,static_cast<int>(current->dpi));
  for (int pixelY = 0; pixelY < height; ++pixelY) {
    const int y=MulDiv(pixelY,96,static_cast<int>(current->dpi));
    for (int pixelX = 0; pixelX < width; ++pixelX) {
    const int x=logicalX[pixelX];
    const auto ellipse = [](int px, int py, int cx, int cy, int rx, int ry) {
      const double dx = static_cast<double>(px - cx) / rx;
      const double dy = static_cast<double>(py - cy) / ry; return dx * dx + dy * dy <= 1;
    };
    std::uint32_t color = 0;
    if(current->mode==2 && x>=8 && x<BaseWidth()-8 && y>=3 && y<BaseHeight()-8) color=0xff202b40;
    if(current->live && x>=8 && x<kWidth-8 && y>=3 && y<49) color=0xff202b40;
    const int whaleY=y-bob;
    const std::uint32_t lowColors[]={0xffe4b778,0xffe6bb7e,0xffe8bf84,0xffe6bb7e};
    const auto body=current->live && (current->stale || visual==3) ? 0xff89919au :
      (visual==2 ? lowColors[motion ? (frame/2)%4 : 0] : 0xff66bfe8u);
    if (current->rolePixels.empty()) {
    if (ellipse(x,whaleY,118,94,66,43) || ellipse(x,whaleY,54,74,24,14) || ellipse(x,whaleY,53,103,21,13)) color=body;
    if (ellipse(x,whaleY,131,112,41,17)) color=0xffcbeaf4;
    if (ellipse(x,whaleY,150,85,5,7)) color=0xff182d49;
    if(visual==1) {
      const int step=motion ? frame%8 : 0;
      if(ellipse(x,y,183+step*3,66-step*3,3,3)) color=0xffcbeaf4;
      if(ellipse(x,y,198-step*2,60-step*2,2,2)) color=0xff66bfe8;
    }
    }
    if(!current->rolePixels.empty() && current->mode!=0) {
      const double scale=std::min(208.0/current->roleWidth,240.0/current->roleHeight);
      const int rw=static_cast<int>(current->roleWidth*scale),rh=static_cast<int>(current->roleHeight*scale);
      const int left=(BaseWidth()-rw)/2,top=52+(240-rh)/2;
      if(x>=left && x<left+rw && y>=top && y<top+rh) {
        const int sx=std::min(static_cast<int>((x-left)/scale),static_cast<int>(current->roleWidth)-1);
        const int sy=std::min(static_cast<int>((y-top)/scale),static_cast<int>(current->roleHeight)-1);
        const auto src=current->rolePixels[sy*current->roleWidth+sx];
        const auto inv=255-(src>>24);
        const auto channel=[&](int shift) { return std::min(255u,((src>>shift)&255)+(((color>>shift)&255)*inv+127)/255); };
        color=(channel(24)<<24)|(channel(16)<<16)|(channel(8)<<8)|channel(0);
      }
    }
    const double remaining = current->live ? current->remaining : 72;
    if (x >= 77 && x <= 174 && y >= (current->rolePixels.empty()?141:301) && y <= (current->rolePixels.empty()?147:307)) color = remaining >= 0 && x < 77 + remaining * .98 ? (current->stale ? 0xff89919a : 0xff6bd4ad) : 0xff43526b;
    if(current->mode==0) {
      color=ellipse(x,y,44,36,40,30) ? (current->stale ? 0xff89919a : 0xff202b40) : 0;
      if(ellipse(x,y,68,18+(motion ? bobbing[frame%8] : 0),3,3))
        color=visual==3 ? 0xff89919a : (visual==2 ? 0xffe4b778 : (visual==1 ? 0xff66bfe8 : 0xff6bd4ad));
    }
    data[pixelY * width + pixelX] = color;
    }
  }
  auto old = SelectObject(dc, bitmap);
  if(current->live) {
    HFONT font=CreateFontW(-Px(current->mode==0 ? 22 : 16),0,0,0,current->mode==0 ? FW_BOLD : FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    auto previousFont=SelectObject(dc,font);
    SetBkMode(dc,TRANSPARENT); SetTextColor(dc,RGB(255,255,255));
    RECT label{Px(8),Px(3),width-Px(8),current->mode==0 ? height-Px(8) : Px(49)};
    auto caption=current->mode==0 ? (current->remaining<0 ? L"--" : std::to_wstring(static_cast<int>(current->remaining))+L"%") : (current->sessionSummary.empty() ? current->caption : current->sessionSummary);
    if(current->visualTest>=0 && current->mode!=0) {
      const wchar_t* labels[]={L"待机",L"刷新",L"低额度",L"不可用"};
      caption=std::wstring(L"动画预览（模拟）· ")+labels[visual];
    }
    DrawTextW(dc,caption.c_str(),-1,&label,current->mode==0 ? DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX : DT_CENTER|DT_WORDBREAK|DT_NOPREFIX);
    if(current->mode==2) {
      RECT detail{Px(16),Px(current->rolePixels.empty()?160:320),width-Px(16),height-Px(12)};
      DrawTextW(dc,current->detail.c_str(),-1,&detail,DT_LEFT|DT_WORDBREAK|DT_NOPREFIX);
    }
    // GDI batches text writes. Flush before restoring alpha in the DIB.
    GdiFlush();
    for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
      auto& pixel=data[y*width+x]; if((pixel & 0x00ffffff) && (current->rolePixels.empty() || y<Px(49) || (current->mode==2 && y>=Px(320)))) pixel |= 0xff000000;
    }
    SelectObject(dc,previousFont); DeleteObject(font);
  }
  SIZE size{width,height}; POINT source{}; RECT r{}; GetWindowRect(current->pet, &r);
  POINT destination{r.left,r.top}; BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
  const bool ok = UpdateLayeredWindow(current->pet, screen, &destination, &size, dc,
                                      &source, 0, &blend, ULW_ALPHA) != FALSE;
  SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr, screen);
  if(!ok) ++current->drawFailures;
  return ok;
}

void ShowPet() {
  if(current->production || current->roleEditorOpen) return;
  ShowWindow(current->pet, SW_SHOWNOACTIVATE);
  SetWindowPos(current->pet, HWND_TOPMOST, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
  SyncAnimation(); Report();
}

bool Register(const wchar_t* name,WNDPROC proc);

LRESULT CALLBACK BubbleProc(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
  if(msg==WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if(msg==WM_DPICHANGED) return 0; // The owning pet renders and positions this surface.
  if(msg==WM_LBUTTONUP || msg==WM_CLOSE) {
    ++current->bubbleDismissals;
    const bool openSession=msg==WM_LBUTTONUP && current->sessionBubble;
    ShowWindow(hwnd,SW_HIDE); KillTimer(current->owner,2);
    if(openSession && current->live) {
      ++current->sessionBubbleClicks;
      ShowWindow(current->mainWindow,SW_RESTORE); SetForegroundWindow(current->mainWindow);
      if(current->action) current->action("sessionDetails");
    }
    Report(); return 0;
  }
  return DefWindowProcW(hwnd,msg,wp,lp);
}

bool ShowAlert(const std::wstring& text,bool renew=true,bool companion=false,bool session=false) {
  auto& s=*current;
  if(s.production) return false;
  // A pet response must not replace a still-visible completion reminder.
  if(companion && s.sessionBubble && IsWindowVisible(s.bubble)) return true;
  if(!s.bubble) {
    if(!Register(kBubbleClass,BubbleProc)) return false;
    s.bubble=CreateWindowExW(WS_EX_LAYERED|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,
        kBubbleClass,L"Codex 桌宠提醒",WS_POPUP,0,0,320,110,s.pet,nullptr,GetModuleHandleW(nullptr),nullptr);
  }
  if(!s.bubble) return false;
  const int width=Px(320),height=Px(110);
  BITMAPINFO info{}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth=width; info.bmiHeader.biHeight=-height;
  info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32;
  HDC screen=GetDC(nullptr),dc=CreateCompatibleDC(screen); void* pixels=nullptr;
  HBITMAP bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,nullptr,0);
  if(!screen || !dc || !bitmap || !pixels) {
    if(bitmap) DeleteObject(bitmap); if(dc) DeleteDC(dc); if(screen) ReleaseDC(nullptr,screen); return false;
  }
  auto data=static_cast<std::uint32_t*>(pixels);
  for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
    const int radius=Px(12),dx=x-std::clamp(x,radius,width-radius-1),dy=y-std::clamp(y,radius,height-radius-1);
    data[y*width+x]=dx*dx+dy*dy<=radius*radius ? 0xff344663 : 0;
  }
  auto old=SelectObject(dc,bitmap);
  HFONT font=CreateFontW(-Px(18),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,L"Segoe UI");
  auto previousFont=SelectObject(dc,font); SetBkMode(dc,TRANSPARENT); SetTextColor(dc,RGB(255,255,255));
  RECT label{Px(14),Px(10),width-Px(14),height-Px(8)};
  const auto message=std::wstring(session ? L"回合提醒 · 点击查看\n" : (companion ? L"桌宠回应 · 点击关闭\n" : L"低额度提醒 · 点击关闭\n"))+text;
  DrawTextW(dc,message.c_str(),-1,&label,DT_LEFT|DT_WORDBREAK|DT_NOPREFIX);
  GdiFlush();
  for(int i=0;i<width*height;++i) if(data[i]&0x00ffffff) data[i]|=0xff000000;
  RECT pet{}; GetWindowRect(s.pet,&pet); MONITORINFO monitor{}; monitor.cbSize=sizeof(monitor);
  GetMonitorInfoW(MonitorFromRect(&pet,MONITOR_DEFAULTTONEAREST),&monitor);
  const auto a=monitor.rcWork;
  POINT destination{std::clamp(pet.left,a.left,std::max(a.left,a.right-width)),
      std::clamp(pet.top-height-Px(4)>=a.top ? pet.top-height-Px(4) : pet.bottom+Px(4),a.top,std::max(a.top,a.bottom-height))};
  POINT source{}; SIZE size{width,height}; BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
  const bool ok=UpdateLayeredWindow(s.bubble,screen,&destination,&size,dc,&source,0,&blend,ULW_ALPHA)!=FALSE;
  SelectObject(dc,previousFont); DeleteObject(font); SelectObject(dc,old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr,screen);
  if(ok) {
    // Extra inspection time only in explicitly opted-in UI test mode.
    if(renew) {
      s.companionBubble=companion;
      s.sessionBubble=session;
      s.bubbleText=text;
      s.bubbleUntil=GetTickCount64()+(s.testControls ? 90000 : 10000);
      if(session) ++s.sessionAlertsShown;
      else if(!companion) ++s.alertsShown;
    }
    ShowWindow(s.bubble,SW_SHOWNOACTIVATE);
    SetWindowPos(s.bubble,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
    SetTimer(s.owner,2,250,nullptr);
  }
  Report(); return ok;
}

LRESULT CALLBACK PetProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto& s = *current;
  switch (msg) {
    case WM_DPICHANGED: {
      if(!s.pet) return 0;
      const auto dpi=LOWORD(wp);
      if(dpi<48 || dpi>768) return 0;
      s.dpi=dpi;
      if(lp) {
        const auto& suggested=*reinterpret_cast<const RECT*>(lp);
        SetWindowPos(hwnd,HWND_TOPMOST,suggested.left,suggested.top,Width(),Height(),SWP_NOACTIVATE);
      }
      Place(false); DrawPet();
      if(IsWindowVisible(s.bubble)) ShowAlert(s.bubbleText,false,s.companionBubble,s.sessionBubble);
      SavePosition(); Report(); return 0;
    }
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_LBUTTONDOWN: {
      ++s.petClicks; s.dragging = true; s.moved=false; GetCursorPos(&s.drag); s.origin=s.drag; SetCapture(hwnd); Report(); return 0;
    }
    case WM_MOUSEMOVE:
      if (s.dragging) {
        POINT p{}; GetCursorPos(&p); RECT r{}; GetWindowRect(hwnd,&r);
        if(!s.moved && abs(p.x-s.origin.x)<GetSystemMetrics(SM_CXDRAG) && abs(p.y-s.origin.y)<GetSystemMetrics(SM_CYDRAG)) return 0;
        s.moved=true;
        SetWindowPos(hwnd,HWND_TOPMOST,r.left+p.x-s.drag.x,r.top+p.y-s.drag.y,0,0,SWP_NOSIZE|SWP_NOACTIVATE);
        s.drag=p;
      } return 0;
    case WM_LBUTTONUP: {
      // Fast input may coalesce WM_MOUSEMOVE behind button-up. Always account
      // for the final cursor displacement before deciding this was a click.
      if(s.dragging) {
        POINT p{}; GetCursorPos(&p);
        if(s.moved || abs(p.x-s.origin.x)>=GetSystemMetrics(SM_CXDRAG) || abs(p.y-s.origin.y)>=GetSystemMetrics(SM_CYDRAG)) {
          RECT r{}; GetWindowRect(hwnd,&r);
          SetWindowPos(hwnd,HWND_TOPMOST,r.left+p.x-s.drag.x,r.top+p.y-s.drag.y,0,0,SWP_NOSIZE|SWP_NOACTIVATE);
          s.moved=true;
        }
      }
      const bool clicked=s.dragging && !s.moved;
      s.dragging=false; ReleaseCapture(); SyncAnimation();
      if(clicked && s.live) { PostMessageW(s.owner,kTray,0,WM_RBUTTONUP); }
      if(clicked && !s.live) { s.mode=(s.mode+1)%3; if(s.live && s.action) s.action("mode"+std::to_string(s.mode)); }
      Place(true); DrawPet(); SavePosition(); Report(); return 0;
    }
    case WM_DISPLAYCHANGE: case WM_SETTINGCHANGE:
      Place(false); DrawPet(); SavePosition(); return 0;
    case WM_CAPTURECHANGED: s.dragging=false; SyncAnimation(); return 0;
    case WM_SHOWWINDOW: SyncAnimation(); return 0;
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
    ++s.restores; if(!s.production && (!s.live || s.preferredVisible)) ShowPet();
    if(s.live) { ShowWindow(s.mainWindow,SW_RESTORE); SetForegroundWindow(s.mainWindow); }
    return 0;
  }
  switch (msg) {
    case WM_POWERBROADCAST:
      if(wp==PBT_APMSUSPEND) {
        ++s.suspendMessages; s.resumeSent=false; s.powerSuspended=true; SyncAnimation();
        if(s.action) s.action("systemSuspend");
      } else if(wp==PBT_APMRESUMEAUTOMATIC || wp==PBT_APMRESUMESUSPEND || wp==PBT_APMRESUMECRITICAL) {
        ++s.resumeMessages; s.powerSuspended=false; SyncAnimation();
        if(!s.resumeSent) {
          s.resumeSent=true; ++s.resumeActions;
          ShowWindow(s.bubble,SW_HIDE); KillTimer(hwnd,2);
          if(!s.production) { Place(false); DrawPet(); SavePosition(); }
          if(s.action) s.action("systemResume");
        }
      }
      Report(); return TRUE;
    case WM_TIMER:
      if(wp==3) {
        SyncAnimation();
        if(s.animationTimer) { s.animationFrame=(s.animationFrame+1)%8; ++s.animationFrames; DrawPet(); }
        if(!s.report.empty() && GetTickCount64()-s.lastAnimationReport>=5000) {
          s.lastAnimationReport=GetTickCount64(); Report();
        }
        return 0;
      }
      if(wp==4 && !s.production && s.animationSoak && s.testControls) {
        ++s.soakStep; const int step=s.soakStep%8;
        s.visualTest=step<3 ? step : (step==5 ? 3 : 0);
        s.testReduced=step==3; s.testHidden=step==4; s.testSuspended=step==6;
        s.mode=(s.soakStep/8)%3; Place(false);
        ShowWindow(s.pet,s.testHidden ? SW_HIDE : SW_SHOWNOACTIVATE);
        SyncAnimation(); DrawPet(); Report(); return 0;
      }
      if(wp==2 && GetTickCount64()>=s.bubbleUntil) { ShowWindow(s.bubble,SW_HIDE); KillTimer(hwnd,2); }
      Report(); return 0;
    case kTray:
      if(s.production && lp==NIN_BALLOONUSERCLICK) { NotificationClick(false); return 0; }
      if(s.production && (lp==NIN_BALLOONTIMEOUT || lp==NIN_BALLOONHIDE)) {
        s.pendingNotificationRoute.clear(); s.quotaPriorityUntil=0; Report(); return 0;
      }
      if(s.production && (lp==WM_LBUTTONUP || lp==WM_LBUTTONDBLCLK)) { RestoreMain(); Report(); return 0; }
      if (lp == WM_LBUTTONUP || lp == WM_LBUTTONDBLCLK) { ShowPet(); if(s.live && s.action) s.action("showPet"); return 0; }
      if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU) {
        HMENU menu=s.production
            ? production_tray::Build({kMain,kRefresh,kPause,kExit},s.paused)
            : CreatePopupMenu();
        if(!menu) return 0;
        if(!s.production) {
        if (s.live) {
          AppendMenuW(menu,MF_STRING|MF_GRAYED,0,s.caption.c_str());
          if(!s.production) {
            AppendMenuW(menu,MF_STRING,kRoles,L"角色与本地立绘…");
            AppendMenuW(menu,MF_STRING,kReduceMotion,L"减少动画");
            AppendMenuW(menu,MF_STRING,kPetTouch,L"摸摸桌宠");
          }
          AppendMenuW(menu,MF_STRING,kMain,L"打开主窗口");
          AppendMenuW(menu,MF_STRING,kMonitor,L"监控与工具");
          AppendMenuW(menu,MF_STRING,kRefresh,L"立即刷新额度");
          AppendMenuW(menu,MF_STRING,kPause,s.paused ? L"恢复自动刷新" : L"暂停自动刷新");
          AppendMenuW(menu,MF_STRING,kMuteCycle,L"本轮额度周期不再提醒");
          AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        }
        if(!s.production) {
        AppendMenuW(menu,MF_STRING|(s.mode==0?MF_CHECKED:0),kEdge,L"边缘形态");
        AppendMenuW(menu,MF_STRING|(s.mode==1?MF_CHECKED:0),kCompact,L"紧凑形态");
        AppendMenuW(menu,MF_STRING|(s.mode==2?MF_CHECKED:0),kExpanded,L"展开形态");
        AppendMenuW(menu,MF_STRING,kShow,s.live ? L"显示桌宠" : L"Show pet (DEMO)");
        AppendMenuW(menu,MF_STRING,kHide,s.live ? L"隐藏桌宠" : L"Hide pet");
        AppendMenuW(menu,MF_STRING,kReset,s.live ? L"复位桌宠位置" : L"Reset position");
        }
        if(s.testControls && !s.production) {
          AppendMenuW(menu,MF_STRING,kPreviewIdle,L"动画预览：待机（模拟）");
          AppendMenuW(menu,MF_STRING,kPreviewRefresh,L"动画预览：刷新（模拟）");
          AppendMenuW(menu,MF_STRING,kPreviewLow,L"动画预览：低额度（模拟）");
          AppendMenuW(menu,MF_STRING,kPreviewReduced,L"预览减少动画（测试）");
          AppendMenuW(menu,MF_STRING,kPreviewReal,L"退出动画预览");
          AppendMenuW(menu,MF_STRING,kAlertTest,L"测试低额度气泡（模拟 10%）");
          AppendMenuW(menu,MF_STRING,kSuspendTest,L"模拟系统挂起（测试）");
          AppendMenuW(menu,MF_STRING,kResumeTest,L"模拟系统恢复（测试）");
          AppendMenuW(menu,MF_STRING,kDpi100,L"模拟 DPI 100%（测试）");
          AppendMenuW(menu,MF_STRING,kDpi150,L"模拟 DPI 150%（测试）");
          AppendMenuW(menu,MF_STRING,kDpi200,L"模拟 DPI 200%（测试）");
        }
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        AppendMenuW(menu,MF_STRING,kExit,s.live ? L"退出监控" : L"Exit Stage A prototype");
        }
        POINT p{}; GetCursorPos(&p);
        // Menus require foreground ownership; ordinary pet show/click never does.
        HWND menuOwner=s.live && IsWindowVisible(s.mainWindow) ? s.mainWindow : hwnd;
        SetForegroundWindow(menuOwner);
        auto command=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,p.x,p.y,0,menuOwner,nullptr);
        DestroyMenu(menu); PostMessageW(menuOwner,WM_NULL,0,0);
        if (command) PostMessageW(hwnd,WM_COMMAND,command,0);
      } return 0;
    case WM_COMMAND:
      if(s.production) {
        const UINT command=LOWORD(wp);
        if(command==kShow || command==kHide || command==kReset || command==kEdge || command==kCompact || command==kExpanded ||
           command==kRoles || command==kReduceMotion || command==kPetTouch || (command>=kPreviewIdle && command<=kPreviewReduced)) { Report(); return 0; }
        if(command>=kTestQuota && command<=kTestResume) {
          if(!s.testControls) return 0;
          ++s.testActionInjections;
          if(command==kTestQuota) Notify(L"测试注入：额度提醒","quota",++s.alertSerial,"monitorDetails");
          if(command==kTestSession) Notify(L"测试注入：回合提醒","session",++s.sessionAlertSerial,"sessionDetails");
          if(command==kTestClick) NotificationClick(true);
          if(command==kTestClose) SendMessageW(s.mainWindow,WM_CLOSE,0,0);
          if(command==kTestLegacy) { ConfigureMonitor(2,true,s.preferencesSerial+1); ShowPet(); }
          if(command==kTestResume) { ++s.powerTestInjections; SendMessageW(hwnd,WM_POWERBROADCAST,PBT_APMSUSPEND,0); SendMessageW(hwnd,WM_POWERBROADCAST,PBT_APMRESUMEAUTOMATIC,0); }
          Report(); return 0;
        }
      }
      switch (LOWORD(wp)) {
        case kShow: ShowPet(); if(s.live && s.action) s.action("showPet"); break;
        case kHide: s.preferredVisible=false; ShowWindow(s.pet,SW_HIDE); if(s.live && s.action) s.action("hidePet"); Report(); break;
        case kReset: ResetPosition(); Place(false); DrawPet(); SavePosition(); ShowPet(); if(s.live && s.action) s.action("showPet"); break;
        case kEdge: case kCompact: case kExpanded:
          s.mode=static_cast<int>(LOWORD(wp)-kEdge); Place(true); DrawPet(); SavePosition(); ShowPet(); if(s.live && s.action) s.action("mode"+std::to_string(s.mode)); break;
        case kRoles:
          ShowWindow(s.mainWindow,SW_RESTORE); SetForegroundWindow(s.mainWindow); if(s.action) s.action("roles"); break;
        case kReduceMotion: if(s.action) s.action("reduceMotion"); break;
        case kPetTouch: ShowAlert(L"谢谢陪伴。额度仍由真实查询更新。",true,true); break;
        case kMain:
          ShowWindow(s.mainWindow,SW_RESTORE); SetForegroundWindow(s.mainWindow); break;
        case kMonitor: RestoreMain(); if(s.action) s.action("monitorDetails"); break;
        case kMuteCycle: if(s.live && s.action) s.action("muteCycle"); break;
        case kRefresh: if(s.action) s.action("refresh"); break;
        case kPreviewIdle: case kPreviewRefresh: case kPreviewLow: case kPreviewReal: case kPreviewReduced:
          if(s.testControls) {
            if(LOWORD(wp)==kPreviewReduced) s.testReduced=!s.testReduced;
            else { s.visualTest=LOWORD(wp)==kPreviewReal ? -1 : static_cast<int>(LOWORD(wp)-kPreviewIdle); s.testReduced=false; }
            SyncAnimation(); DrawPet(); Report();
          } break;
        case kAlertTest:
          TriggerTestAlert(); break;
        case kSuspendTest: case kResumeTest:
          if(s.testControls) {
            ++s.powerTestInjections;
            SendMessageW(hwnd,WM_POWERBROADCAST,LOWORD(wp)==kSuspendTest ? PBT_APMSUSPEND : PBT_APMRESUMEAUTOMATIC,0);
          } break;
        case kDpi100: case kDpi150: case kDpi200:
          if(s.testControls) {
            const UINT dpi=LOWORD(wp)==kDpi100 ? 96u : (LOWORD(wp)==kDpi150 ? 144u : 192u);
            RECT r{}; GetWindowRect(s.pet,&r);
            SendMessageW(s.pet,WM_DPICHANGED,MAKELONG(dpi,dpi),reinterpret_cast<LPARAM>(&r));
          } break;
        case kPause: if(s.action) s.action(s.paused ? "resume" : "pause"); break;
        case kExit: if(s.live && s.action) s.action("exit"); else DestroyWindow(hwnd); break;
      } return 0;
    case WM_CLOSE: DestroyWindow(hwnd); return 0;
    case WM_DESTROY: {
      if(s.powerRegistration) { UnregisterSuspendResumeNotification(s.powerRegistration); s.powerRegistration=nullptr; }
      NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=hwnd; icon.uID=1;
      if (s.tray) Shell_NotifyIconW(NIM_DELETE,&icon);
      KillTimer(hwnd,1); KillTimer(hwnd,2); KillTimer(hwnd,3); KillTimer(hwnd,4); if(!s.live) PostQuitMessage(0); return 0;
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

bool TriggerTestAlert() {
  if(!current || !current->testControls) return false;
  ++current->alertTests;
  return ShowAlert(L"测试模拟：剩余 10%。\n真实用量未改变。");
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

int ForwardWorkspaceTestAction(const std::vector<std::wstring>& arguments) {
  constexpr wchar_t prefix[]=L"--workspace-test-action=";
  for(const auto& argument:arguments) if(argument.rfind(prefix,0)==0) {
    const auto name=argument.substr(std::size(prefix)-1);
    UINT command=0;
    if(name==L"quota") command=kTestQuota; else if(name==L"session") command=kTestSession;
    else if(name==L"click") command=kTestClick; else if(name==L"close") command=kTestClose;
    else if(name==L"legacy-show") command=kTestLegacy; else if(name==L"resume") command=kTestResume;
    else if(name==L"restore") command=kMain; else return 4;
    const HWND owner=FindWindowW(kOwnerClass,(L"CodexTimeZone.Monitor."+Suffix()).c_str());
    return owner && PostMessageW(owner,WM_COMMAND,command,0) ? 0 : 4;
  }
  return -1;
}

bool AttachMonitor(HWND main_window, std::function<void(const std::string&)> action, bool background_start) {
  if(current) return false;
  current=new State(); current->live=true; current->production=true; current->preferredVisible=false; current->mainWindow=main_window;
  int argc=0; auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(argv) {
    for(int i=1;i<argc;++i) { std::wstring arg(argv[i]); constexpr wchar_t prefix[]=L"--monitor-report=";
      if(arg.rfind(prefix,0)==0) current->report=arg.substr(std::size(prefix)-1);
      if(arg==L"--monitor-test-controls") current->testControls=true;
      if(arg==L"--monitor-animation-soak") current->animationSoak=true;
    }
    LocalFree(argv);
  }
  current->backgroundStart=background_start;
  current->action=std::move(action);
  current->taskbarCreated=RegisterWindowMessageW(L"TaskbarCreated");
  if(!Register(kOwnerClass,OwnerProc)||!Register(kPetClass,PetProc)) { DetachMonitor(); return false; }
  current->owner=CreateWindowExW(WS_EX_TOOLWINDOW,kOwnerClass,(L"CodexTimeZone.Monitor."+Suffix()).c_str(),
      WS_POPUP,0,0,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  if(!current->owner || !InstallTray()) { DetachMonitor(); return false; }
  current->powerRegistration=RegisterSuspendResumeNotification(current->owner,DEVICE_NOTIFY_WINDOW_HANDLE);
  Report(); return true;
}

void SetRoleEditorOpen(bool open) {
  if(!current || current->production) return;
  current->roleEditorOpen=open;
  if(open) { ShowWindow(current->pet,SW_HIDE); if(IsWindow(current->bubble)) ShowWindow(current->bubble,SW_HIDE); }
  else if(current->preferredVisible) ShowPet();
  SyncAnimation(); Report();
}

void ConfigureRole(const std::wstring& path,const std::wstring& name) {
  if(!current || current->production || (current->rolePath==path && current->roleName==name)) return;
  auto& s=*current; s.rolePath=path; s.roleName=name; s.rolePixels.clear(); s.roleWidth=0;s.roleHeight=0;
  if(!path.empty()) {
    using Microsoft::WRL::ComPtr;
    ComPtr<IWICImagingFactory> factory; ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame; ComPtr<IWICFormatConverter> converter;
    std::error_code ec;
    const auto bytes=std::filesystem::file_size(path,ec);
    if(!ec && bytes<=8*1024*1024 &&
       SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&factory))) &&
       SUCCEEDED(factory->CreateDecoderFromFilename(path.c_str(),nullptr,GENERIC_READ,WICDecodeMetadataCacheOnLoad,&decoder)) &&
       SUCCEEDED(decoder->GetFrame(0,&frame)) && SUCCEEDED(frame->GetSize(&s.roleWidth,&s.roleHeight)) &&
       s.roleWidth>0 && s.roleHeight>0 && s.roleWidth<=2048 && s.roleHeight<=2048 &&
       SUCCEEDED(factory->CreateFormatConverter(&converter)) &&
       SUCCEEDED(converter->Initialize(frame.Get(),GUID_WICPixelFormat32bppPBGRA,WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom))) {
      s.rolePixels.resize(s.roleWidth*s.roleHeight);
      if(FAILED(converter->CopyPixels(nullptr,s.roleWidth*4,static_cast<UINT>(s.rolePixels.size()*4),reinterpret_cast<BYTE*>(s.rolePixels.data())))) s.rolePixels.clear();
    }
  }
  Place(true); DrawPet(); SyncAnimation(); Report();
}

void ReportMonitorState() { if(current) Report(); }
void ConfigureWorkspace(bool keep_alive,const std::string& workspace) {
  if(!current || !current->production) return;
  current->keepAlive=keep_alive; current->workspace=workspace=="monitor"?"monitor":"launcher";
  current->bridgeReady=true; Report();
}
void RecordCloseRequest() { if(current) { ++current->closeRequests; Report(); } }
void HideMonitorMain() {
  if(!current) return;
  ShowWindow(current->mainWindow,SW_HIDE);
  if(!current->backgroundNotices && (current->keepAlive || current->backgroundStart)) {
    ++current->backgroundNotices;
    Notify(L"窗口已隐藏，监控仍在后台运行。双击托盘恢复，托盘菜单可退出。","background",0,"monitorDetails");
  }
  Report();
}

void ConfigureSessionSummary(const std::wstring& summary, double rate, int status) { if(current) { current->sessionSummary=summary; current->sessionRate=rate; current->sessionStatus=status; } }

void ConfigureSessionAlert(const std::wstring& text, int64_t serial) {
  if(!current || !current->live) return;
  auto& s=*current;
  if(s.production) {
    if(text.empty() || serial<=s.sessionAlertSerial) return;
    s.sessionAlertSerial=serial;
    if(s.powerSuspended || s.sessionStatus!=2 || GetTickCount64()<s.quotaPriorityUntil) { ++s.sessionAlertsSuppressed; Report(); return; }
    Notify(text,"session",serial,"sessionDetails"); Report(); return;
  }
  if(text.empty()) {
    // The Dart production TTL is 10s. Only opted-in UI tests retain the
    // same completed-turn bubble longer for a human click; state changes clear it.
    if(s.testControls && s.sessionStatus==2 && GetTickCount64()<s.bubbleUntil) return;
    if(s.sessionBubble) { ShowWindow(s.bubble,SW_HIDE); KillTimer(s.owner,2); }
    Report(); return;
  }
  if(serial<=s.sessionAlertSerial) return;
  s.sessionAlertSerial=serial;
  // Quota alerts take priority. Never defer a stale session event until later.
  if(!s.preferredVisible || s.roleEditorOpen || s.powerSuspended ||
      (IsWindowVisible(s.bubble) && !s.sessionBubble)) { ++s.sessionAlertsSuppressed; Report(); return; }
  const HWND foreground=GetForegroundWindow();
  if(ShowAlert(text,true,false,true)) { ++s.sessionFocusChecks; s.sessionAlertKeptFocus=s.sessionAlertKeptFocus && GetForegroundWindow()==foreground; }
  Report();
}

void PublishMonitor(const std::wstring& text, double remaining, bool stale,
                    bool paused, int64_t revision, int64_t attempts, int64_t failures,
                    const std::wstring& detail, const std::wstring& alert, int64_t alert_serial,
                    bool reduced_motion, int animation_state) {
  if(!current || !current->live) return;
  current->caption=text; current->remaining=std::clamp(remaining,-1.0,100.0);
  current->stale=stale; current->paused=paused; current->revision=revision;
  current->attempts=attempts; current->failures=failures;
  current->detail=detail;
  current->reducedMotion=reduced_motion; current->animationState=std::clamp(animation_state,0,3);
  if((alert.empty() || stale) && !current->companionBubble && !current->sessionBubble) { if(IsWindow(current->bubble)) ShowWindow(current->bubble,SW_HIDE); }
  // A suppressed stale event is consumed, never replayed after a later refresh.
  if(current->production && stale && alert_serial>current->alertSerial) current->alertSerial=alert_serial;
  if(!alert.empty() && !stale && alert_serial>current->alertSerial) {
    if(current->production) {
      current->alertSerial=alert_serial;
      current->quotaPriorityUntil=GetTickCount64()+10000;
      Notify(alert,"quota",alert_serial,"monitorDetails");
    } else if(ShowAlert(alert)) current->alertSerial=alert_serial;
  }
  NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=current->owner;
  icon.uID=1; icon.uFlags=NIF_TIP; wcsncpy_s(icon.szTip,text.c_str(),_TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY,&icon);
  if(!current->production) { SetWindowTextW(current->pet,text.c_str()); SyncAnimation(); DrawPet(); }
  Report();
}

void ConfigureMonitor(int mode, bool visible, int64_t serial) {
  if(!current || !current->live || serial<=current->preferencesSerial) return;
  current->preferencesSerial=serial;
  if(current->production) { current->preferredVisible=false; Report(); return; }
  current->preferredVisible=visible;
  current->mode=std::clamp(mode,0,2);
  Place(false); DrawPet(); SavePosition();
  if(visible) ShowPet(); else { ShowWindow(current->pet,SW_HIDE); if(IsWindow(current->bubble)) ShowWindow(current->bubble,SW_HIDE); }
  SyncAnimation();
  Report();
}

void DetachMonitor() {
  if(current && current->live) {
    SavePosition();
    if(IsWindow(current->bubble)) DestroyWindow(current->bubble);
    if(IsWindow(current->pet)) DestroyWindow(current->pet);
    if(IsWindow(current->owner)) DestroyWindow(current->owner);
    delete current; current=nullptr;
  }
  if(monitorMutex) { CloseHandle(monitorMutex); monitorMutex=nullptr; }
}

int Run(const std::vector<std::wstring>& args) {
  for(const auto& arg:args) {
    constexpr wchar_t prefix[]=L"--probe-displays=";
    if(arg.rfind(prefix,0)==0) return WriteDisplayProbe(arg.substr(std::size(prefix)-1)) ? 0 : 9;
  }
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
  if(state.owner) state.powerRegistration=RegisterSuspendResumeNotification(state.owner,DEVICE_NOTIFY_WINDOW_HANDLE);
  if (!state.owner || !state.pet || (testHost && !state.host) || !InstallTray()) result=5;
  if(!result) { state.dpi=GetDpiForWindow(state.pet); if(!state.dpi) state.dpi=96; ResetPosition(); if(!DrawPet()) result=6; }
  if(!result) {
    ShowPet(); SetTimer(state.owner,1,200,nullptr);
    if(std::find(args.begin(),args.end(),L"--prototype-self-test")!=args.end()) {
      const auto foreground=GetForegroundWindow();
      const auto check=[&](int line, bool condition) { if(condition) ++state.selfChecks; else { result=8; if(!state.selfFailedLine) state.selfFailedLine=line; } };
      check(__LINE__,state.powerRegistration!=nullptr);
      for(UINT command : {kEdge,kCompact,kExpanded}) {
        SendMessageW(state.owner,WM_COMMAND,command,0);
        RECT r{}; GetWindowRect(state.pet,&r);
        check(__LINE__,r.right-r.left==Width() && r.bottom-r.top==Height());
        check(__LINE__,GetForegroundWindow()==foreground);
        check(__LINE__,WindowFromPoint(POINT{r.left+1,r.top+1})!=state.pet);
      }
      // Synthetic topology cases do not claim that physical monitors exist.
      for(const RECT area : {RECT{-1440,-400,0,1480},RECT{0,0,2560,1400},RECT{2560,-1080,4480,0}}) {
        for(UINT dpi : {96u,144u,192u}) for(int mode : {0,1,2}) {
          const int w=pet_geometry::Scale(mode==0 ? 88 : (mode==1 ? 240 : 320),dpi);
          const int h=pet_geometry::Scale(mode==0 ? 72 : (mode==1 ? 160 : 310),dpi);
          RECT position{area.right-w+4,area.bottom-h+4,0,0};
          const auto fitted=pet_geometry::Fit(position,area,w,h,mode==0,pet_geometry::Scale(24,dpi));
          check(__LINE__,fitted.right==area.right && fitted.bottom==area.bottom && fitted.left>=area.left && fitted.top>=area.top);
        }
      }
      for(UINT dpi : {96u,144u,192u}) for(UINT command : {kEdge,kCompact,kExpanded}) {
        SendMessageW(state.owner,WM_COMMAND,command,0);
        RECT r{}; GetWindowRect(state.pet,&r);
        SendMessageW(state.pet,WM_DPICHANGED,MAKELONG(dpi,dpi),reinterpret_cast<LPARAM>(&r));
        GetWindowRect(state.pet,&r);
        check(__LINE__,r.right-r.left==Width() && r.bottom-r.top==Height() && state.dpi==dpi && GetForegroundWindow()==foreground && WindowFromPoint(POINT{r.left+1,r.top+1})!=state.pet);
      }
      RECT original{}; GetWindowRect(state.pet,&original);
      const UINT actualDpi=GetDpiForWindow(state.pet);
      SendMessageW(state.pet,WM_DPICHANGED,MAKELONG(actualDpi,actualDpi),reinterpret_cast<LPARAM>(&original));
      int suspends=0,resumes=0;
      state.action=[&](const std::string& action) { if(action=="systemSuspend") ++suspends; if(action=="systemResume") ++resumes; };
      SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMSUSPEND,0);
      SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMRESUMEAUTOMATIC,0);
      SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMRESUMESUSPEND,0);
      check(__LINE__,suspends==1 && resumes==1 && state.resumeActions==1);
      SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMSUSPEND,0);
      SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMRESUMESUSPEND,0);
      check(__LINE__,suspends==2 && resumes==2 && state.resumeActions==2);
      check(__LINE__,GetForegroundWindow()==foreground);
      state.action=nullptr;
      check(__LINE__,(GetWindowLongPtrW(state.pet,GWL_EXSTYLE)&(WS_EX_NOACTIVATE|WS_EX_LAYERED))==(WS_EX_NOACTIVATE|WS_EX_LAYERED));
      check(__LINE__,ShowAlert(L"自检模拟 10%，非真实用量"));
      check(__LINE__,IsWindowVisible(state.bubble)!=FALSE);
      check(__LINE__,GetForegroundWindow()==foreground);
      SendMessageW(state.bubble,WM_LBUTTONUP,0,0);
      check(__LINE__,!IsWindowVisible(state.bubble) && state.bubbleDismissals==1);
      check(__LINE__,ShowAlert(L"自检自动消失") && IsWindowVisible(state.bubble));
      state.bubbleUntil=0; SendMessageW(state.owner,WM_TIMER,2,0);
      check(__LINE__,!IsWindowVisible(state.bubble));
      state.live=true;
      const auto shown=state.sessionAlertsShown;
      ConfigureSessionAlert(L"自检回合已结束",1);
      check(__LINE__,state.sessionAlertsShown==shown+1 && state.sessionBubble && state.sessionAlertKeptFocus);
      check(__LINE__,(GetWindowLongPtrW(state.bubble,GWL_EXSTYLE)&WS_EX_NOACTIVATE)!=0);
      check(__LINE__,SendMessageW(state.bubble,WM_MOUSEACTIVATE,0,0)==MA_NOACTIVATE);
      check(__LINE__,ShowAlert(L"桌宠回应不覆盖提醒",true,true) && state.sessionBubble);
      ConfigureSessionAlert(L"重复事件",1); check(__LINE__,state.sessionAlertsShown==shown+1);
      PublishMonitor(L"自检",-1,true,true,0,0,0,L"",L"",0,true,3);
      check(__LINE__,IsWindowVisible(state.bubble)!=FALSE);
      ConfigureSessionAlert(L"",1); check(__LINE__,!IsWindowVisible(state.bubble));
      check(__LINE__,ShowAlert(L"优先级自检"));
      ConfigureSessionAlert(L"本条不延迟弹出",2);
      check(__LINE__,state.sessionAlertsShown==shown+1 && state.sessionAlertsSuppressed==1);
      SendMessageW(state.bubble,WM_CLOSE,0,0);
      state.live=false; state.reducedMotion=false; state.stale=false; state.paused=false;
      check(__LINE__,GetForegroundWindow()==foreground);
      SetWindowPos(state.pet,nullptr,-90000,-90000,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER);
      Place(false);
      RECT r{}; GetWindowRect(state.pet,&r);
      MONITORINFO info{}; info.cbSize=sizeof(info);
      GetMonitorInfoW(MonitorFromRect(&r,MONITOR_DEFAULTTONEAREST),&info);
      check(__LINE__,r.left>=info.rcWork.left && r.top>=info.rcWork.top && r.right<=info.rcWork.right && r.bottom<=info.rcWork.bottom);
      SetWindowPos(state.pet,nullptr,info.rcWork.left+12,info.rcWork.top+12,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER);
      Place(true); GetWindowRect(state.pet,&r);
      check(__LINE__,r.left==info.rcWork.left && r.top==info.rcWork.top);
      if(!state.report.empty()) {
        state.settings=state.report.parent_path()/L"fixture-position.txt";
        SavePosition();
        state.mode=1;
        SetWindowPos(state.pet,nullptr,r.left+50,r.top+50,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER);
        ReadPosition();
        RECT restored{}; GetWindowRect(state.pet,&restored);
        check(__LINE__,state.mode==2 && EqualRect(&r,&restored));
        { std::ofstream bad(state.settings); bad<<"1 999 9000000000 -9000000000"; }
        ReadPosition(); check(__LINE__,state.mode==2);
        { std::ofstream bad(state.settings); bad<<"broken"; }
        ReadPosition(); check(__LINE__,state.mode==2);
        SavePosition();
      }
      // Exercise the live renderer without a Flutter engine or account queries.
      state.live=true; state.mode=1; state.stale=false; state.paused=false;
      state.powerSuspended=false; state.animationState=0; Place(false); DrawPet(); ShowPet(); SyncAnimation();
      check(__LINE__,state.animationTimer);
      for(int visual : {0,1,2}) {
        state.animationState=visual;
        for(int frame=0;frame<8;++frame) {
          state.animationFrame=frame; RECT before{}; GetWindowRect(state.pet,&before);
          const bool drawn=DrawPet(); RECT after{}; GetWindowRect(state.pet,&after);
          check(__LINE__,drawn && EqualRect(&before,&after) && GetForegroundWindow()==foreground &&
            WindowFromPoint(POINT{after.left+1,after.top+1})!=state.pet);
        }
      }
      state.reducedMotion=true; SyncAnimation(); check(__LINE__,!state.animationTimer);
      const auto frozen=state.animationFrames;
      SendMessageW(state.owner,WM_TIMER,3,0); check(__LINE__,state.animationFrames==frozen);
      state.reducedMotion=false; ShowWindow(state.pet,SW_HIDE); SyncAnimation(); check(__LINE__,!state.animationTimer);
      ShowPet(); check(__LINE__,state.animationTimer);
      state.paused=true; SyncAnimation(); check(__LINE__,!state.animationTimer);
      state.paused=false; SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMSUSPEND,0); check(__LINE__,!state.animationTimer);
      SendMessageW(state.owner,WM_POWERBROADCAST,PBT_APMRESUMEAUTOMATIC,0); check(__LINE__,state.animationTimer);
      state.stale=true; SyncAnimation(); check(__LINE__,!state.animationTimer);
      state.stale=false; state.dragging=true; SyncAnimation(); check(__LINE__,!state.animationTimer);
      state.dragging=false;
      const DWORD gdiBefore=GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS);
      DWORD handlesBefore=0; GetProcessHandleCount(GetCurrentProcess(),&handlesBefore);
      for(int i=0;i<300;++i) {
        state.mode=i%3; state.animationState=(i/3)%3; state.animationFrame=i%8;
        Place(false); DrawPet();
      }
      DWORD handlesAfter=0; GetProcessHandleCount(GetCurrentProcess(),&handlesAfter);
      check(__LINE__,GetGuiResources(GetCurrentProcess(),GR_GDIOBJECTS)==gdiBefore);
      check(__LINE__,handlesAfter<=handlesBefore+1);
      check(__LINE__,state.drawFailures==0);
      check(__LINE__,GetForegroundWindow()==foreground);
      const HRESULT roleCom=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
      ConfigureRole((std::filesystem::current_path()/L"flutter_app"/L"assets"/L"app_icon.png").wstring(),L"Owned icon fixture");
      check(__LINE__,!state.rolePixels.empty());
      state.mode=1; check(__LINE__,BaseHeight()==320); check(__LINE__,!AnimationAllowed()); check(__LINE__,DrawPet());
      state.mode=2; check(__LINE__,BaseHeight()==470);
      state.mode=0; check(__LINE__,BaseHeight()==72);
      ConfigureRole(L"missing-role-test.png",L"Missing"); check(__LINE__,state.rolePixels.empty());
      state.mode=1; check(__LINE__,BaseHeight()==160);
      const int quotaAlerts=state.alertsShown;
      SendMessageW(state.owner,WM_COMMAND,kPetTouch,0);
      check(__LINE__,state.companionBubble && IsWindowVisible(state.bubble));
      check(__LINE__,state.alertsShown==quotaAlerts);
      SendMessageW(state.bubble,WM_LBUTTONUP,0,0);
      SetRoleEditorOpen(true); check(__LINE__,!IsWindowVisible(state.pet));
      SetRoleEditorOpen(false); check(__LINE__,IsWindowVisible(state.pet));
      if(SUCCEEDED(roleCom)) CoUninitialize();
      state.live=false; SyncAnimation();
      Report();
      DestroyWindow(state.owner);
    }
    MSG message{}; int status=0;
    while((status=static_cast<int>(GetMessageW(&message,nullptr,0,0)))>0) {
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    if(status<0) result=7;
  }
  if(IsWindow(state.pet)) DestroyWindow(state.pet);
  if(IsWindow(state.bubble)) DestroyWindow(state.bubble);
  if(IsWindow(state.host)) DestroyWindow(state.host);
  if(IsWindow(state.owner)) DestroyWindow(state.owner);
  CloseHandle(mutex); current=nullptr; return result;
}
}
