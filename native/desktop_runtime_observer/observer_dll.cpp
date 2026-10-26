#include "v4_capture.h"
#include <intrin.h>
#include <cstdio>
#include <bcrypt.h>
#include <cwchar>
#pragma comment(lib, "bcrypt.lib")
using ctz::observer_v2::StartConfig;
using ctz::observer_v2::Role;
using ctz::observer_v2::Status;

// Finite NodeFixture/main or pinned Desktop/chrome.dll roles. This DLL has no injector.
using ReadFn = BOOL(WINAPI*)(HANDLE, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);
using WriteFn = BOOL(WINAPI*)(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
using GorFn = BOOL(WINAPI*)(HANDLE, LPOVERLAPPED, LPDWORD, BOOL);
ReadFn gRead = nullptr;
GorFn gGor = nullptr;
WriteFn gWrite = nullptr;
bootstrap4::Shared* gBootstrapShared = nullptr;
live3::Shared* gLiveShared = nullptr;
Shared* gShared = nullptr;  // Kept mapped/resident through logical Stop.
HANDLE gMapping = nullptr;
Shared* gRetiredShared = nullptr;
HANDLE gRetiredMapping = nullptr;
HMODULE gSelected = nullptr;
volatile LONG gTransition = 0, gActiveCalls = 0, gBarrierPayloadSkips = 0;
alignas(8) volatile LONG64 gReaderValue = 0;
alignas(8) volatile LONG64 gWriterValue = 0;
volatile LONG gBusy = 0;
volatile LONG gFault = 0;
Projection gParser, gWriterParser;
Stats gStats, gWriterStats;
unsigned gGorAborted = 0, gZeroReads = 0;
struct Pending { HANDLE handle; OVERLAPPED* overlap; void* buffer; DWORD capacity; bool used; } gPending{};
struct Patch { PVOID volatile* slot = nullptr; PVOID original = nullptr, replacement = nullptr; bool installed = false, protection = true; } gReadPatch, gGorPatch, gWritePatch;

Shared* currentShared() {
  return static_cast<Shared*>(InterlockedCompareExchangePointer(reinterpret_cast<PVOID volatile*>(&gShared), nullptr, nullptr));
}
Shared* enterCall(HANDLE handle, bool& registered, bool writer = false) {
  volatile LONG64* selectedValue = writer ? &gWriterValue : &gReaderValue;
  registered = false;
  // Unrelated module I/O (including synchronous control stdin) owns no capture context.
  if (reinterpret_cast<std::uintptr_t>(handle) != static_cast<std::uintptr_t>(InterlockedCompareExchange64(selectedValue, 0, 0))) return nullptr;
  if (InterlockedCompareExchange(&gTransition, 0, 0)) return nullptr;
  // Register only the exact reader before its original API. Recheck the transition
  // and reader after registration so a concurrent generation change cannot lease an old context.
  InterlockedIncrement(&gActiveCalls);
  if (InterlockedCompareExchange(&gTransition, 0, 0) || reinterpret_cast<std::uintptr_t>(handle) != static_cast<std::uintptr_t>(InterlockedCompareExchange64(selectedValue, 0, 0))) {
    InterlockedDecrement(&gActiveCalls); return nullptr;
  }
  registered = true;
  return currentShared();
}
void publish(Shared* shared) {
  shared->drops = static_cast<LONG>(gStats.drops) + InterlockedCompareExchange(&gCoreLosses, 0, 0) + (InterlockedCompareExchange(&gFault, 0, 0) ? 1 : 0) + InterlockedCompareExchange(&gBarrierPayloadSkips, 0, 0);
  shared->lines = static_cast<LONG>(gStats.lines);
  shared->rejects = static_cast<LONG>(gStats.rejected);
  shared->duplicateRejects = static_cast<LONG>(gStats.duplicateRejected);
  shared->immediate = static_cast<LONG>(gStats.immediate);
  shared->pending = static_cast<LONG>(gStats.pending);
  shared->gor = static_cast<LONG>(gStats.gorCompleted);
  shared->gorAborted = static_cast<LONG>(gGorAborted);
  shared->zeroReads = static_cast<LONG>(gZeroReads);
  shared->apiInvariant = gStats.immutable ? 1 : 0;
  shared->coalesced = gStats.coalesced ? 1 : 0;
  shared->fragmented = gStats.fragmented ? 1 : 0;
  shared->writerFrames = static_cast<LONG>(gWriterStats.lines);
  if(shared->drops){InterlockedOr(&shared->coverageFlags,CoverageUnknown);InterlockedExchange(&shared->writerReady,0);}
}
std::uint64_t hash(const void* buffer, DWORD count) {
  auto* bytes = static_cast<const unsigned char*>(buffer);
  std::uint64_t h = 1469598103934665603ull;
  for (DWORD i = 0; i < count; ++i) { h ^= bytes[i]; h *= 1099511628211ull; }
  return h;
}
void observe(Shared* shared, void* buffer, DWORD count, OVERLAPPED* overlap) {
  const auto before = hash(buffer, count);
  OVERLAPPED snapshot{}; if (overlap) snapshot = *overlap;
  gParser.feed(static_cast<const char*>(buffer), count, gStats);
  if (before != hash(buffer, count) || (overlap && std::memcmp(&snapshot, overlap, sizeof snapshot))) gStats.immutable = false;
  if (gStats.drops) InterlockedExchange(&shared->enabled, 0);  // Fail closed, retain original reader.
}
bool eligible(Shared* shared, HANDLE handle) {
  return shared && InterlockedCompareExchange(&shared->enabled, 0, 0) && reinterpret_cast<std::uintptr_t>(handle) == shared->readerHandle;
}
bool acquire(Shared* shared) {
  if (InterlockedCompareExchange(&gBusy, 1, 0) == 0) return true;
  InterlockedExchange(&gFault, 1); Loss(AssociationAmbiguous); InterlockedExchange(&shared->enabled, 0); return false;
}
BOOL WINAPI ReadHook(HANDLE handle, LPVOID buffer, DWORD capacity, LPDWORD transferred, LPOVERLAPPED overlap) {
  bool registered = false;
  Shared* const shared = enterCall(handle, registered);
  const BOOL result = gRead(handle, buffer, capacity, transferred, overlap);
  const DWORD error = GetLastError();
  if (eligible(shared, handle) && acquire(shared)) {
    if (!capacity) ++gZeroReads;
    else if (result && transferred && *transferred <= capacity) { ++gStats.immediate; observe(shared, buffer, *transferred, overlap); }
    else if (!result && error == ERROR_IO_PENDING && overlap) {
      ++gStats.pending;
      if (gPending.used) { ++gStats.drops; InterlockedExchange(&shared->enabled, 0); }
      else gPending = {handle, overlap, buffer, capacity, true};
    }
    publish(shared); InterlockedExchange(&gBusy, 0);
  }
  if (!shared && reinterpret_cast<std::uintptr_t>(handle) == static_cast<std::uintptr_t>(InterlockedCompareExchange64(&gReaderValue, 0, 0)) && result && transferred && *transferred) InterlockedIncrement(&gBarrierPayloadSkips);
  if (registered) InterlockedDecrement(&gActiveCalls);
  SetLastError(error); return result;
}
BOOL WINAPI GorHook(HANDLE handle, LPOVERLAPPED overlap, LPDWORD transferred, BOOL wait) {
  bool registered = false;
  Shared* const shared = enterCall(handle, registered);
  const BOOL result = gGor(handle, overlap, transferred, wait);
  const DWORD error = GetLastError();
  if (eligible(shared, handle) && acquire(shared)) {
    if (gPending.used && gPending.handle == handle && gPending.overlap == overlap) {
      if (result && transferred && *transferred <= gPending.capacity) { ++gStats.gorCompleted; observe(shared, gPending.buffer, *transferred, overlap); }
      if (!result && error == ERROR_OPERATION_ABORTED) ++gGorAborted;
      if (result || (error != ERROR_IO_INCOMPLETE && error != ERROR_IO_PENDING)) gPending = {};
    }
    publish(shared); InterlockedExchange(&gBusy, 0);
  }
  if (registered) InterlockedDecrement(&gActiveCalls);
  SetLastError(error); return result;
}
BOOL WINAPI WriteHook(HANDLE handle, LPCVOID buffer, DWORD capacity, LPDWORD transferred, LPOVERLAPPED overlap) {
  const DWORD incomingError=GetLastError();bool registered=false;
  Shared*const shared=enterCall(handle,registered,true);std::uint64_t ticket=0;
  const bool target=shared&&InterlockedCompareExchange(&shared->enabled,0,0)&&reinterpret_cast<std::uintptr_t>(handle)==shared->candidateWriter;
  if(target&&acquire(shared)){
    ticket=++gWriteTicket;const auto before=hash(buffer,capacity);
    gWriterParser.feed(static_cast<const char*>(buffer),capacity,gWriterStats,true,ticket);
    if(before!=hash(buffer,capacity))gStats.immutable=false;
    publish(shared);InterlockedExchange(&gBusy,0);
  }
  SetLastError(incomingError);
  const BOOL result=gWrite(handle,buffer,capacity,transferred,overlap);
  const DWORD error=GetLastError();
  if(target&&ticket&&acquire(shared)){
    const bool admitted=(result&&(!transferred||*transferred==capacity))||(!result&&error==ERROR_IO_PENDING);
    AdmitWrite(ticket,admitted);if(!admitted)gWriterParser=Projection{};
    publish(shared);InterlockedExchange(&gBusy,0);
  }
  if(registered)InterlockedDecrement(&gActiveCalls);
  SetLastError(error);return result;
}
PVOID volatile* findImport(HMODULE selected, const char* wanted) {
  auto* base = reinterpret_cast<unsigned char*>(selected);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return nullptr;
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) return nullptr;
  const DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
  if (!rva) return nullptr;
  for (auto* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + rva); desc->Name; ++desc) {
    if (!desc->OriginalFirstThunk) continue;
    auto* names = reinterpret_cast<IMAGE_THUNK_DATA64*>(base + desc->OriginalFirstThunk);
    auto* slots = reinterpret_cast<IMAGE_THUNK_DATA64*>(base + desc->FirstThunk);
    for (; names->u1.AddressOfData; ++names, ++slots) {
      if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
      auto* entry = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
      if (!std::strcmp(reinterpret_cast<const char*>(entry->Name), wanted)) return reinterpret_cast<PVOID volatile*>(&slots->u1.Function);
    }
  }
  return nullptr;
}
bool exchange(Patch& patch, bool install) {
  MEMORY_BASIC_INFORMATION before{}, after{}; DWORD old = 0, ignored = 0;
  if (!VirtualQuery(const_cast<PVOID*>(patch.slot), &before, sizeof before) || !VirtualProtect(const_cast<PVOID*>(patch.slot), sizeof(PVOID), PAGE_READWRITE, &old)) return false;
  const PVOID previous = InterlockedCompareExchangePointer(patch.slot, install ? patch.replacement : patch.original, install ? patch.original : patch.replacement);
  const bool protection = VirtualProtect(const_cast<PVOID*>(patch.slot), sizeof(PVOID), old, &ignored) && VirtualQuery(const_cast<PVOID*>(patch.slot), &after, sizeof after) && before.Protect == after.Protect;
  patch.protection = patch.protection && protection;
  if (previous == (install ? patch.original : patch.replacement)) patch.installed = install; else return false;
  return patch.protection;
}
extern "C" __declspec(dllexport) DWORD WINAPI Stop(void*) {
  if (InterlockedCompareExchange(&gTransition, 1, 0)) return static_cast<DWORD>(Status::NotQuiescent);
  if (!gShared) { InterlockedExchange(&gTransition, 0); return static_cast<DWORD>(Status::InvalidConfig); }
  if (InterlockedCompareExchange(&gActiveCalls, 0, 0) || InterlockedCompareExchange(&gBusy, 0, 0) || gPending.used) {
    InterlockedExchange(&gTransition, 0); return static_cast<DWORD>(Status::NotQuiescent);
  }
  InterlockedExchange(&gShared->enabled, 0);
  InterlockedExchange(&gShared->writerReady, 0);
  InterlockedOr(&gLiveShared->liveCoverageFlags, live3::LiveUnknown | live3::LiveStreamGap);
  InterlockedOr(&gBootstrapShared->bootstrapCoverageFlags, bootstrap4::BootstrapUnknown | bootstrap4::BootstrapStreamGap);
  bool ok = true;
  if (gWritePatch.installed) ok = exchange(gWritePatch, false) && ok;
  if (gReadPatch.installed) ok = exchange(gReadPatch, false) && ok;
  if (gGorPatch.installed) ok = exchange(gGorPatch, false) && ok;
  gShared->iatRestored = ok && gReadPatch.slot && gGorPatch.slot && *gReadPatch.slot == gReadPatch.original && *gGorPatch.slot == gGorPatch.original && gWritePatch.slot && *gWritePatch.slot == gWritePatch.original;
  gShared->protectionRestored = gReadPatch.protection && gGorPatch.protection && gWritePatch.protection;
  InterlockedExchange(&gShared->state, ok ? 2 : 3);
  InterlockedExchange(&gTransition, 0);
  return static_cast<DWORD>(ok ? Status::Stopped : Status::ImportConflict);  // Resident; no FreeLibrary.
}
bool moduleProven(HMODULE module, const ctz::observer_v2::ModuleProof& proof, Role role) {
  auto* base = reinterpret_cast<const unsigned char*>(module);
  auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
  auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC || proof.imageSize != nt->OptionalHeader.SizeOfImage || proof.imageTimestamp != nt->FileHeader.TimeDateStamp) return false;
  wchar_t path[32768]{};
  const DWORD n = GetModuleFileNameW(module, path, 32768);
  if (!n || n >= 32768) return false;
  const wchar_t* basename = std::wcsrchr(path, L'\\'); basename = basename ? basename + 1 : path;
  if (_wcsicmp(basename, role == Role::NodeFixture ? L"node.exe" : L"chrome.dll")) return false;
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hashHandle = nullptr;
  unsigned char object[1024]{}, digest[32]{}, buffer[65536]{};
  DWORD objectBytes = 0, returned = 0;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
  if (ok) ok = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectBytes), sizeof objectBytes, &returned, 0) >= 0 && objectBytes <= sizeof object;
  if (ok) ok = BCryptCreateHash(algorithm, &hashHandle, object, objectBytes, nullptr, 0, 0) >= 0;
  while (ok) {
    DWORD count = 0;
    if (!ReadFile(file, buffer, static_cast<DWORD>(sizeof buffer), &count, nullptr)) { ok = false; break; }
    if (!count) break;
    ok = BCryptHashData(hashHandle, buffer, count, 0) >= 0;
  }
  if (ok) ok = BCryptFinishHash(hashHandle, digest, sizeof digest, 0) >= 0 && !std::memcmp(digest, proof.sha256, sizeof digest);
  SecureZeroMemory(buffer, sizeof buffer);
  if (hashHandle) BCryptDestroyHash(hashHandle);
  if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file); return ok;
}
extern "C" __declspec(dllexport) DWORD WINAPI Start(void* explicitConfig) {
  if (!explicitConfig) return static_cast<DWORD>(Status::InvalidConfig);
  // The broker owns this allocation until this thread returns. Retain only a local copy.
  const StartConfig config = *static_cast<const StartConfig*>(explicitConfig);
  if (config.magic != 0x434f4e46 || config.version != 4 || config.bytes != sizeof(StartConfig) || (config.role != static_cast<unsigned>(Role::NodeFixture) && config.role != static_cast<unsigned>(Role::PinnedCodexDesktop)) || config.mappingBytes != sizeof(bootstrap4::Shared) || config.mappingVersion != 4 || !config.ownerGeneration || !config.mappingName[0] || config.mappingName[195] != 0) return static_cast<DWORD>(Status::InvalidConfig);
  const auto role = static_cast<Role>(config.role);
  const auto& stdio = config.establishedStdio;
  FILETIME created{}, exited{}, kernel{}, user{};
  if (stdio.ownerPid != GetCurrentProcessId() || !GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user) || stdio.ownerCreationFileTime != ((static_cast<std::uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime)) return static_cast<DWORD>(Status::IdentityNotProven);
  if (!stdio.childPid || !stdio.childCreationFileTime || !stdio.exactStdoutReader || !stdio.candidateWriter || stdio.candidateWriter==stdio.exactStdoutReader || GetFileType(reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(stdio.exactStdoutReader))) != FILE_TYPE_PIPE || GetFileType(reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(stdio.candidateWriter))) != FILE_TYPE_PIPE) return static_cast<DWORD>(Status::HandleNotProven);
  const HMODULE selected = role == Role::NodeFixture ? GetModuleHandleW(nullptr) : GetModuleHandleW(L"chrome.dll");
  if (!selected || !moduleProven(selected, config.expectedModule, role)) return static_cast<DWORD>(Status::ModuleNotProven);
  HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, config.mappingName);
  if (!mapping) return static_cast<DWORD>(Status::InvalidConfig);
  auto* whole = static_cast<bootstrap4::Shared*>(MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(bootstrap4::Shared)));
  Shared* shared = whole ? &whole->runtime.auth : nullptr;
  if (!shared) { CloseHandle(mapping); return static_cast<DWORD>(Status::InvalidConfig); }
  const bool valid = shared->magic == 0x4f4e4f42 && shared->version == config.mappingVersion && shared->bytes == config.mappingBytes && shared->ownerPid == stdio.ownerPid && shared->childPid == stdio.childPid && shared->readerHandle == stdio.exactStdoutReader && shared->generation == config.ownerGeneration && shared->candidateWriter == stdio.candidateWriter && shared->eventBytes == sizeof(Event) && shared->controlBytes == sizeof(RequestControl);
  if (!valid) { UnmapViewOfFile(shared); CloseHandle(mapping); return static_cast<DWORD>(Status::InvalidConfig); }
  if (InterlockedCompareExchange(&gTransition, 1, 0)) { UnmapViewOfFile(shared); CloseHandle(mapping); return static_cast<DWORD>(Status::NotQuiescent); }
  auto reject = [&](Status status) { InterlockedExchange(&gTransition, 0); UnmapViewOfFile(shared); CloseHandle(mapping); return static_cast<DWORD>(status); };
  if (gShared && (gShared->state != 2 || !gShared->iatRestored || !gShared->protectionRestored || gReadPatch.installed || gGorPatch.installed || gWritePatch.installed || selected != gSelected || gShared == shared || gShared->generation == shared->generation)) return reject(Status::InvalidConfig);
  if (InterlockedCompareExchange(&gActiveCalls, 0, 0) || InterlockedCompareExchange(&gBusy, 0, 0) || gPending.used) return reject(Status::NotQuiescent);
  Patch nextRead, nextGor, nextWrite;
  nextRead.slot = findImport(selected, "ReadFile"); nextGor.slot = findImport(selected, "GetOverlappedResult");
  nextWrite.slot = findImport(selected, "WriteFile");
  if (!nextRead.slot || !nextGor.slot || !nextWrite.slot) return reject(Status::ImportConflict);
  nextRead.original = *nextRead.slot; nextGor.original = *nextGor.slot; nextWrite.original = *nextWrite.slot;
  if (gShared && (nextRead.original != gReadPatch.original || nextGor.original != gGorPatch.original || nextWrite.original != gWritePatch.original)) return reject(Status::ImportConflict);
  nextRead.replacement = reinterpret_cast<PVOID>(&ReadHook); nextGor.replacement = reinterpret_cast<PVOID>(&GorHook); nextWrite.replacement = reinterpret_cast<PVOID>(&WriteHook);
  // Entry rundown is zero and the transition barrier prevents any new old-context snapshot.
  // Keep one retired view; an even older view is released only at this next quiet transition.
  if (gRetiredShared) UnmapViewOfFile(gRetiredShared);
  if (gRetiredMapping) CloseHandle(gRetiredMapping);
  gRetiredShared = gShared; gRetiredMapping = gMapping;
  gParser = Projection{}; gWriterParser = Projection{}; gStats = Stats{}; gWriterStats = Stats{}; ResetCapture(); gPending = {}; gGorAborted = 0; gZeroReads = 0;
  InterlockedExchange(&gFault, 0); InterlockedExchange(&gBarrierPayloadSkips, 0);
  gReadPatch = nextRead; gGorPatch = nextGor; gWritePatch = nextWrite;
  // Once hooks can run these targets are immutable, including across rearm.
  if (!gRead) gRead = reinterpret_cast<ReadFn>(nextRead.original);
  if (!gGor) gGor = reinterpret_cast<GorFn>(nextGor.original);
  if (!gWrite) gWrite = reinterpret_cast<WriteFn>(nextWrite.original);
  gMapping = mapping; gSelected = selected;
  gBootstrapShared = whole;
  gLiveShared = &whole->runtime;
  InterlockedExchange(&whole->runtime.liveCoverageFlags, live3::LiveUnknown | live3::InitialGap);
  InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(&gShared), shared);
  InterlockedExchange64(&gReaderValue, static_cast<LONG64>(shared->readerHandle));
  InterlockedExchange64(&gWriterValue, static_cast<LONG64>(shared->candidateWriter));
  if (!exchange(gGorPatch, true) || !exchange(gReadPatch, true) || !exchange(gWritePatch, true)) {
    if (gWritePatch.installed) exchange(gWritePatch, false);
    if (gReadPatch.installed) exchange(gReadPatch, false);
    if (gGorPatch.installed) exchange(gGorPatch, false);
    shared->state = 3; InterlockedExchange(&gTransition, 0); return static_cast<DWORD>(Status::ImportConflict);
  }
  shared->apiInvariant = 1; InterlockedExchange(&shared->enabled, 1); InterlockedExchange(&shared->state, 1);
  InterlockedExchange(&gTransition, 0); return 1;
}
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
  return TRUE;
}
