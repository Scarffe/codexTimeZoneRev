#include "desktop_prototype.h"
#include <windows.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>
#include <shellapi.h>

namespace {
constexpr wchar_t kOwnerClass[]=L"CodexTimeZone.StageA.Owner";
constexpr wchar_t kPetClass[]=L"CodexTimeZone.StageA.Pet";
std::filesystem::path decoyReport;
HWND decoyOwner=nullptr,decoyPet=nullptr;
int decoyMutations=0;
void WriteDecoy() {
  std::ofstream out(decoyReport);
  out<<GetCurrentProcessId()<<' '<<reinterpret_cast<uintptr_t>(decoyOwner)<<' '
     <<reinterpret_cast<uintptr_t>(decoyPet)<<' '<<decoyMutations;
}
LRESULT CALLBACK DecoyProc(HWND hwnd,UINT message,WPARAM wp,LPARAM lp) {
  if(message==WM_COMMAND || message==WM_APP+72 || message==WM_POWERBROADCAST) {
    ++decoyMutations; WriteDecoy(); return 0;
  }
  return DefWindowProcW(hwnd,message,wp,lp);
}
int RunDecoy(const wchar_t* output,const wchar_t* stopName) {
  decoyReport=output;
  WNDCLASSW cls{}; cls.lpfnWndProc=DecoyProc; cls.hInstance=GetModuleHandleW(nullptr);
  cls.lpszClassName=kOwnerClass; if(!RegisterClassW(&cls)) return 10;
  cls.lpszClassName=kPetClass; if(!RegisterClassW(&cls)) return 11;
  decoyOwner=CreateWindowExW(WS_EX_TOOLWINDOW,kOwnerClass,L"Foreign fixture decoy owner",WS_POPUP,
      0,0,1,1,nullptr,nullptr,cls.hInstance,nullptr);
  decoyPet=CreateWindowExW(WS_EX_TOOLWINDOW,kPetClass,L"Foreign fixture decoy pet",WS_POPUP,
      0,0,1,1,nullptr,nullptr,cls.hInstance,nullptr);
  if(!decoyOwner || !decoyPet) return 12;
  HANDLE stop=OpenEventW(SYNCHRONIZE,FALSE,stopName); if(!stop) return 13;
  WriteDecoy();
  const auto deadline=GetTickCount64()+15000;
  while(GetTickCount64()<deadline && WaitForSingleObject(stop,0)!=WAIT_OBJECT_0) {
    MsgWaitForMultipleObjects(1,&stop,FALSE,50,QS_ALLINPUT);
    MSG message{}; while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
  }
  WriteDecoy(); DestroyWindow(decoyPet); DestroyWindow(decoyOwner); CloseHandle(stop); return 0;
}
struct ForeignDecoy {
  HANDLE stop=nullptr,process=nullptr;
  DWORD pid=0; HWND owner=nullptr,pet=nullptr;
  std::filesystem::path report;
  ~ForeignDecoy() { if(stop) SetEvent(stop); if(process) { WaitForSingleObject(process,5000); CloseHandle(process); } if(stop) CloseHandle(stop); }
  bool Start(const std::filesystem::path& output) {
    report=output;
    const auto stopName=L"Local\\CodexTimeZone.WorkspaceDecoy.Stop."+std::to_wstring(GetCurrentProcessId());
    stop=CreateEventW(nullptr,TRUE,FALSE,stopName.c_str()); if(!stop) return false;
    wchar_t executable[32768]{}; GetModuleFileNameW(nullptr,executable,32768);
    std::wstring command=L"\""+std::wstring(executable)+L"\" --workspace-foreign-decoy \""+report.wstring()+L"\" \""+stopName+L"\"";
    STARTUPINFOW startup{}; startup.cb=sizeof(startup); startup.dwFlags=STARTF_USESHOWWINDOW; startup.wShowWindow=SW_HIDE;
    PROCESS_INFORMATION child{};
    if(!CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child)) return false;
    process=child.hProcess; pid=child.dwProcessId; CloseHandle(child.hThread);
    const auto deadline=GetTickCount64()+5000;
    while(GetTickCount64()<deadline) {
      DWORD reportedPid=0; uintptr_t ownerValue=0,petValue=0; int mutations=-1;
      std::ifstream in(report);
      if(in>>reportedPid>>ownerValue>>petValue>>mutations && reportedPid==pid && ownerValue && petValue) {
        owner=reinterpret_cast<HWND>(ownerValue); pet=reinterpret_cast<HWND>(petValue);
        // Put this owned decoy before the app owner to reproduce unscoped lookup.
        SetWindowPos(owner,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
        return mutations==0;
      }
      Sleep(20);
    }
    return false;
  }
  bool Untouched() const {
    DWORD reportedPid=0; uintptr_t ownerValue=0,petValue=0; int mutations=-1;
    std::ifstream in(report); in>>reportedPid>>ownerValue>>petValue>>mutations;
    return reportedPid==pid && mutations==0 && IsWindow(owner) && IsWindow(pet);
  }
};
struct OwnWindowSearch { const wchar_t* windowClass; HWND window=nullptr; };
BOOL CALLBACK FindOwnWindow(HWND window,LPARAM parameter) {
  auto& search=*reinterpret_cast<OwnWindowSearch*>(parameter);
  DWORD pid=0; GetWindowThreadProcessId(window,&pid);
  if(pid!=GetCurrentProcessId()) return TRUE;
  wchar_t windowClass[128]{};
  if(GetClassNameW(window,windowClass,static_cast<int>(std::size(windowClass))) &&
      std::wstring(windowClass)==search.windowClass) { search.window=window; return FALSE; }
  return TRUE;
}
HWND CurrentProcessWindow(const wchar_t* windowClass) {
  OwnWindowSearch search{windowClass};
  EnumWindows(FindOwnWindow,reinterpret_cast<LPARAM>(&search)); return search.window;
}
bool OwnedByCurrentProcess(HWND window) {
  DWORD pid=0; if(window) GetWindowThreadProcessId(window,&pid); return window && pid==GetCurrentProcessId();
}
}

