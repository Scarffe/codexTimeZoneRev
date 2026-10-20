#include "desktop_prototype.h"
#include "package_context.h"
#include <windows.h>
#include <shellapi.h>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int count=0; auto argv=CommandLineToArgvW(GetCommandLineW(),&count);
  if(!argv) return 1;
  std::vector<std::wstring> args;
  for(int i=1;i<count;++i) args.emplace_back(argv[i]);
  LocalFree(argv);
  const int prepared=package_context::Prepare(args);
  if(prepared!=-1) return prepared;
  return desktop_prototype::Run(args);
}
