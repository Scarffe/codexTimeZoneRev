#include "observer_core.h"
#include <intrin.h>

// Only the broker-created Node executable is patched. This DLL has no injector.
using ReadFn = BOOL(WINAPI*)(HANDLE, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);
using GorFn = BOOL(WINAPI*)(HANDLE, LPOVERLAPPED, LPDWORD, BOOL);
ReadFn gRead = nullptr;
GorFn gGor = nullptr;
Shared* gShared = nullptr;  // Kept mapped/resident through logical Stop.
HANDLE gMapping = nullptr;
volatile LONG gBusy = 0;
volatile LONG gFault = 0;
Parser gParser;
Stats gStats;
Queue gQueue;
unsigned gGorAborted = 0, gZeroReads = 0;
struct Pending { HANDLE handle; OVERLAPPED* overlap; void* buffer; DWORD capacity; bool used; } gPending{};
struct Patch { PVOID volatile* slot = nullptr; PVOID original = nullptr, replacement = nullptr; bool installed = false, protection = true; } gReadPatch, gGorPatch;

void publish() {
  gShared->drops = static_cast<LONG>(gStats.drops) + (InterlockedCompareExchange(&gFault, 0, 0) ? 1 : 0);
  gShared->lines = static_cast<LONG>(gStats.lines);
  gShared->rejects = static_cast<LONG>(gStats.rejected);
  gShared->duplicateRejects = static_cast<LONG>(gStats.duplicateRejected);
  gShared->immediate = static_cast<LONG>(gStats.immediate);
  gShared->pending = static_cast<LONG>(gStats.pending);
  gShared->gor = static_cast<LONG>(gStats.gorCompleted);
  gShared->gorAborted = static_cast<LONG>(gGorAborted);
  gShared->zeroReads = static_cast<LONG>(gZeroReads);
  gShared->apiInvariant = gStats.immutable ? 1 : 0;
  gShared->coalesced = gStats.coalesced ? 1 : 0;
  gShared->fragmented = gStats.fragmented ? 1 : 0;
}
std::uint64_t hash(const void* buffer, DWORD count) {
  auto* bytes = static_cast<const unsigned char*>(buffer);
  std::uint64_t h = 1469598103934665603ull;
  for (DWORD i = 0; i < count; ++i) { h ^= bytes[i]; h *= 1099511628211ull; }
  return h;
}
void observe(void* buffer, DWORD count, OVERLAPPED* overlap) {
  if (count > kChunkLimit) { ++gStats.drops; InterlockedExchange(&gShared->enabled, 0); return; }
  const auto before = hash(buffer, count);
  OVERLAPPED snapshot{}; if (overlap) snapshot = *overlap;
  gParser.feed(static_cast<const char*>(buffer), count, gQueue, gStats);
  if (before != hash(buffer, count) || (overlap && std::memcmp(&snapshot, overlap, sizeof snapshot))) gStats.immutable = false;
  if (gStats.drops) InterlockedExchange(&gShared->enabled, 0);  // Fail closed, retain original reader.
}
bool eligible(HANDLE handle) {
  return gShared && InterlockedCompareExchange(&gShared->enabled, 0, 0) && reinterpret_cast<std::uintptr_t>(handle) == gShared->readerHandle;
}
bool acquire() {
  if (InterlockedCompareExchange(&gBusy, 1, 0) == 0) return true;
  InterlockedExchange(&gFault, 1); InterlockedIncrement(&gShared->drops); InterlockedExchange(&gShared->enabled, 0); return false;
}
BOOL WINAPI ReadHook(HANDLE handle, LPVOID buffer, DWORD capacity, LPDWORD transferred, LPOVERLAPPED overlap) {
  const BOOL result = gRead(handle, buffer, capacity, transferred, overlap);
  const DWORD error = GetLastError();
  if (eligible(handle) && acquire()) {
    if (!capacity) ++gZeroReads;
    else if (result && transferred && *transferred <= capacity) { ++gStats.immediate; observe(buffer, *transferred, overlap); }
    else if (!result && error == ERROR_IO_PENDING && overlap) {
      ++gStats.pending;
      if (gPending.used) { ++gStats.drops; InterlockedExchange(&gShared->enabled, 0); }
      else gPending = {handle, overlap, buffer, capacity, true};
    }
    publish(); InterlockedExchange(&gBusy, 0);
  }
  SetLastError(error); return result;
}
BOOL WINAPI GorHook(HANDLE handle, LPOVERLAPPED overlap, LPDWORD transferred, BOOL wait) {
  const BOOL result = gGor(handle, overlap, transferred, wait);
  const DWORD error = GetLastError();
  if (eligible(handle) && acquire()) {
    if (gPending.used && gPending.handle == handle && gPending.overlap == overlap) {
      if (result && transferred && *transferred <= gPending.capacity) { ++gStats.gorCompleted; observe(gPending.buffer, *transferred, overlap); }
      if (!result && error == ERROR_OPERATION_ABORTED) ++gGorAborted;
      if (result || (error != ERROR_IO_INCOMPLETE && error != ERROR_IO_PENDING)) gPending = {};
    }
    publish(); InterlockedExchange(&gBusy, 0);
  }
  SetLastError(error); return result;
}
PVOID volatile* findImport(const char* wanted) {
  auto* base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
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
  if (!gShared) return 0;
  InterlockedExchange(&gShared->enabled, 0);
  bool ok = true;
  if (gReadPatch.installed) ok = exchange(gReadPatch, false) && ok;
  if (gGorPatch.installed) ok = exchange(gGorPatch, false) && ok;
  gShared->iatRestored = ok && gReadPatch.slot && gGorPatch.slot && *gReadPatch.slot == gReadPatch.original && *gGorPatch.slot == gGorPatch.original;
  gShared->protectionRestored = gReadPatch.protection && gGorPatch.protection;
  InterlockedExchange(&gShared->state, ok ? 2 : 3);
  return ok ? 1 : 0;  // Code and shared view remain resident; no FreeLibrary.
}
extern "C" __declspec(dllexport) DWORD WINAPI Start(void*) {
  if (gShared) return 0;
  wchar_t mapName[200]{}, nonce[80]{};
  const DWORD mapLength = GetEnvironmentVariableW(L"CTZ_OWNED_OBSERVER_MAP", mapName, 200);
  const DWORD nonceLength = GetEnvironmentVariableW(L"CTZ_OWNED_NONCE", nonce, 80);
  if (!mapLength || mapLength >= 200 || nonceLength != 32) return 0;
  HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, mapName);
  if (!mapping) return 0;
  auto* shared = static_cast<Shared*>(MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared)));
  if (!shared) { CloseHandle(mapping); return 0; }
  bool valid = shared->magic == 0x4f4e4f42 && shared->version == 1 && shared->bytes == sizeof(Shared) && shared->nodePid == GetCurrentProcessId() && shared->readerHandle && shared->nonce[32] == 0;
  for (unsigned i = 0; i < 32 && valid; ++i) if (nonce[i] > 127 || shared->nonce[i] != static_cast<char>(nonce[i])) valid = false;
  if (!valid) { UnmapViewOfFile(shared); CloseHandle(mapping); return 0; }
  gShared = shared; gMapping = mapping; gQueue.shared = shared;
  gReadPatch.slot = findImport("ReadFile"); gGorPatch.slot = findImport("GetOverlappedResult");
  if (!gReadPatch.slot || !gGorPatch.slot) { shared->state = 3; return 0; }
  gReadPatch.original = *gReadPatch.slot; gGorPatch.original = *gGorPatch.slot;
  gReadPatch.replacement = reinterpret_cast<PVOID>(&ReadHook); gGorPatch.replacement = reinterpret_cast<PVOID>(&GorHook);
  gRead = reinterpret_cast<ReadFn>(gReadPatch.original); gGor = reinterpret_cast<GorFn>(gGorPatch.original);
  if (!exchange(gGorPatch, true) || !exchange(gReadPatch, true)) { Stop(nullptr); shared->state = 3; return 0; }
  shared->apiInvariant = 1; InterlockedExchange(&shared->enabled, 1); InterlockedExchange(&shared->state, 1); return 1;
}
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
  return TRUE;
}