int wmain(int argc, wchar_t** argv) {
  if(argc==4 && std::wstring(argv[1])==L"--workspace-foreign-decoy") return RunDecoy(argv[2],argv[3]);
  if (argc < 2) return 2;
  const std::filesystem::path report(argv[1]);
  HWND main = CreateWindowExW(0,L"STATIC",L"Workspace native fixture",WS_OVERLAPPEDWINDOW,
      0,0,400,300,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  std::vector<std::string> actions;
  int failures=0,checks=0;
  const auto check=[&](bool pass,const char* name) {
    ++checks; std::cout<<(pass?"PASS ":"FAIL ")<<name<<'\n'; if(!pass) ++failures;
  };
  const auto snapshot=[&] {
    desktop_prototype::ReportMonitorState(); std::ifstream in(report); std::ostringstream out; out<<in.rdbuf(); return out.str();
  };
  check(desktop_prototype::AttachMonitor(main,[&](const std::string& a){ actions.push_back(a); }),"attach live native monitor");
  ForeignDecoy decoy;
  check(decoy.Start(report.wstring()+L".decoy"),"foreign same-class decoy starts in separate owned process");
  HWND owner=CurrentProcessWindow(kOwnerClass);
  HWND pet=CurrentProcessWindow(kPetClass);
  check(OwnedByCurrentProcess(owner),"fixture owner lookup targets only current process");
  check(pet==nullptr,"production creates no current-process pet HWND");
  if(!OwnedByCurrentProcess(owner) || pet!=nullptr) {
    check(decoy.Untouched(),"foreign decoy remains untouched before failed ownership guard");
    desktop_prototype::DetachMonitor(); DestroyWindow(main);
    std::cout<<checks<<" checks, "<<failures<<" failed\n"; return 1;
  }
  desktop_prototype::ConfigureMonitor(2,true,5);
  check(!IsWindowVisible(pet),"legacy petVisible true cannot expose production pet");
  for (UINT command : {100u,102u,110u,111u,112u,125u,127u}) SendMessageW(owner,WM_COMMAND,command,0);
  desktop_prototype::SetRoleEditorOpen(false);
  SendMessageW(owner,WM_APP+72,0,0);
  SendMessageW(owner,WM_POWERBROADCAST,PBT_APMSUSPEND,0);
  SendMessageW(owner,WM_POWERBROADCAST,PBT_APMRESUMEAUTOMATIC,0);
  check(!IsWindowVisible(pet),"legacy commands restore and resume keep production pet paused");
  auto before=snapshot();
  check(before.find("\"petPaused\":true")!=std::string::npos,"report identifies production pet paused");
  desktop_prototype::ConfigureSessionSummary(L"fixture completed",1.0,2);
  desktop_prototype::PublishMonitor(L"Fixture",10,false,false,1,0,0,L"",L"quota fixture",1);
  desktop_prototype::ConfigureSessionAlert(L"session lower priority",1);
  auto quota=snapshot();
  check(quota.find("\"notificationKind\":\"quota\"")!=std::string::npos,"quota notice is independent and takes priority");
  desktop_prototype::PublishMonitor(L"Fixture",10,false,false,2,0,0,L"",L"quota fixture",1);
  check(snapshot().find("\"notificationAttempts\":1")!=std::string::npos,"same quota serial deduplicates");
  SendMessageW(owner,WM_COMMAND,1125,0);
  check(!actions.empty() && actions.back()=="monitorDetails","quota injected click routes monitor details");
  desktop_prototype::ConfigureSessionAlert(L"session fixture",2);
  check(snapshot().find("\"notificationKind\":\"session\"")!=std::string::npos,"session notice works while pet paused");
  SendMessageW(owner,WM_COMMAND,1125,0);
  check(!actions.empty() && actions.back()=="sessionDetails","session injected click routes session details");
  check(snapshot().find("\"notificationClickInjections\":2")!=std::string::npos,"callback injections are explicitly counted");
  check(snapshot().find("\"notificationKeptFocus\":true")!=std::string::npos,"notification publication preserves focus");
  desktop_prototype::PublishMonitor(L"Stale",10,true,false,3,0,0,L"",L"stale quota",2);
  desktop_prototype::PublishMonitor(L"Fresh",10,false,false,4,0,0,L"",L"stale quota",2);
  check(snapshot().find("\"notificationAttempts\":2")!=std::string::npos,"stale quota event is consumed without delayed replay");
  desktop_prototype::ConfigureSessionSummary(L"cancelled",-1,3);
  desktop_prototype::ConfigureSessionAlert(L"cancelled event",3);
  check(snapshot().find("\"notificationAttempts\":2")!=std::string::npos,"cancelled turn never produces completion notice");
  desktop_prototype::ConfigureWorkspace(true,"monitor");
  desktop_prototype::HideMonitorMain(); desktop_prototype::HideMonitorMain();
  const auto hidden=snapshot();
  check(hidden.find("\"keepAlive\":true")!=std::string::npos && hidden.find("\"workspace\":\"monitor\"")!=std::string::npos,"workspace and close keepAlive snapshot are retained");
  check(hidden.find("\"backgroundNotices\":1")!=std::string::npos && !IsWindowVisible(main),"hide gives background-running notice once");
  desktop_prototype::ConfigureRole((std::filesystem::current_path()/L"flutter_app/assets/app_icon.png").wstring(),L"legacy role");
  check(snapshot().find("\"roleLoaded\":false")!=std::string::npos,"production ignores legacy role decoding");
  desktop_prototype::DetachMonitor();
  check(desktop_prototype::AttachMonitor(main,[&](const std::string& a){ actions.push_back(a); },true),"explicit background native initialization succeeds");
  check(snapshot().find("\"backgroundStart\":true")!=std::string::npos && !IsWindowVisible(main),"background attach leaves main hidden");
  check(decoy.Untouched(),"foreign same-class owner and pet receive no fixture mutations");
  desktop_prototype::DetachMonitor(); DestroyWindow(main);
  std::cout<<checks<<" checks, "<<failures<<" failed\n"; return failures?1:0;
}
