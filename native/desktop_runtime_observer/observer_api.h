#pragma once
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstddef>
#include <cstdint>

// Explicit native API. Start success=1, logical Stop success=2; errors are the finite codes below.
namespace ctz::desktop_observer {
enum class Role : std::uint32_t { NodeFixture = 1, PinnedCodexDesktop = 2 };
enum class Status : std::uint32_t {
  Started = 1, Stopped = 2, InvalidConfig = 10, IdentityNotProven = 11,
  ModuleNotProven = 12, HandleNotProven = 13, ImportConflict = 14, NotQuiescent = 15
};
struct ModuleProof {
  std::uint64_t imageSize;
  std::uint32_t imageTimestamp;
  std::uint32_t reserved;
  unsigned char sha256[32];
};
struct HandleProof {
  std::uint64_t exactStdoutReader;
  std::uint64_t ownerCreationFileTime;
  std::uint64_t childCreationFileTime;
  std::uint32_t ownerPid;
  std::uint32_t childPid;
};
struct StartConfig {
  std::uint32_t magic, version, bytes;
  Role role;
  std::uint64_t ownerGeneration;
  ModuleProof expectedModule;
  HandleProof establishedStdio;
  std::uint32_t mappingVersion, mappingBytes;
  wchar_t mappingName[200];
};
static_assert(sizeof(void*) == 8 && sizeof(wchar_t) == 2, "Windows x64 ABI");
static_assert(sizeof(ModuleProof) == 48 && sizeof(HandleProof) == 32, "fixed proof layouts");
static_assert(offsetof(StartConfig, expectedModule) == 24 && sizeof(StartConfig) == 512, "fixed explicit configuration");
using StartFn = DWORD(WINAPI*)(void* explicitConfig);
using StopFn = DWORD(WINAPI*)(void* reserved);
// Role selects the module internally: NodeFixture=>main module; PinnedCodexDesktop=>chrome.dll.
// No arbitrary module name, process selector, credential provider, or model request is an API input.
}
