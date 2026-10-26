// Windows-only isolated research probe. No credential input or stdout stealing.
// Compile with: cl /nologo /std:c++17 /EHsc /W4 stdio_runtime_probe.cpp
// Default modes only query identity or enumerate pipe metadata. Only a process
// running THIS executable in --fixture-server mode may receive a probe write.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winternl.h>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using NtQueryProcess = LONG (NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
using NtQueryObjectFn = LONG (NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
struct HandleEntry { HANDLE handle; ULONG_PTR handle_count, pointer_count;
  ULONG access, type_index, attributes, reserved; };
struct HandleSnapshot { ULONG_PTR count, reserved; HandleEntry entries[1]; };
struct NativeBasic { LONG exit_status; PVOID peb; ULONG_PTR affinity;
  LONG priority; ULONG_PTR pid, parent_pid; };
struct OwnedHandle { HANDLE h = nullptr; OwnedHandle() = default;
  explicit OwnedHandle(HANDLE value):h(value){}
  ~OwnedHandle(){if(h && h != INVALID_HANDLE_VALUE) CloseHandle(h);}
  OwnedHandle(const OwnedHandle&)=delete; OwnedHandle& operator=(const OwnedHandle&)=delete;
};
struct Identity { DWORD pid, parent; uint64_t created; std::wstring path; };
struct Pipe { uintptr_t handle; ULONG access; DWORD server, client, flags; std::wstring name; };

static std::string utf8(const std::wstring& s) {
  if(s.empty()) return {};
  int n=WideCharToMultiByte(CP_UTF8,0,s.data(),static_cast<int>(s.size()),nullptr,0,nullptr,nullptr);
  std::string out(n,'\0');WideCharToMultiByte(CP_UTF8,0,s.data(),static_cast<int>(s.size()),out.data(),n,nullptr,nullptr);return out;
}
static std::string quoted(const std::wstring& s) {
  std::string out="\"";for(unsigned char c:utf8(s)) {
    if(c=='"'||c=='\\'){out+='\\';out+=static_cast<char>(c);}
    else if(c>=32) out+=static_cast<char>(c);
  } return out+'"';
}
static std::wstring own_path(){std::wstring p(32768,L'\0');DWORD n=GetModuleFileNameW(nullptr,p.data(),static_cast<DWORD>(p.size()));p.resize(n);return p;}
static bool same_path(const std::wstring& a,const std::wstring& b){return _wcsicmp(a.c_str(),b.c_str())==0;}
static NtQueryProcess query_process(){return reinterpret_cast<NtQueryProcess>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryInformationProcess"));}
static NtQueryObjectFn query_object(){return reinterpret_cast<NtQueryObjectFn>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryObject"));}
static Identity identity(DWORD pid,HANDLE process) {
  FILETIME c{},e{},k{},u{};if(!GetProcessTimes(process,&c,&e,&k,&u))throw std::runtime_error("process times unavailable");
  std::wstring p(32768,L'\0');DWORD n=static_cast<DWORD>(p.size());if(!QueryFullProcessImageNameW(process,0,p.data(),&n))throw std::runtime_error("process path unavailable");p.resize(n);
  NativeBasic b{};if(query_process()(process,0,&b,sizeof(b),nullptr)<0)throw std::runtime_error("process parent unavailable");
  return {pid,static_cast<DWORD>(b.parent_pid),(static_cast<uint64_t>(c.dwHighDateTime)<<32)|c.dwLowDateTime,p};
}
static void print_identity(const char* key,const Identity& i){std::cout<<'"'<<key<<"\":{\"pid\":"<<i.pid<<",\"parentPid\":"<<i.parent<<",\"created\":"<<i.created<<",\"path\":"<<quoted(i.path)<<'}';}
static std::vector<HandleEntry> snapshot(HANDLE p) {
  ULONG size=65536,needed=0;for(int i=0;i<10;i++){
    std::vector<unsigned char> b(size);LONG status=query_process()(p,51,b.data(),size,&needed);
    if(status>=0){auto* s=reinterpret_cast<HandleSnapshot*>(b.data());
      if(s->count>100000 || 2*sizeof(ULONG_PTR)+s->count*sizeof(HandleEntry)>b.size())throw std::runtime_error("invalid handle snapshot");
      return {s->entries,s->entries+s->count};}
    size=std::max(size*2,needed);
  }throw std::runtime_error("handle snapshot unavailable");
}
static std::wstring pipe_name(HANDLE h) {
  std::vector<unsigned char> b(65536);ULONG needed=0;
  if(query_object()(h,1,b.data(),static_cast<ULONG>(b.size()),&needed)<0)return {};
  auto* s=reinterpret_cast<UNICODE_STRING*>(b.data());return s->Buffer?std::wstring(s->Buffer,s->Length/sizeof(wchar_t)):L"";
}
// Runs potentially blocking pipe metadata calls in an expendable helper.
// The controller can terminate this helper without touching the target process.
static int query_one(DWORD pid,uintptr_t value,ULONG access) {
  OwnedHandle p(OpenProcess(PROCESS_DUP_HANDLE,FALSE,pid));if(!p.h)return 2;
  HANDLE d=nullptr;if(!DuplicateHandle(p.h,reinterpret_cast<HANDLE>(value),GetCurrentProcess(),&d,0,FALSE,DUPLICATE_SAME_ACCESS))return 3;
  OwnedHandle h(d);if(GetFileType(d)!=FILE_TYPE_PIPE)return 4;
  DWORD server=0,client=0,flags=0;if(!GetNamedPipeServerProcessId(d,&server)||!GetNamedPipeClientProcessId(d,&client)||!GetNamedPipeInfo(d,&flags,nullptr,nullptr,nullptr))return 5;
  std::wstring name=pipe_name(d);if(name.empty())return 6;
  std::wcout<<value<<L'\t'<<access<<L'\t'<<server<<L'\t'<<client<<L'\t'<<flags<<L'\t'<<name<<L'\n';return 0;
}
static bool bounded_pipe_query(DWORD pid,const HandleEntry& e,Pipe& out) {
  SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE rd=nullptr,wr=nullptr;
  if(!CreatePipe(&rd,&wr,&sa,0))throw std::runtime_error("helper control pipe unavailable");
  OwnedHandle reader(rd),writer(wr);SetHandleInformation(rd,HANDLE_FLAG_INHERIT,0);
  OwnedHandle nullin(CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr));
  std::wstring cmd=L"\""+own_path()+L"\" --query-one "+std::to_wstring(pid)+L" "+std::to_wstring(reinterpret_cast<uintptr_t>(e.handle))+L" "+std::to_wstring(e.access);
  STARTUPINFOW si{};si.cb=sizeof(si);si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=nullin.h;si.hStdOutput=wr;si.hStdError=wr;PROCESS_INFORMATION pi{};
  if(!CreateProcessW(nullptr,cmd.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&si,&pi))return false;
  OwnedHandle process(pi.hProcess),thread(pi.hThread);CloseHandle(writer.h);writer.h=nullptr;
  if(WaitForSingleObject(process.h,750)!=WAIT_OBJECT_0){TerminateProcess(process.h,124);WaitForSingleObject(process.h,2000);return false;}
  DWORD code=0;GetExitCodeProcess(process.h,&code);if(code!=0)return false;
  std::string text;char b[4096];DWORD n=0;while(ReadFile(rd,b,sizeof(b),&n,nullptr)&&n)text.append(b,n);
  int chars=MultiByteToWideChar(CP_UTF8,0,text.data(),static_cast<int>(text.size()),nullptr,0);
  std::wstring wide(chars,L'\0');MultiByteToWideChar(CP_UTF8,0,text.data(),static_cast<int>(text.size()),wide.data(),chars);
  std::wistringstream in(wide);wchar_t tab=0;in>>out.handle>>out.access>>out.server>>out.client>>out.flags;in.get(tab);std::getline(in,out.name);
  // A text-mode Windows helper writes CRLF. JSON rendering hid the trailing CR
  // during enum output; retain an exact metadata name before matching instead.
  if(!out.name.empty() && out.name.back()==L'\r')out.name.pop_back();
  return !out.name.empty();
}
static void write_fixture(HANDLE parent,const Pipe& p) {
  HANDLE d=nullptr;if(!DuplicateHandle(parent,reinterpret_cast<HANDLE>(p.handle),GetCurrentProcess(),&d,0,FALSE,DUPLICATE_SAME_ACCESS))throw std::runtime_error("write handle duplication unavailable");
  OwnedHandle pipe(d),event(CreateEventW(nullptr,TRUE,FALSE,nullptr));if(!event.h)throw std::runtime_error("event unavailable");
  OVERLAPPED ov{};ov.hEvent=reinterpret_cast<HANDLE>(reinterpret_cast<uintptr_t>(event.h)|1);
  // Low event bit prevents broker OVERLAPPED pointers reaching parent's IOCP.
  const std::string frame="{\"id\":\"thread/read:ctz-hot-fixture\",\"method\":\"fixture/auth-update\"}\n";
  DWORD written=0;BOOL ok=WriteFile(d,frame.data(),static_cast<DWORD>(frame.size()),&written,&ov);
  if(!ok && GetLastError()!=ERROR_IO_PENDING)throw std::runtime_error("fixture write rejected");
  if(!ok && WaitForSingleObject(event.h,5000)!=WAIT_OBJECT_0){CancelIoEx(d,&ov);GetOverlappedResult(d,&ov,&written,TRUE);throw std::runtime_error("fixture write timeout");}
  if(!GetOverlappedResult(d,&ov,&written,FALSE)||written!=frame.size())throw std::runtime_error("fixture incomplete write");
}
static int fixture_server(){
  HANDLE input=GetStdHandle(STD_INPUT_HANDLE);
  std::cout<<"{\"method\":\"fixture/ready\",\"params\":{\"pid\":"<<GetCurrentProcessId()<<",\"stdinHandle\":"<<reinterpret_cast<uintptr_t>(input)<<",\"stdinName\":"<<quoted(pipe_name(input))<<"}}\n"<<std::flush;
  std::string line;int revision=0;while(std::getline(std::cin,line)){
    if(line.find("fixture/exit")!=std::string::npos)return 0;
    if(line.find("fixture/auth-update")!=std::string::npos){revision++;std::cout<<"{\"method\":\"account/updated\",\"params\":{\"authMode\":\"fixture\",\"authRevision\":"<<revision<<"}}\n";}
    std::cout<<"{\"method\":\"fixture/received\",\"params\":{\"authRevision\":"<<revision<<"}}\n"<<std::flush;
  }return 0;
}
int wmain(int argc,wchar_t** argv){
  SetConsoleOutputCP(CP_UTF8);std::ios::sync_with_stdio(false);
  try {
    if(argc==2 && std::wstring(argv[1])==L"--fixture-server")return fixture_server();
    if(argc==5 && std::wstring(argv[1])==L"--query-one")return query_one(std::stoul(argv[2]),std::stoull(argv[3]),std::stoul(argv[4]));
    if(argc<2)throw std::runtime_error("mode required: --identity-only, --enum-only, --fixture-write");
    std::wstring mode=argv[1];std::map<std::wstring,std::wstring> args;
    for(int i=2;i+1<argc;i+=2)args[argv[i]]=argv[i+1];
    DWORD parent_pid=std::stoul(args.at(L"--parent-pid")),child_pid=std::stoul(args.at(L"--child-pid"));
    OwnedHandle parent(OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_DUP_HANDLE,FALSE,parent_pid));
    OwnedHandle child(OpenProcess(PROCESS_QUERY_INFORMATION,FALSE,child_pid));
    if(!parent.h||!child.h)throw std::runtime_error("process access unavailable");
    auto p=identity(parent_pid,parent.h),c=identity(child_pid,child.h);if(c.parent!=p.pid)throw std::runtime_error("child-parent mismatch");
    if(mode==L"--identity-only"){std::cout<<'{';print_identity("parent",p);std::cout<<',';print_identity("child",c);std::cout<<"}\n";return 0;}
    if(mode!=L"--enum-only"&&mode!=L"--fixture-write")throw std::runtime_error("unsupported mode");
    if(p.created!=std::stoull(args.at(L"--parent-created"))||c.created!=std::stoull(args.at(L"--child-created"))||!same_path(p.path,args.at(L"--parent-path"))||!same_path(c.path,args.at(L"--child-path")))throw std::runtime_error("pinned process identity mismatch");
    std::vector<Pipe> pipes;for(auto& e:snapshot(parent.h)){
      if(!(e.access&FILE_WRITE_DATA))continue;Pipe pipe{};
      if(bounded_pipe_query(parent_pid,e,pipe)&&pipe.server==parent_pid)pipes.push_back(pipe);
    }
    if(mode==L"--enum-only"){
      std::cout<<"{\"mode\":\"enum-only\",\"writePerformed\":false,\"pipes\":[";bool first=true;
      for(auto& pipe:pipes){if(!first)std::cout<<',';first=false;std::cout<<"{\"handle\":"<<pipe.handle<<",\"access\":"<<pipe.access<<",\"serverPid\":"<<pipe.server<<",\"clientCreatorPid\":"<<pipe.client<<",\"name\":"<<quoted(pipe.name)<<'}';}std::cout<<"]}\n";return 0;
    }
    // Real process writes are deliberately unavailable in this first artifact.
    if(!same_path(c.path,own_path()))throw std::runtime_error("fixture-only write gate: child must run this probe executable");
    std::wstring trusted_stdin=args.at(L"--fixture-stdin-name");
    auto child_handles=snapshot(child.h);uintptr_t stdin_value=std::stoull(args.at(L"--fixture-stdin-handle"));
    if(std::none_of(child_handles.begin(),child_handles.end(),[&](auto& e){return reinterpret_cast<uintptr_t>(e.handle)==stdin_value&&(e.access&FILE_READ_DATA);}))throw std::runtime_error("fixture stdin snapshot mismatch");
    pipes.erase(std::remove_if(pipes.begin(),pipes.end(),[&](auto& pipe){return pipe.name!=trusted_stdin;}),pipes.end());
    if(pipes.size()!=1)throw std::runtime_error("fixture stdin pipe match is not unique; match count="+std::to_string(pipes.size()));
    auto p2=identity(parent_pid,parent.h),c2=identity(child_pid,child.h);if(p2.created!=p.created||c2.created!=c.created||c2.parent!=p2.pid)throw std::runtime_error("identity changed before write");
    write_fixture(parent.h,pipes.front());
    std::cout<<"{\"mode\":\"fixture-write\",\"writePerformed\":true,\"requestKind\":\"fixture-auth-update\",\"requestPayloadLogged\":false,\"authenticated\":\"NOT_ESTABLISHED\"}\n";return 0;
  }catch(const std::exception& e){std::cerr<<"probe refused: "<<e.what()<<'\n';return 1;}
}
