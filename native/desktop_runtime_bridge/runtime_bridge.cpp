#include "runtime_bridge.h"
#include "metadata_protocol.h"
#include "endpoint_role.h"
#include <tlhelp32.h>
#include <winternl.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#pragma comment(lib, "bcrypt.lib")

namespace {
using Result = CtzBridgeResult;
namespace observer = ctz::observer_v2;
enum class Role : std::uint32_t { NodeFixture = 1, PinnedCodexDesktop = 2 };
using observer::StartConfig;
using observer::ModuleProof;
using observer::Shared;
constexpr wchar_t kDesktop[] = L"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.1021.3705.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe";
constexpr wchar_t kChrome[] = L"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.1021.3705.0_x64__2p2nqsd0c76g0\\app\\chrome.dll";
constexpr char kDesktopSha[] = "c5a6ea0f6d99d696e9976c0ecefb6b8410a7dd5b17d96fb69a72c83a8192b649";
constexpr char kChromeSha[] = "e049ab292c32d867288b5cb06248f5c0a947c895a6e7eec2def9e44b0f7fed15";
constexpr char kServerSha[] = "1103e9e09c71fa2cd0afd6d8f3b9a2d63174fe8efd7cb5bd09f1cb14ef58a098";
constexpr char kNodeSha[] = "3602f2bb1a10f2cbab4c36886218a33c1ab3db87290e73b033c46c77147d0237";
using NtQueryProcess = LONG(NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
const auto queryProcess = reinterpret_cast<NtQueryProcess>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess"));

struct Handle {
  HANDLE value = nullptr;
  Handle() = default; explicit Handle(HANDLE v) : value(v) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete; Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value(other.value) { other.value = nullptr; }
  Handle& operator=(Handle&& other) noexcept { if (this != &other) { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); value = other.value; other.value = nullptr; } return *this; }
  explicit operator bool() const { return value && value != INVALID_HANDLE_VALUE; }
};
struct Identity { DWORD pid = 0, parent = 0; std::uint64_t creation = 0; std::wstring path; };
std::uint64_t filetime(FILETIME value) { return (static_cast<std::uint64_t>(value.dwHighDateTime) << 32) | value.dwLowDateTime; }
bool equalPath(const std::wstring& first, const std::wstring& second) {
  auto left = first, right = second;
  std::replace(left.begin(), left.end(), L'/', L'\\'); std::replace(right.begin(), right.end(), L'/', L'\\');
  if (left.rfind(L"\\\\?\\", 0) == 0) left.erase(0, 4);
  if (right.rfind(L"\\\\?\\", 0) == 0) right.erase(0, 4);
  return _wcsicmp(left.c_str(), right.c_str()) == 0;
}
bool identity(HANDLE process, Identity& out) {
  FILETIME c{}, e{}, k{}, u{}; wchar_t path[32768]{}; DWORD count = 32768;
  std::array<std::uintptr_t, 6> basic{};
  if (!queryProcess || !GetProcessTimes(process, &c, &e, &k, &u)
      || !QueryFullProcessImageNameW(process, 0, path, &count)
      || queryProcess(process, 0, basic.data(), sizeof basic, nullptr) < 0) return false;
  out.pid = GetProcessId(process); out.parent = static_cast<DWORD>(basic[5]); out.creation = filetime(c); out.path.assign(path, count); return true;
}
bool same(const Identity& first, const Identity& second) {
  return first.pid == second.pid && first.parent == second.parent && first.creation == second.creation && equalPath(first.path, second.path);
}
EndpointRole endpointRole(HANDLE process, const Identity& expected) {
  ULONG capacity = 4096;
  for (unsigned attempt = 0; attempt < 6; ++attempt) {
    std::vector<unsigned char> bytes(capacity); ULONG required = 0;
    const auto status = queryProcess(process, 60, bytes.data(), capacity, &required);
    if (status >= 0) {
      EndpointRole role = EndpointRole::Unknown;
      if (bytes.size() >= sizeof(UNICODE_STRING)) {
        const auto* text = reinterpret_cast<const UNICODE_STRING*>(bytes.data());
        const auto start = reinterpret_cast<std::uintptr_t>(bytes.data()), end = start + bytes.size();
        const auto pointer = reinterpret_cast<std::uintptr_t>(text->Buffer);
        if (text->Buffer && text->Length && !(text->Length % sizeof(wchar_t))
            && text->MaximumLength >= text->Length && pointer >= start && pointer <= end && text->Length <= end - pointer) {
          std::vector<wchar_t> command(text->Length / sizeof(wchar_t) + 1, 0);
          std::memcpy(command.data(), text->Buffer, text->Length);
          int count = 0; auto** arguments = CommandLineToArgvW(command.data(), &count);
          if (arguments && count && equalPath(arguments[0], expected.path)) role = parsedEndpointRole(count, arguments);
          freePrivateArgv(arguments);
          SecureZeroMemory(command.data(), command.size() * sizeof(wchar_t));
        }
      }
      SecureZeroMemory(bytes.data(), bytes.size());
      return role;
    }
    SecureZeroMemory(bytes.data(), bytes.size());
    if (required <= capacity || required > 65536 + sizeof(UNICODE_STRING)) return EndpointRole::Unknown;
    capacity = required;
  }
  return EndpointRole::Unknown;
}
bool hashFile(const std::wstring& path, unsigned char result[32]) {
  Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (!file) return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
  DWORD objectBytes = 0, returned = 0; bool ok = false;
  if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectBytes), sizeof objectBytes, &returned, 0) >= 0) {
    std::vector<unsigned char> object(objectBytes), block(1024 * 1024);
    if (BCryptCreateHash(algorithm, &hash, object.data(), objectBytes, nullptr, 0, 0) >= 0) {
      ok = true;
      for (;;) { DWORD read = 0; if (!ReadFile(file.value, block.data(), static_cast<DWORD>(block.size()), &read, nullptr)) { ok = false; break; }
        if (!read) break; if (BCryptHashData(hash, block.data(), read, 0) < 0) { ok = false; break; } }
      if (ok) ok = BCryptFinishHash(hash, result, 32, 0) >= 0;
      BCryptDestroyHash(hash);
    }
  }
  BCryptCloseAlgorithmProvider(algorithm, 0); return ok;
}
bool hashMatches(const std::wstring& path, const char* expected) {
  unsigned char digest[32]{}; if (!hashFile(path, digest)) return false;
  for (unsigned i = 0; i < 32; ++i) { unsigned byte = 0; if (sscanf_s(expected + i * 2, "%2x", &byte) != 1 || digest[i] != byte) return false; }
  return true;
}
bool fileProof(const std::wstring& path, ModuleProof& proof) {
  Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr));
  IMAGE_DOS_HEADER dos{}; DWORD read = 0;
  if (!file || !ReadFile(file.value, &dos, sizeof dos, &read, nullptr) || read != sizeof dos || dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0) return false;
  LARGE_INTEGER offset{}; offset.QuadPart = dos.e_lfanew;
  IMAGE_NT_HEADERS64 nt{};
  if (!SetFilePointerEx(file.value, offset, nullptr, FILE_BEGIN) || !ReadFile(file.value, &nt, sizeof nt, &read, nullptr)
      || read != sizeof nt || nt.Signature != IMAGE_NT_SIGNATURE || nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return false;
  proof = {}; proof.imageSize = nt.OptionalHeader.SizeOfImage; proof.imageTimestamp = nt.FileHeader.TimeDateStamp;
  return hashFile(path, proof.sha256);
}
std::wstring bridgeDirectory() {
  HMODULE self = nullptr; wchar_t path[32768]{};
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCWSTR>(&CtzBridgeAttachDesktop), &self) || !GetModuleFileNameW(self, path, 32768)) return {};
  return std::filesystem::path(path).parent_path().wstring();
}
std::wstring serverPath() {
  wchar_t local[32768]{}; const auto n = GetEnvironmentVariableW(L"LOCALAPPDATA", local, 32768);
  if (!n || n >= 32768) return {};
  return (std::filesystem::path(local) / L"OpenAI/Codex/bin/2993767bd1dfb009/codex.exe").wstring();
}
std::wstring fixtureNodePath() {
  wchar_t profile[32768]{};
  const auto length = GetEnvironmentVariableW(L"USERPROFILE", profile, 32768);
  if (!length || length >= 32768) return {};
  return (std::filesystem::path(profile) /
          L".cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe").wstring();
}
struct ProcessHandleEntry { HANDLE value; SIZE_T handleCount, pointerCount; ULONG access, typeIndex, attributes, reserved; };
std::vector<ProcessHandleEntry> handles(HANDLE process) {
  ULONG length = 65536;
  for (unsigned attempt = 0; attempt < 10; ++attempt) {
    std::vector<unsigned char> bytes(length); ULONG required = 0;
    if (queryProcess(process, 51, bytes.data(), length, &required) >= 0) {
      const auto count = *reinterpret_cast<const SIZE_T*>(bytes.data());
      if (count > 100000 || 16ull + count * sizeof(ProcessHandleEntry) > bytes.size()) return {};
      const auto* entries = reinterpret_cast<const ProcessHandleEntry*>(bytes.data() + 16);
      return {entries, entries + count};
    }
    length = (std::max)(length * 2, required);
  }
  return {};
}
bool standards(HANDLE process, std::uint64_t result[3]) {
  std::array<std::uintptr_t, 6> basic{}; std::uint64_t params = 0; SIZE_T read = 0;
  return queryProcess(process, 0, basic.data(), sizeof basic, nullptr) >= 0
      && ReadProcessMemory(process, reinterpret_cast<void*>(basic[1] + 0x20), &params, sizeof params, &read) && read == sizeof params
      && ReadProcessMemory(process, reinterpret_cast<void*>(params + 0x20), result, 24, &read) && read == 24;
}
bool metadata(const Identity& who, std::uint64_t handle, CtzPipeMetadata& result, DWORD relatedPid = 0) {
  const auto executable = std::filesystem::path(bridgeDirectory()) / L"codex_runtime_metadata.exe";
  SECURITY_ATTRIBUTES attributes{sizeof attributes, nullptr, TRUE}; HANDLE readRaw = nullptr, writeRaw = nullptr;
  if (!CreatePipe(&readRaw, &writeRaw, &attributes, 65536)) return false;
  Handle reader(readRaw), writer(writeRaw);
  if (!SetHandleInformation(reader.value, HANDLE_FLAG_INHERIT, 0)) return false;
  Handle nullInput(CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes, OPEN_EXISTING, 0, nullptr));
  Handle nullError(CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes, OPEN_EXISTING, 0, nullptr));
  if (!nullInput || !nullError) return false;
  SIZE_T bytes = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
  std::vector<unsigned char> storage(bytes);
  auto* list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(list, 1, 0, &bytes)) return false;
  HANDLE inherited[3]{writer.value, nullInput.value, nullError.value};
  const bool attributesOk = UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof inherited, nullptr, nullptr) != FALSE;
  STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof startup;
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = nullInput.value; startup.StartupInfo.hStdOutput = writer.value; startup.StartupInfo.hStdError = nullError.value; startup.lpAttributeList = list;
  std::wstring command = L"\"" + executable.wstring() + L"\" " + std::to_wstring(who.pid) + L" " + std::to_wstring(who.creation) + L" " + std::to_wstring(handle) + L" " + std::to_wstring(relatedPid);
  PROCESS_INFORMATION child{};
  const bool created = attributesOk && CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr, bridgeDirectory().c_str(), &startup.StartupInfo, &child);
  DeleteProcThreadAttributeList(list);
  if (!created) return false;
  Handle process(child.hProcess), thread(child.hThread);
  if (WaitForSingleObject(process.value, 1500) != WAIT_OBJECT_0) {
    // Exact metadata subprocess created above, never the observed application.
    TerminateProcess(process.value, 21); WaitForSingleObject(process.value, 2000); return false;
  }
  DWORD code = 1, read = 0;
  if (!GetExitCodeProcess(process.value, &code) || code || !ReadFile(reader.value, &result, sizeof result, &read, nullptr)) return false;
  return read == sizeof result && result.magic == kMetadataMagic && result.bytes == sizeof result && result.identityMatched;
}
bool includes(const CtzPipeMetadata& data, DWORD pid) {
  return std::find(data.users, data.users + data.userCount, pid) != data.users + data.userCount;
}
struct PipeAssociation {
  std::uint64_t reader = 0, writer = 0; bool complete = true;
  unsigned visited = 0, metadataUnknown = 0, localUnknown = 0, nameOrUsersUnknown = 0, readerCandidates = 0, writerCandidates = 0, firstUnknownStatus = 0;
  unsigned nonPipeKnown = 0, writableUnknown = 0;
};
bool associate(HANDLE ownerProcess, HANDLE childProcess, const Identity& owner, const Identity& child, PipeAssociation& out) {
  std::uint64_t standard[3]{};
  if (!standards(childProcess, standard)) return false;
  const auto childHandles = handles(childProcess);
  const auto childStdout = std::find_if(childHandles.begin(), childHandles.end(), [&](const auto& value) { return reinterpret_cast<std::uint64_t>(value.value) == standard[1]; });
  if (childStdout == childHandles.end()) return false;
  CtzPipeMetadata stdoutData{}, stderrData{};
  if (!metadata(child, standard[1], stdoutData) || !stdoutData.nameOk || !metadata(child, standard[2], stderrData) || !stderrData.nameOk) return false;
  const std::wstring stdoutName(stdoutData.name, stdoutData.nameChars), stderrName(stderrData.name, stderrData.nameChars);
  if (stdoutName.empty() || stderrName.empty() || stdoutName == stderrName) return false;
  unsigned readerCount = 0, writerCount = 0;
  auto candidates = handles(ownerProcess);
  candidates.erase(std::remove_if(candidates.begin(), candidates.end(), [&](const auto& entry) { return entry.typeIndex != childStdout->typeIndex; }), candidates.end());
  struct Observation { CtzPipeMetadata data{}; bool completed = false; };
  std::vector<Observation> observations(candidates.size());
  std::atomic_size_t next{0};
  auto inspect = [&] {
    for (;;) {
      const auto index = next.fetch_add(1);
      if (index >= candidates.size()) return;
      observations[index].completed = metadata(owner, reinterpret_cast<std::uint64_t>(candidates[index].value), observations[index].data, child.pid);
    }
  };
  std::vector<std::thread> workers;
  for (unsigned i = 0; i < 4; ++i) workers.emplace_back(inspect);
  for (auto& worker : workers) worker.join();
  for (std::size_t index = 0; index < candidates.size(); ++index) {
    const auto& candidate = candidates[index];
    const auto& data = observations[index].data;
    ++out.visited;
    // The writer proof covers every handle with FILE_WRITE_DATA. Read-only
    // unrelated handles cannot be an alternative writer. Their query failures
    // remain counted, while the exact successful stdout name proves our reader.
    const bool writable = (candidate.access & FILE_WRITE_DATA) != 0;
    auto unknown = [&] { if (writable) { ++out.writableUnknown; out.complete = false; } };
    if (!observations[index].completed) { ++out.metadataUnknown; unknown(); continue; }
    if (data.fileType == FILE_TYPE_DISK || data.fileType == FILE_TYPE_CHAR) { ++out.nonPipeKnown; continue; }
    if (data.fileType != FILE_TYPE_PIPE) { ++out.localUnknown; unknown(); continue; }
    if (!data.localOk) {
      // GetFileType has proved this is a pipe, so every failed local query is
      // uncertainty, including access loss or STATUS_PENDING.
      const auto status = static_cast<std::uint32_t>(data.localStatus);
      ++out.localUnknown; if (!out.firstUnknownStatus) out.firstUnknownStatus = status; unknown();
      continue;
    }
    if (!data.usersOk) { ++out.nameOrUsersUnknown;
      if (!out.firstUnknownStatus) out.firstUnknownStatus = static_cast<unsigned>(data.usersOk ? data.nameStatus : data.usersStatus);
      unknown(); continue; }
    if (data.fields[2] != 1 || data.fields[3] != 1 || data.fields[8] != 3 || data.fields[9] != 1
        || !includes(data, owner.pid) || !includes(data, child.pid)) continue;
    if (!data.nameOk) { ++out.nameOrUsersUnknown; if (!out.firstUnknownStatus) out.firstUnknownStatus = static_cast<unsigned>(data.nameStatus); unknown(); continue; }
    const std::wstring name(data.name, data.nameChars);
    if (name == stdoutName && (candidate.access & FILE_READ_DATA)) { out.reader = reinterpret_cast<std::uint64_t>(candidate.value); ++readerCount; }
    else if (name != stdoutName && name != stderrName && (candidate.access & FILE_WRITE_DATA)) { out.writer = reinterpret_cast<std::uint64_t>(candidate.value); ++writerCount; }
  }
  out.readerCandidates = readerCount; out.writerCandidates = writerCount;
  if (writerCount != 1) { out.writer = 0; out.complete = false; }
  return readerCount == 1;
}
struct Module { std::wstring name, path; std::uintptr_t base; DWORD size; };
std::vector<Module> modules(DWORD pid) {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid));
  std::vector<Module> result; MODULEENTRY32W entry{}; entry.dwSize = sizeof entry;
  if (snapshot && Module32FirstW(snapshot.value, &entry)) do {
    result.push_back({entry.szModule, entry.szExePath, reinterpret_cast<std::uintptr_t>(entry.modBaseAddr), entry.modBaseSize});
  } while (Module32NextW(snapshot.value, &entry));
  return result;
}
struct Write {
  Handle pipe, event; OVERLAPPED overlap{}; std::vector<unsigned char> bytes;
  ~Write() { if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size()); }
};
struct Context {
  std::mutex mutex;
  Handle ownerProcess, childProcess, mapping, remotePending;
  Identity owner, child;
  PipeAssociation pipes;
  Shared* shared = nullptr;
  ctz::observer_v3::Shared* liveShared = nullptr;
  ctz::observer_v4::Shared* bootstrapShared = nullptr;
  std::uint64_t lastBootstrapSequence = 0;
  bool bootstrapConsumerFault = false;
  std::uint64_t lastLiveSequence = 0;
  bool liveConsumerFault = false;
  std::uintptr_t observerBase = 0, stopRva = 0;
  std::unique_ptr<Write> write;
  bool ownedFixture = false, stopped = false, remoteUncertain = false, unknownWrite = false;
  unsigned completedWrites = 0;
  std::uint64_t nextTicket = 0, preparedTicket = 0;
  int preparedSlot = -1;
  std::array<std::uint64_t, 8> admittedTickets{};
  std::deque<observer::Event> bufferedEvents;
  bool normalWriteIssued = false, probeAttempted = false, bridgeFault = false;
  unsigned controlledReadPairs = 0;
  std::array<observer::TypedId, 2> probeIds{};
  std::array<bool, 2> probeAdmitted{}, probeResponded{};
  ~Context() { if (shared) UnmapViewOfFile(shared); }
  bool alive() const {
    Identity first{}, second{};
    return WaitForSingleObject(ownerProcess.value, 0) == WAIT_TIMEOUT && WaitForSingleObject(childProcess.value, 0) == WAIT_TIMEOUT
      && identity(ownerProcess.value, first) && identity(childProcess.value, second) && same(first, owner) && same(second, child);
  }
};
DWORD remoteCall(Context& context, std::uintptr_t function, void* argument) {
  if (!context.alive() || context.remoteUncertain) return 0;
  Handle thread(CreateRemoteThread(context.ownerProcess.value, nullptr, 0, reinterpret_cast<LPTHREAD_START_ROUTINE>(function), argument, 0, nullptr));
  if (!thread) return 0;
  if (WaitForSingleObject(thread.value, 10000) != WAIT_OBJECT_0) {
    context.remoteUncertain = true; context.remotePending = std::move(thread); return 0;
  }
  DWORD code = 0;
  if (!GetExitCodeThread(thread.value, &code) || !context.alive()) return 0;
  return code;
}
std::uintptr_t exportRva(const std::wstring& dll, const char* name) {
  const auto local = LoadLibraryExW(dll.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
  if (!local) return 0;
  const auto address = GetProcAddress(local, name);
  const auto rva = address ? reinterpret_cast<std::uintptr_t>(address) - reinterpret_cast<std::uintptr_t>(local) : 0;
  FreeLibrary(local); return rva;
}
bool loadObserver(Context& context, const std::wstring& path) {
  const auto load = reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW"));
  HMODULE owner = nullptr; wchar_t ownerPath[32768]{};
  if (!load || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCWSTR>(load), &owner) || !GetModuleFileNameW(owner, ownerPath, 32768)) return false;
  std::uintptr_t remoteModule = 0;
  for (const auto& module : modules(context.owner.pid)) if (equalPath(module.path, ownerPath)) remoteModule = module.base;
  if (!remoteModule) return false;
  const auto byteCount = (path.size() + 1) * sizeof(wchar_t);
  const auto remote = VirtualAllocEx(context.ownerProcess.value, nullptr, byteCount, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (!remote) return false;
  SIZE_T written = 0;
  bool ok = WriteProcessMemory(context.ownerProcess.value, remote, path.c_str(), byteCount, &written) && written == byteCount;
  if (ok) remoteCall(context, remoteModule + reinterpret_cast<std::uintptr_t>(load) - reinterpret_cast<std::uintptr_t>(owner), remote);
  if (!context.remoteUncertain) VirtualFreeEx(context.ownerProcess.value, remote, 0, MEM_RELEASE);
  if (!ok || context.remoteUncertain) return false;
  for (const auto& module : modules(context.owner.pid)) if (equalPath(module.path, path)) { context.observerBase = module.base; return true; }
  return false;
}
bool startObserver(Context& context, Role role, const std::wstring& observerPath) {
  ModuleProof proof{};
  const auto modulePath = role == Role::NodeFixture ? context.owner.path : std::wstring(kChrome);
  if (!fileProof(modulePath, proof)) return false;
  if (role == Role::PinnedCodexDesktop && (proof.imageSize != 336666624 || proof.imageTimestamp != 1792446703 || !hashMatches(modulePath, kChromeSha))) return false;
  bool moduleFound = false;
  for (const auto& module : modules(context.owner.pid)) if (equalPath(module.path, modulePath) && module.size == proof.imageSize) moduleFound = true;
  if (!moduleFound) return false;
  std::uint64_t generation = 0;
  if (BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(&generation), sizeof generation, BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0 || !generation) return false;
  wchar_t mappingName[200]{};
  swprintf_s(mappingName, L"Local\\CodexTimeZone.Runtime.%lu.%016llx", GetCurrentProcessId(), static_cast<unsigned long long>(generation));
  context.mapping = Handle(CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(ctz::observer_v4::Shared), mappingName));
  if (!context.mapping || GetLastError() == ERROR_ALREADY_EXISTS) return false;
  context.bootstrapShared = static_cast<ctz::observer_v4::Shared*>(MapViewOfFile(context.mapping.value, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(ctz::observer_v4::Shared)));
  context.liveShared = context.bootstrapShared ? &context.bootstrapShared->runtime : nullptr;
  context.shared = context.liveShared ? &context.liveShared->auth : nullptr;
  if (!context.shared) return false;
  SecureZeroMemory(context.shared, sizeof(ctz::observer_v4::Shared));
  context.shared->magic = observer::kMagic; context.shared->version = ctz::observer_v4::kVersion; context.shared->bytes = sizeof(ctz::observer_v4::Shared);
  context.shared->eventBytes = sizeof(observer::Event); context.shared->controlBytes = sizeof(observer::RequestControl);
  context.shared->brokerPid = GetCurrentProcessId(); context.shared->ownerPid = context.owner.pid; context.shared->childPid = context.child.pid;
  context.shared->generation = generation; context.shared->readerHandle = context.pipes.reader; context.shared->candidateWriter = context.pipes.writer;
  const auto start = exportRva(observerPath, "Start"); context.stopRva = exportRva(observerPath, "Stop");
  if (!start || !context.stopRva || !loadObserver(context, observerPath)) return false;
  StartConfig config{}; config.magic = 0x434f4e46; config.version = ctz::observer_v4::kVersion; config.bytes = sizeof config; config.role = static_cast<std::uint32_t>(role);
  config.ownerGeneration = generation; config.expectedModule = proof;
  config.establishedStdio = {context.pipes.reader, context.owner.creation, context.child.creation, context.owner.pid, context.child.pid, context.pipes.writer};
  config.mappingVersion = ctz::observer_v4::kVersion; config.mappingBytes = sizeof(ctz::observer_v4::Shared); wcscpy_s(config.mappingName, mappingName);
  const auto remote = VirtualAllocEx(context.ownerProcess.value, nullptr, sizeof config, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (!remote) return false;
  SIZE_T written = 0; bool ok = WriteProcessMemory(context.ownerProcess.value, remote, &config, sizeof config, &written) && written == sizeof config;
  if (ok) ok = remoteCall(context, context.observerBase + start, remote) == 1;
  if (!context.remoteUncertain) VirtualFreeEx(context.ownerProcess.value, remote, 0, MEM_RELEASE);
  return ok && context.shared->state == 1 && context.shared->enabled;
}
Result attach(DWORD ownerPid, DWORD childPid, std::uint64_t ownerCreation, std::uint64_t childCreation, bool fixture, const wchar_t* observer, CtzBridge* out) {
  if (!out || !observer || !*observer) return Result::InvalidArgument;
  *out = nullptr;
  auto context = std::make_unique<Context>(); context->ownedFixture = fixture;
  context->ownerProcess = Handle(OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_DUP_HANDLE | PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_CREATE_THREAD | SYNCHRONIZE, FALSE, ownerPid));
  context->childProcess = Handle(OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_DUP_HANDLE | SYNCHRONIZE, FALSE, childPid));
  if (!context->ownerProcess || !context->childProcess || !identity(context->ownerProcess.value, context->owner) || !identity(context->childProcess.value, context->child)
      || context->owner.creation != ownerCreation || context->child.creation != childCreation || context->child.parent != ownerPid) return Result::IdentityChanged;
  if (fixture) {
    const auto node = fixtureNodePath();
    if (node.empty() || context->owner.parent != GetCurrentProcessId() ||
        !equalPath(context->owner.path, node) || !equalPath(context->child.path, node) ||
        !hashMatches(node, kNodeSha)) return Result::IdentityChanged;
  } else {
    if (!equalPath(context->owner.path, kDesktop) || !equalPath(context->child.path, serverPath()) || !hashMatches(context->owner.path, kDesktopSha) || !hashMatches(context->child.path, kServerSha)) return Result::ModuleNotProven;
    const auto expected = std::filesystem::path(bridgeDirectory()) / L"codex_desktop_observer.dll";
    if (!equalPath(std::filesystem::absolute(observer).wstring(), expected.wstring())) return Result::InvalidArgument;
  }
  if (!associate(context->ownerProcess.value, context->childProcess.value, context->owner, context->child, context->pipes) || !context->alive()) return Result::ReaderNotProven;
  if (!startObserver(*context, fixture ? Role::NodeFixture : Role::PinnedCodexDesktop, std::filesystem::absolute(observer).wstring())) {
    // A timed-out remote operation can still reference its bootstrap allocation.
    // Retain the context/mapping; never free a live remote allocation or unload.
    if (context->remoteUncertain || context->observerBase) *out = context.release();
    return Result::ObserverFailed;
  }
  *out = context.release(); return Result::Ok;
}
Result finish(Context& context) {
  if (!context.write) return context.unknownWrite ? Result::WriteOutcomeUnknown : Result::Ok;
  const bool targetAlive = context.alive();
  DWORD count = 0;
  if (!GetOverlappedResult(context.write->pipe.value, &context.write->overlap, &count, FALSE)) {
    if (GetLastError() == ERROR_IO_INCOMPLETE || GetLastError() == ERROR_IO_PENDING) return Result::Pending;
    context.unknownWrite = true; context.write.reset(); return targetAlive ? Result::WriteOutcomeUnknown : Result::TargetExited;
  }
  const bool complete = count == context.write->bytes.size();
  context.write.reset();
  if (!complete) { context.unknownWrite = true; return targetAlive ? Result::WriteOutcomeUnknown : Result::TargetExited; }
  ++context.completedWrites; return Result::Ok;
}
Result discover(Identity& selectedOwner, Identity& selectedChild) {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)); PROCESSENTRY32W entry{}; entry.dwSize = sizeof entry;
  std::vector<Identity> owners, children;
  if (!snapshot || !Process32FirstW(snapshot.value, &entry)) return Result::NotFound;
  do {
    if (_wcsicmp(entry.szExeFile, L"ChatGPT.exe") && _wcsicmp(entry.szExeFile, L"codex.exe")) continue;
    Handle process(OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, entry.th32ProcessID)); Identity actual{};
    if (!process || !identity(process.value, actual)) continue;
    if (equalPath(actual.path, kDesktop)) owners.push_back(actual);
    else if (equalPath(actual.path, serverPath())) children.push_back(actual);
  } while (Process32NextW(snapshot.value, &entry));
  std::vector<std::pair<Identity, Identity>> pairs;
  for (const auto& owner : owners) for (const auto& child : children) if (child.parent == owner.pid) {
    Handle process(OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, child.pid));
    const auto role = process ? endpointRole(process.value, child) : EndpointRole::Unknown;
    if (role == EndpointRole::Unknown) return Result::Unsupported;
    if (role == EndpointRole::StdioAppServer) pairs.emplace_back(owner, child);
  }
  if (pairs.empty()) return Result::NotFound;
  if (pairs.size() != 1) return Result::Ambiguous;
  selectedOwner = pairs[0].first; selectedChild = pairs[0].second; return Result::Ok;
}
bool channelHealthy(const Context& context) {
  const auto* s = context.shared;
  return s && context.alive() && !context.stopped && !context.bridgeFault && s->state == 1 && s->enabled
    && !s->drops && !s->coverageFlags && s->generation && s->ownerPid == context.owner.pid && s->childPid == context.child.pid
    && s->readerHandle == context.pipes.reader && s->candidateWriter == context.pipes.writer;
}
bool writerReady(const Context& context) {
  return channelHealthy(context) && context.pipes.writer && !context.unknownWrite
    && ((context.shared->writerReady && context.shared->writerMatchedPairs >= 2) || context.controlledReadPairs == 2);
}
bool validId(const observer::TypedId& id) {
  if (id.kind == observer::IdKind::Number) return id.length == 0;
  if (id.kind != observer::IdKind::String || !id.length || id.length >= sizeof id.text) return false;
  for (unsigned i = 0; i < id.length; ++i) if (static_cast<unsigned char>(id.text[i]) < 32 || static_cast<unsigned char>(id.text[i]) > 126) return false;
  return true;
}
bool sameId(const observer::TypedId& a, const observer::TypedId& b) {
  return a.kind == b.kind && (a.kind == observer::IdKind::Number ? a.number == b.number
    : a.length == b.length && !std::memcmp(a.text, b.text, a.length));
}
LONG controlState(observer::RequestControl& c) {
  return InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&c.state), 0, 0);
}
Result registerRequest(Context& context, unsigned purpose, const observer::TypedId& id, std::uint64_t& ticket) {
  ticket = 0;
  if (!validId(id) || (purpose < 1 || purpose > 4)) return Result::InvalidArgument;
  if (!channelHealthy(context)) return Result::ObserverFailed;
  if (context.preparedTicket) return Result::Busy;
  for (auto& control : context.shared->controls) {
    const auto state = controlState(control);
    if (state != 0 && control.generation == context.shared->generation && sameId(control.id, id)) return Result::Busy;
  }
  for (unsigned i = 0; i < 8; ++i) {
    auto& control = context.shared->controls[i]; const auto state = controlState(control);
    if (state != static_cast<LONG>(observer::ControlState::Free) && state != static_cast<LONG>(observer::ControlState::Observed)) continue;
    if (InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&control.state), 1, state) != state) continue;
    control.purpose = static_cast<observer::Purpose>(purpose); control.generation = context.shared->generation;
    if (++context.nextTicket == 0) ++context.nextTicket;
    control.ticket = context.nextTicket; control.id = id; context.admittedTickets[i] = 0;
    context.preparedTicket = control.ticket; context.preparedSlot = static_cast<int>(i); ticket = control.ticket;
    InterlockedExchange(reinterpret_cast<volatile LONG*>(&control.state), 2); return Result::Ok;
  }
  return Result::Busy;
}
Result popShared(Context& context, observer::Event& out) {
  if (!context.alive()) return Result::TargetExited;
  if (!channelHealthy(context)) return Result::ObserverFailed;
  auto* s = context.shared;
  const LONG tail = InterlockedCompareExchange(&s->tail, 0, 0), head = InterlockedCompareExchange(&s->head, 0, 0);
  if (head == tail) return Result::Empty;
  if (head < tail || head - tail > 16) return Result::ObserverFailed;
  const auto event = s->events[static_cast<unsigned>(tail) % 16];
  if (event.generation != s->generation || !event.sequence || event.id.length >= 64
      || event.emailBytes > sizeof event.email || event.planBytes > sizeof event.plan || event.accountIdBytes > sizeof event.accountId) return Result::ObserverFailed;
  if ((event.kind == observer::EventKind::OwnedAccountRead || event.kind == observer::EventKind::OwnedReply)
      && event.method == observer::Method::AccountRead && (event.flags & (observer::ResultPresent | observer::ErrorPresent))) {
    for (unsigned i = 0; i < 2; ++i) if (context.probeAdmitted[i] && !context.probeResponded[i] && sameId(event.id, context.probeIds[i])) {
      context.probeResponded[i] = true; ++context.controlledReadPairs;
    }
  }
  out = event; InterlockedExchange(&s->tail, tail + 1); return Result::Ok;
}
Result privateWrite(Context& context, const unsigned char* bytes, std::uint32_t count, bool startupProbe) {
  if (!bytes || !count || count > 1024 * 1024 || bytes[count - 1] != '\n') return Result::InvalidArgument;
  if (!context.alive()) return Result::TargetExited;
  if (!channelHealthy(context)) return Result::ObserverFailed;
  if (context.write) return Result::Busy;
  if (startupProbe) {
    if (context.pipes.readerCandidates != 1 || context.pipes.writerCandidates != 1 || !context.pipes.writer || context.normalWriteIssued || context.unknownWrite) return Result::WriteNotProven;
  } else if (!writerReady(context)) return Result::WriteNotProven;
  auto write = std::make_unique<Write>(); HANDLE pipe = nullptr;
  if (!DuplicateHandle(context.ownerProcess.value, reinterpret_cast<HANDLE>(context.pipes.writer), GetCurrentProcess(), &pipe, 0, FALSE, DUPLICATE_SAME_ACCESS)) return Result::WriteNotProven;
  write->pipe = Handle(pipe); write->event = Handle(CreateEventW(nullptr, TRUE, FALSE, nullptr)); if (!write->event) return Result::WriteNotProven;
  write->overlap.hEvent = reinterpret_cast<HANDLE>(reinterpret_cast<std::uintptr_t>(write->event.value) | 1ull);
  write->bytes.assign(bytes, bytes + count); DWORD transferred = 0; context.write = std::move(write);
  if (context.preparedSlot >= 0) {
    context.admittedTickets[static_cast<unsigned>(context.preparedSlot)] = context.preparedTicket;
    context.preparedTicket = 0; context.preparedSlot = -1;
  }
  if (!startupProbe) context.normalWriteIssued = true;
  const BOOL ok = WriteFile(context.write->pipe.value, context.write->bytes.data(), count, &transferred, &context.write->overlap);
  if (!ok && GetLastError() != ERROR_IO_PENDING) { context.unknownWrite = true; context.write.reset(); return Result::WriteOutcomeUnknown; }
  return finish(context);
}
}

