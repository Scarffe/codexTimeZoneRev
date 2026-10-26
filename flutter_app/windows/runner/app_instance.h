#ifndef RUNNER_APP_INSTANCE_H_
#define RUNNER_APP_INSTANCE_H_
#include <windows.h>
#include <shellapi.h>
#include <algorithm>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <string>
#include <vector>
#pragma comment(lib, "advapi32.lib")

namespace app_instance {
constexpr wchar_t kIsolatedProperty[]=L"CodexTimeZone.Isolated.v1";
constexpr wchar_t kPrimaryProperty[]=L"CodexTimeZone.Primary.v1";
enum class Decision { start, reused, failed };
struct Options {
  std::wstring name=L"CodexTimeZone.Application.v1";
  std::wstring title=L"Codex 时区启动器";
  std::wstring windowClass=L"FLUTTER_RUNNER_WIN32_WINDOW";
  std::wstring executable=L"codex_timezone.exe";
  bool isolated=false;
  DWORD waitMs=15000;
};
inline bool Has(const std::vector<std::wstring>& args,const wchar_t* flag) {
  return std::find(args.begin(),args.end(),flag)!=args.end();
}
inline bool IsolatedProcess() {
  static const bool isolated=[] {
    int count=0; auto args=CommandLineToArgvW(GetCommandLineW(),&count); bool result=false;
    if(args) { for(int i=1;i<count;++i) if(std::wstring(args[i])==L"--isolated-instance") result=true; LocalFree(args); }
    return result;
  }();
  return isolated;
}
inline std::wstring Lower(std::wstring text) {
  std::transform(text.begin(),text.end(),text.begin(),[](wchar_t c){return static_cast<wchar_t>(std::towlower(c));}); return text;
}
inline std::wstring ImagePath(HANDLE process) {
  wchar_t path[32768]{}; DWORD size=static_cast<DWORD>(std::size(path));
  return QueryFullProcessImageNameW(process,0,path,&size)?std::wstring(path,size):L"";
}
inline std::vector<BYTE> User(HANDLE process) {
  HANDLE token=nullptr; if(!OpenProcessToken(process,TOKEN_QUERY,&token)) return {};
  DWORD size=0; GetTokenInformation(token,TokenUser,nullptr,0,&size);
  std::vector<BYTE> buffer(size);
  if(!size || !GetTokenInformation(token,TokenUser,buffer.data(),size,&size)) buffer.clear();
  CloseHandle(token); return buffer;
}
inline std::uint64_t Hash(const void* data,size_t size) {
  auto bytes=static_cast<const BYTE*>(data); std::uint64_t hash=14695981039346656037ULL;
  for(size_t i=0;i<size;++i) {hash^=bytes[i];hash*=1099511628211ULL;} return hash;
}
inline std::wstring Identity(const Options& options) {
  const auto user=User(GetCurrentProcess()); if(user.empty()) return L"";
  const auto sid=reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid;
  DWORD session=0; if(!ProcessIdToSessionId(GetCurrentProcessId(),&session)) return L"";
  auto name=options.name+L"."+std::to_wstring(session)+L"."+std::to_wstring(Hash(sid,GetLengthSid(sid)));
  if(options.isolated) { auto path=Lower(ImagePath(GetCurrentProcess())); name+=L".test."+std::to_wstring(Hash(path.data(),path.size()*sizeof(wchar_t))); }
  return name;
}
struct Search {
  const Options* options;
  std::vector<BYTE> user;
  HWND window=nullptr;
  DWORD pid=0;
  ULONGLONG created=0;
  bool primary=false;
};
inline BOOL CALLBACK FindWindow(HWND window,LPARAM parameter) {
  auto& found=*reinterpret_cast<Search*>(parameter); const auto& o=*found.options;
  DWORD pid=0; GetWindowThreadProcessId(window,&pid); if(!pid || pid==GetCurrentProcessId()) return TRUE;
  wchar_t cls[128]{},title[256]{}; GetClassNameW(window,cls,128); GetWindowTextW(window,title,256);
  // Display titles are localized. The properties installed by Mark identify
  // current runners; the old Chinese title still admits unmarked legacy ones.
  const bool marked=GetPropW(window,kPrimaryProperty)!=nullptr ||
      GetPropW(window,kIsolatedProperty)!=nullptr;
  if(o.windowClass!=cls || (!marked && o.title!=title)) return TRUE;
  if((GetPropW(window,kIsolatedProperty)!=nullptr)!=o.isolated) return TRUE;
  HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid); if(!process) return TRUE;
  const auto path=ImagePath(process); const auto user=User(process);
  const bool sameUser=!user.empty() && EqualSid(reinterpret_cast<const TOKEN_USER*>(found.user.data())->User.Sid,reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid);
  const bool sameExe=Lower(std::filesystem::path(path).filename().wstring())==Lower(o.executable);
  const bool samePath=!o.isolated || Lower(path)==Lower(ImagePath(GetCurrentProcess()));
  FILETIME create{},exit{},kernel{},cpu{}; GetProcessTimes(process,&create,&exit,&kernel,&cpu); CloseHandle(process);
  if(!sameUser || !sameExe || !samePath) return TRUE;
  const ULONGLONG created=(static_cast<ULONGLONG>(create.dwHighDateTime)<<32)|create.dwLowDateTime;
  const bool primary=GetPropW(window,kPrimaryProperty)!=nullptr;
  // Prefer the elected primary; legacy candidates have no marker: newest wins.
  if(!found.window || (primary && !found.primary) || (primary==found.primary && created>found.created)) {
    found.window=window;found.pid=pid;found.created=created;found.primary=primary;
  }
  return TRUE;
}
inline HWND Existing(const Options& options,DWORD* pid=nullptr) {
  auto user=User(GetCurrentProcess()); if(user.empty()) return nullptr;
  Search found{&options,std::move(user)};
  EnumWindows(FindWindow,reinterpret_cast<LPARAM>(&found)); if(pid) *pid=found.pid; return found.window;
}
inline bool Restore(HWND window,DWORD pid) {
  if(!IsWindow(window)) return false;
  AllowSetForegroundWindow(pid);
  ShowWindowAsync(window,SW_RESTORE);
  SetForegroundWindow(window);
  return true;
}
class Lease {
  HANDLE handle_=nullptr;
 public:
  Lease()=default;
  Lease(const Lease&)=delete;
  Lease& operator=(const Lease&)=delete;
  ~Lease(){if(handle_) CloseHandle(handle_);}
  Decision Claim(const Options& options={}) {
    const auto identity=Identity(options); if(identity.empty() || handle_) return Decision::failed;
    HANDLE candidate=CreateMutexW(nullptr,FALSE,(L"Local\\"+identity).c_str());
    if(!candidate) return Decision::failed;
    const bool occupied=GetLastError()==ERROR_ALREADY_EXISTS;
    const auto deadline=GetTickCount64()+options.waitMs;
    do {
      DWORD pid=0; HWND window=Existing(options,&pid);
      if(window) { const bool restored=Restore(window,pid);CloseHandle(candidate);return restored?Decision::reused:Decision::failed; }
      if(!occupied) {handle_=candidate;return Decision::start;}
      Sleep(50);
    } while(GetTickCount64()<deadline);
    // A starting instance owns the lease. Do not create a second engine.
    CloseHandle(candidate); return Decision::failed;
  }
};
inline void Mark(HWND window,bool isolated) {
  SetPropW(window,isolated?kIsolatedProperty:kPrimaryProperty,reinterpret_cast<HANDLE>(1));
}
}
#endif

