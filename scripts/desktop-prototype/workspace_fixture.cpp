#include "desktop_prototype.h"
#include <windows.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>

int wmain(int argc, wchar_t** argv) {
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
  HWND owner=FindWindowW(L"CodexTimeZone.StageA.Owner",nullptr);
  HWND pet=FindWindowW(L"CodexTimeZone.StageA.Pet",nullptr);
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
  desktop_prototype::DetachMonitor(); DestroyWindow(main);
  std::cout<<checks<<" checks, "<<failures<<" failed\n"; return failures?1:0;
}