extern "C" __declspec(dllexport) std::uint32_t WINAPI CtzBridgeAbiVersion() { return 2; }
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeDiscoverDesktop(CtzDesktopIdentity* out) {
  if (!out || out->bytes != sizeof *out || out->version != 1) return Result::InvalidArgument;
  *out = {sizeof *out, 1, 0, 0, 0, 0};
  try {
    Identity owner{}, child{}; const auto result = discover(owner, child); if (result != Result::Ok) return result;
    if (!hashMatches(owner.path, kDesktopSha) || !hashMatches(child.path, kServerSha) || !hashMatches(kChrome, kChromeSha)) return Result::ModuleNotProven;
    Handle first(OpenProcess(PROCESS_QUERY_INFORMATION | SYNCHRONIZE, FALSE, owner.pid)), second(OpenProcess(PROCESS_QUERY_INFORMATION | SYNCHRONIZE, FALSE, child.pid));
    Identity a{}, b{};
    if (!first || !second || !identity(first.value, a) || !identity(second.value, b) || !same(a, owner) || !same(b, child)
        || WaitForSingleObject(first.value, 0) != WAIT_TIMEOUT || WaitForSingleObject(second.value, 0) != WAIT_TIMEOUT) return Result::IdentityChanged;
    out->ownerPid = owner.pid; out->childPid = child.pid; out->ownerCreation = owner.creation; out->childCreation = child.creation; return Result::Ok;
  } catch (...) { return Result::Unsupported; }
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeAttachDesktop(const wchar_t* observer, CtzBridge* out) {
  if (out) *out = nullptr;
  try {
    Identity owner{}, child{}; const auto result = discover(owner, child); if (result != Result::Ok) return result;
    return attach(owner.pid, child.pid, owner.creation, child.creation, false, observer, out);
  } catch (...) { return Result::Unsupported; }
}
#ifdef CTZ_BRIDGE_OWNED_TEST
extern "C" __declspec(dllexport) DWORD WINAPI CtzBridgeTestEndpointRole(const wchar_t* command) {
  if (!command) return 0;
  int count = 0; auto** arguments = CommandLineToArgvW(command, &count);
  const bool server = arguments && parsedEndpointRole(count, arguments) == EndpointRole::StdioAppServer;
  freePrivateArgv(arguments); return server ? 1 : 0;
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeAttachOwned(const CtzOwnedTarget* target, const wchar_t* observer, CtzBridge* out) {
  try { return target ? attach(target->ownerPid, target->childPid, target->ownerCreation, target->childCreation, true, observer, out) : Result::InvalidArgument; }
  catch (...) { return Result::Unsupported; }
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeAttachOwnedProductionGate(const CtzOwnedTarget* target, const wchar_t* observer, CtzBridge* out) {
  try {
    if (!target) return Result::InvalidArgument;
    const auto result = attach(target->ownerPid, target->childPid, target->ownerCreation, target->childCreation, true, observer, out);
    return result;
  } catch (...) { return Result::Unsupported; }
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeOwnedDiagnostics(CtzBridge value, CtzOwnedDiagnostics* out) {
  if (!value || !out || out->bytes != sizeof *out) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  if (!context.ownedFixture) return Result::InvalidArgument;
  const auto& p = context.pipes;
  *out = {sizeof *out, p.visited, p.metadataUnknown, p.localUnknown, p.nameOrUsersUnknown, p.readerCandidates, p.writerCandidates, p.firstUnknownStatus, p.nonPipeKnown, p.writableUnknown};
  return Result::Ok;
}
#endif
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeStatus(CtzBridge value, CtzBridgeState* out) {
  if (!value || !out || out->bytes != sizeof *out || out->version != 1) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  const bool alive = context.alive();
  const auto* shared = context.shared;
  *out = {}; out->bytes = sizeof *out; out->version = 1;
  out->ownerPid = context.owner.pid; out->childPid = context.child.pid; out->ownerCreation = context.owner.creation; out->childCreation = context.child.creation;
  out->attached = shared && shared->state == 1 && shared->enabled; out->targetAlive = alive;
  out->writeReady = writerReady(context);
  out->coverageUnknown = !shared || shared->drops || shared->coverageFlags || !shared->enabled || !alive || context.bridgeFault;
  if (shared) { out->framesObserved = shared->lines; out->eventDrops = shared->drops; out->iatRestored = shared->iatRestored; out->protectionRestored = shared->protectionRestored;
    out->apiInvariant = shared->apiInvariant; out->pendingReadCompleted = shared->pending > 0 && shared->gor > 0; }
  out->writesCompleted = context.completedWrites; out->writePending = context.write ? 1 : 0; return Result::Ok;
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgePoll(CtzBridge value, CtzBridgeEvent* out) {
  return value && out ? Result::Unsupported : Result::InvalidArgument; // ABI2 must not silently discard non-refresh events.
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgePollV2(CtzBridge value, observer::Event* out) {
  if (!value || !out) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  if (!context.alive()) return Result::TargetExited;
  if (!channelHealthy(context)) return Result::ObserverFailed;
  if (!context.bufferedEvents.empty()) { *out = context.bufferedEvents.front(); context.bufferedEvents.pop_front(); return Result::Ok; }
  return popShared(context, *out);
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeReadWatermark(CtzBridge value, std::uint64_t* out) {
  if (!value || !out) return Result::InvalidArgument; *out = 0;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  if (!channelHealthy(context)) return Result::ObserverFailed;
  auto* s = context.shared;
  for (unsigned attempt = 0; attempt < 4; ++attempt) {
    const LONG head = InterlockedCompareExchange(&s->head, 0, 0);
    if (!head) return Result::Ok;
    if (head < 0) return Result::ObserverFailed;
    auto& event = s->events[static_cast<unsigned>(head - 1) % 16];
    const auto sequence = static_cast<std::uint64_t>(InterlockedCompareExchange64(reinterpret_cast<volatile LONG64*>(&event.sequence), 0, 0));
    if (head == InterlockedCompareExchange(&s->head, 0, 0) && sequence && event.generation == s->generation) { *out = sequence; return Result::Ok; }
  }
  return Result::Busy;
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeRegisterRequest(CtzBridge value, std::uint32_t purpose, const observer::TypedId* id, std::uint64_t* ticket) {
  if (!value || !id || !ticket) return Result::InvalidArgument; *ticket = 0;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  return registerRequest(context, purpose, *id, *ticket);
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeDiscardRequest(CtzBridge value, std::uint64_t ticket) {
  if (!value || !ticket) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  if (!context.shared) return Result::ObserverFailed;
  for (unsigned i = 0; i < 8; ++i) {
    auto& control = context.shared->controls[i];
    if (control.ticket != ticket || control.generation != context.shared->generation) continue;
    if (context.admittedTickets[i] == ticket || controlState(control) != 2) return Result::Busy;
    if (InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&control.state), 1, 2) != 2) return Result::Busy;
    control.id = {}; control.ticket = 0; control.generation = 0;
    InterlockedExchange(reinterpret_cast<volatile LONG*>(&control.state), 0);
    if (context.preparedTicket == ticket) { context.preparedTicket = 0; context.preparedSlot = -1; }
    return Result::Ok;
  }
  return Result::NotFound;
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeProbeConnection(CtzBridge value, std::uint32_t timeoutMs) {
  if (!value || timeoutMs < 100 || timeoutMs > 8000) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  if (writerReady(context)) return Result::Ok; // Natural binding wins with no extra request.
  if (!channelHealthy(context) || context.normalWriteIssued || context.write || context.preparedTicket || context.probeAttempted) return Result::WriteNotProven;
  for (auto& control : context.shared->controls) if (controlState(control) == 1 || controlState(control) == 2) return Result::Busy;
  if (context.pipes.readerCandidates != 1 || context.pipes.writerCandidates != 1 || !context.pipes.writer) return Result::WriteNotProven;
  context.probeAttempted = true; const auto deadline = GetTickCount64() + timeoutMs;
  for (unsigned index = 0; index < 2; ++index) {
    auto& id = context.probeIds[index]; id.kind = observer::IdKind::String;
    const int length = sprintf_s(id.text, "thread/read:ctz-p-%016llx-%u", static_cast<unsigned long long>(context.shared->generation), index);
    if (length <= 0 || length >= 64) return Result::InvalidArgument; id.length = static_cast<unsigned>(length);
    std::uint64_t ticket = 0; const auto registered = registerRequest(context, 2, id, ticket);
    if (registered != Result::Ok) return registered;
    char frame[256]{};
    const int bytes = sprintf_s(frame, "{\"id\":\"%s\",\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}\n", id.text);
    if (bytes <= 0 || bytes >= 256) return Result::InvalidArgument;
    auto status = privateWrite(context, reinterpret_cast<const unsigned char*>(frame), static_cast<unsigned>(bytes), true);
    if (status != Result::Ok && status != Result::Pending) return status;
    context.probeAdmitted[index] = true;
    while (status == Result::Pending && GetTickCount64() < deadline) { Sleep(5); status = finish(context); }
    if (status == Result::Pending) return Result::Pending; // Keep the IRP and buffer; no cancellation.
    if (status != Result::Ok) return status;
    while (!context.probeResponded[index] && GetTickCount64() < deadline) {
      observer::Event event{}; status = popShared(context, event);
      if (status == Result::Empty) { Sleep(5); continue; }
      if (status != Result::Ok) return status;
      if (sameId(event.id, id) && event.method == observer::Method::AccountRead) {
        SecureZeroMemory(&event, sizeof event); // Probe identity is not a monitor/default source.
      } else {
        if (context.bufferedEvents.size() == 16) { context.bridgeFault = true; return Result::ObserverFailed; }
        context.bufferedEvents.push_back(event);
      }
    }
    if (!context.probeResponded[index]) return Result::WriteOutcomeUnknown;
  }
  return writerReady(context) ? Result::Ok : Result::ObserverFailed;
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeWrite(CtzBridge value, const unsigned char* bytes, std::uint32_t count) {
  if (!value) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  return privateWrite(context, bytes, count, false);
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeFinishWrite(CtzBridge value) {
  if (!value) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex); return finish(context);
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeStop(CtzBridge value) {
  if (!value) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  if (!context.alive()) { context.stopped = true; return Result::Ok; }
  if (context.write || context.remoteUncertain) return Result::Pending;
  if (context.stopped) return Result::Ok;
  if (!context.observerBase || !context.stopRva) return Result::ObserverFailed;
  const auto status = remoteCall(context, context.observerBase + context.stopRva, nullptr);
  if (status == 15) return Result::Busy; // Scoped rundown has not drained; retain the live context and retry later.
  if (status != 2) return Result::ObserverFailed;
  context.stopped = context.shared && context.shared->state == 2 && context.shared->iatRestored && context.shared->protectionRestored;
  return context.stopped ? Result::Ok : Result::ObserverFailed;
}
extern "C" __declspec(dllexport) Result WINAPI CtzBridgeClose(CtzBridge value) {
  if (!value) return Result::InvalidArgument;
  auto* context = static_cast<Context*>(value);
  { std::lock_guard<std::mutex> guard(context->mutex);
    if (context->write && finish(*context) == Result::Pending) return Result::Pending;
    if (context->alive() && (!context->stopped || context->write || context->remoteUncertain)) return Result::Pending;
  }
  delete context; return Result::Ok;
}

extern "C" __declspec(dllexport) Result WINAPI CtzBridgeDescribeConnection(CtzBridge value, CtzConnectionProof* out) {
  if (!value || !out || out->bytes != sizeof *out) return Result::InvalidArgument;
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  const auto& p = context.pipes;
  *out = {sizeof *out, p.complete?1u:0u, p.readerCandidates, p.writerCandidates, p.writer?1u:0u,
    p.metadataUnknown, p.writableUnknown, p.localUnknown, p.nameOrUsersUnknown,
    context.shared?static_cast<unsigned>(context.shared->coverageFlags):1u,
    context.normalWriteIssued?1u:0u, context.write?1u:0u, context.preparedTicket?1u:0u,
    context.probeAttempted?1u:0u, context.controlledReadPairs,
    context.shared?static_cast<unsigned>(context.shared->writerMatchedPairs):0u};
  return Result::Ok;
}

// Optional ABI1 live extension on the ABI2 auth bridge. This path never drains
// auth events or clears auth readiness, including on live consumer failure.
extern "C" __declspec(dllexport) Result WINAPI CtzBridgePollLive(
    CtzBridge value, ctz::observer_v3::LiveEvent* out, CtzBridgeLiveState* state) {
  if (!value || !out || !state || state->bytes != sizeof *state || state->version != 1) return Result::InvalidArgument;
  *out = {};
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  auto* live = context.liveShared; auto* auth = context.shared;
  *state = {sizeof *state, 1, 0, ctz::observer_v3::LiveUnknown, 0, 0, 0, 0, 0};
  if (!live || !auth || auth->magic != ctz::observer_v3::kMagic || auth->version != ctz::observer_v4::kVersion
      || auth->bytes != sizeof(ctz::observer_v4::Shared) || auth->ownerPid != context.owner.pid || auth->childPid != context.child.pid
      || auth->readerHandle != context.pipes.reader || auth->candidateWriter != context.pipes.writer || !auth->generation) return Result::ObserverFailed;
  const bool alive = context.alive();
  state->generation = auth->generation;
  state->coverageFlags = static_cast<std::uint32_t>(InterlockedCompareExchange(&live->liveCoverageFlags, 0, 0));
  state->eventDrops = static_cast<std::uint32_t>(InterlockedCompareExchange(&live->liveDrops, 0, 0));
  state->eventsPublished = static_cast<std::uint32_t>(InterlockedCompareExchange(&live->livePublished, 0, 0));
  state->outstanding = static_cast<std::uint32_t>(InterlockedCompareExchange(&live->liveOutstanding, 0, 0));
  state->targetAlive = alive ? 1 : 0; state->captureEnabled = !context.stopped && auth->state == 1 && auth->enabled ? 1 : 0;
  if (!alive || !state->captureEnabled) state->coverageFlags |= ctz::observer_v3::LiveUnknown | ctz::observer_v3::LiveStreamGap;
  if (!alive) return Result::TargetExited;
  if (context.liveConsumerFault) { state->coverageFlags |= ctz::observer_v3::LiveUnknown | ctz::observer_v3::LiveFieldIncomplete; return Result::ObserverFailed; }
  const LONG tail = InterlockedCompareExchange(&live->liveTail, 0, 0), head = InterlockedCompareExchange(&live->liveHead, 0, 0);
  if (head == tail) return Result::Empty;
  auto failLive = [&]() { context.liveConsumerFault = true; state->coverageFlags |= ctz::observer_v3::LiveUnknown | ctz::observer_v3::LiveFieldIncomplete; return Result::ObserverFailed; };
  if (head < tail || head - tail > 16) return failLive();
  const auto event = live->liveEvents[static_cast<unsigned>(tail) % 16];
  const auto kind = static_cast<std::uint32_t>(event.kind), lifecycle = static_cast<std::uint32_t>(event.lifecycle);
  const bool request = (event.flags & ctz::observer_v3::RequestIdPresent) != 0;
  const bool idValid = request ? ((event.requestId.kind == ctz::observer_v2::IdKind::Number && !event.requestId.length)
      || (event.requestId.kind == ctz::observer_v2::IdKind::String && event.requestId.length <= 64))
      : event.requestId.kind == ctz::observer_v2::IdKind::None;
  const bool noTurn = (event.flags & (ctz::observer_v3::TurnIdAbsent | ctz::observer_v3::TurnIdNull)) != 0;
  if (event.generation != auth->generation || !event.sequence || event.sequence <= context.lastLiveSequence || kind < 1 || kind > 8 || lifecycle > 8
      || (event.attention & ~3u) || (event.flags & ~4095u) || !(event.flags & ctz::observer_v3::ProjectionComplete) || !idValid
      || !event.threadId[0] || !std::memchr(event.threadId, 0, 64)
      || (noTurn ? event.turnId[0] != 0 : !event.turnId[0] || !std::memchr(event.turnId, 0, 64))) return failLive();
  *out = event; context.lastLiveSequence = event.sequence;
  InterlockedExchange(&live->liveTail, tail + 1); return Result::Ok;
}

// Separate from both auth and live rings. Partial metadata is explicit and must
// not poison the two credential-control purposes or clear their readiness.
extern "C" __declspec(dllexport) Result WINAPI CtzBridgePollBootstrap(
    CtzBridge value, ctz::observer_v4::BootstrapEvent* out, ctz::observer_v4::BootstrapState* state) {
  namespace bs = ctz::observer_v4;
  if (!value || !out || !state || state->bytes != sizeof *state || state->version != 1) return Result::InvalidArgument;
  *out = {};
  auto& context = *static_cast<Context*>(value); std::lock_guard<std::mutex> guard(context.mutex);
  auto* shared = context.bootstrapShared; auto* auth = context.shared;
  *state = {sizeof *state, 1, 0, bs::BootstrapUnknown, 0, 0, 0, 0, 0};
  if (!shared || !auth || auth->magic != bs::kMagic || auth->version != bs::kVersion || auth->bytes != sizeof(bs::Shared)
      || auth->ownerPid != context.owner.pid || auth->childPid != context.child.pid || auth->readerHandle != context.pipes.reader
      || auth->candidateWriter != context.pipes.writer || !auth->generation) return Result::ObserverFailed;
  state->generation = auth->generation;
  state->coverageFlags = static_cast<std::uint32_t>(InterlockedCompareExchange(&shared->bootstrapCoverageFlags, 0, 0));
  state->eventDrops = static_cast<std::uint32_t>(InterlockedCompareExchange(&shared->bootstrapDrops, 0, 0));
  state->eventsPublished = static_cast<std::uint32_t>(InterlockedCompareExchange(&shared->bootstrapPublished, 0, 0));
  state->pages = static_cast<std::uint32_t>(InterlockedCompareExchange(&shared->bootstrapPages, 0, 0));
  state->snapshots = static_cast<std::uint32_t>(InterlockedCompareExchange(&shared->bootstrapSnapshots, 0, 0));
  const bool alive = context.alive();
  state->captureEnabled = alive && !context.stopped && auth->state == 1 && auth->enabled ? 1 : 0;
  if (!state->captureEnabled) state->coverageFlags |= bs::BootstrapUnknown | bs::BootstrapStreamGap;
  if (!alive) return Result::TargetExited;
  auto fail = [&]() { context.bootstrapConsumerFault = true; state->coverageFlags |= bs::BootstrapUnknown | bs::BootstrapProjectionIncomplete; return Result::ObserverFailed; };
  if (context.bootstrapConsumerFault) return fail();
  const LONG tail = InterlockedCompareExchange(&shared->bootstrapTail, 0, 0), head = InterlockedCompareExchange(&shared->bootstrapHead, 0, 0);
  if (head == tail) return Result::Empty;
  if (head < tail || head - tail > 16) return fail();
  const auto event = shared->bootstrapEvents[static_cast<unsigned>(tail) % 16];
  const auto kind = static_cast<unsigned>(event.kind), status = static_cast<unsigned>(event.status);
  if (event.generation != auth->generation || !event.sequence || event.sequence <= context.lastBootstrapSequence || kind < 1 || kind > 4
      || (event.flags & ~65535u) || (event.attention & ~3u) || status > 4 || !validId(event.requestId)
      || event.count > 8 || event.valueBytes > 64) return fail();
  const bool complete = (event.flags & bs::Complete) != 0;
  const bool thread = (event.flags & bs::ThreadIdPresent) != 0;
  const bool valueId = thread && event.valueBytes && event.valueBytes <= 63 && !event.value[event.valueBytes];
  if (complete && (event.flags & bs::Incomplete)) return fail();
  if (event.kind == bs::BootstrapKind::PageItem) {
    if (!valueId || !event.count || event.index >= event.count) return fail();
  } else if (event.kind == bs::BootstrapKind::PageEnd) {
    const bool cursor = (event.flags & bs::CursorPresent) != 0, nullCursor = (event.flags & bs::CursorNull) != 0;
    if (event.index != event.count || (cursor && nullCursor) || (nullCursor && event.valueBytes)
        || (complete && (!(event.flags & bs::DataPresent) || (!cursor && !nullCursor)))) return fail();
  } else if (event.kind == bs::BootstrapKind::ThreadSnapshot) {
    if (thread ? !valueId : event.valueBytes != 0) return fail();
    if (complete && (!thread || !(event.flags & bs::StatusPresent) || !status
        || (event.status == ctz::observer_v3::Lifecycle::Active && !(event.flags & bs::ActiveFlagsPresent)))) return fail();
  } else if (event.valueBytes || !(event.flags & bs::ErrorPresent)) return fail();
  *out = event; context.lastBootstrapSequence = event.sequence;
  InterlockedExchange(&shared->bootstrapTail, tail + 1); return Result::Ok;
}
