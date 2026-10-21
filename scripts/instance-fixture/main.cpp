#include "app_instance.h"
#include <fstream>

std::filesystem::path report;
void State(HWND hwnd) {
  std::ofstream out(report); out<<"{\"pid\":"<<GetCurrentProcessId()<<",\"visible\":"<<(IsWindowVisible(hwnd)?"true":"false")<<"}";
}
LRESULT CALLBACK Procedure(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
  if(msg==WM_SHOWWINDOW) {PostMessageW(hwnd,WM_APP+1,0,0);return 0;}
  if(msg==WM_APP+1) {State(hwnd);return 0;}
  return DefWindowProcW(hwnd,msg,wp,lp);
}
int wmain(int argc,wchar_t** argv) {
  std::vector<std::wstring> args; for(int i=1;i<argc;++i) args.emplace_back(argv[i]);
  const auto option=[&](const wchar_t* prefix) {for(const auto& a:args) if(a.rfind(prefix,0)==0) return a.substr(wcslen(prefix));return std::wstring();};
  const auto scope=option(L"--scope="),output=option(L"--output="),quit=option(L"--quit=");
  if(scope.empty()||output.empty()||quit.empty()) return 10;
  app_instance::Options options;options.name+=L".Fixture."+scope;
  options.title=L"CodexTimeZone instance fixture "+scope;
  options.windowClass=L"CodexTimeZone.Instance.Fixture";
  options.isolated=app_instance::Has(args,L"--isolated-instance");
  if(!option(L"--wait=").empty()) options.waitMs=static_cast<DWORD>(std::stoul(option(L"--wait=")));
  app_instance::Lease lease;
  const auto decision=app_instance::Has(args,L"--legacy")?app_instance::Decision::start:lease.Claim(options);
  DWORD target=0;app_instance::Existing(options,&target);
  {std::ofstream out{std::filesystem::path(output)};out<<"{\"pid\":"<<GetCurrentProcessId()<<",\"decision\":\""<<(decision==app_instance::Decision::start?"start":decision==app_instance::Decision::reused?"reused":"failed")<<"\",\"target\":"<<target<<"}";}
  if(decision!=app_instance::Decision::start) return decision==app_instance::Decision::reused?0:4;
  if(app_instance::Has(args,L"--held")) {Sleep(2000);return 0;}
  if(!option(L"--delay=").empty()) Sleep(static_cast<DWORD>(std::stoul(option(L"--delay="))));
  report=std::filesystem::path(output+L".state");
  WNDCLASSW cls{};cls.hInstance=GetModuleHandleW(nullptr);cls.lpfnWndProc=Procedure;cls.lpszClassName=options.windowClass.c_str();
  if(!RegisterClassW(&cls)) return 11;
  HWND window=CreateWindowW(cls.lpszClassName,options.title.c_str(),WS_OVERLAPPEDWINDOW,40,40,350,100,nullptr,nullptr,cls.hInstance,nullptr);
  if(!window) return 12;
  if(!app_instance::Has(args,L"--legacy")) app_instance::Mark(window,options.isolated);
  State(window);
  HANDLE stop=CreateEventW(nullptr,TRUE,FALSE,quit.c_str());if(!stop) return 13;
  const auto deadline=GetTickCount64()+20000;
  while(GetTickCount64()<deadline && WaitForSingleObject(stop,0)!=WAIT_OBJECT_0) {
    MsgWaitForMultipleObjects(1,&stop,FALSE,50,QS_ALLINPUT);
    MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
  }
  DestroyWindow(window);CloseHandle(stop);return 0;
}
