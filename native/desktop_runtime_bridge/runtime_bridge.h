#pragma once
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include "../desktop_runtime_observer/v4_bootstrap_api.h"

// Native-private transport ABI. Tokens/JSONL must never cross the application's
// public JSON dispatcher. This DLL is loaded only by the finite native helper.
enum class CtzBridgeResult : std::uint32_t {
  Ok = 1, Empty = 2, Pending = 3, ReadOnly = 4,
  Unsupported = 10, NotFound = 11, Ambiguous = 12, IdentityChanged = 13,
  ReaderNotProven = 14, ModuleNotProven = 15, ObserverFailed = 16,
  WriteNotProven = 17, WriteOutcomeUnknown = 18, TargetExited = 19,
  InvalidArgument = 20, Busy = 21
};
struct CtzBridgeEvent {
  std::uint32_t method, kind;
  std::int64_t number;
  std::uint32_t length;
  char text[64];
};
struct CtzBridgeState {
  std::uint32_t bytes, version, ownerPid, childPid;
  std::uint64_t ownerCreation, childCreation;
  std::uint32_t attached, targetAlive, writeReady, coverageUnknown;
  std::uint32_t framesObserved, eventDrops, iatRestored, protectionRestored;
  std::uint32_t writesCompleted, writePending, apiInvariant, pendingReadCompleted;
};
struct CtzDesktopIdentity {
  std::uint32_t bytes, version, ownerPid, childPid;
  std::uint64_t ownerCreation, childCreation;
};
static_assert(sizeof(CtzDesktopIdentity) == 32, "fixed discovery ABI");
static_assert(sizeof(CtzBridgeEvent) == 88 && sizeof(CtzBridgeState) == 80, "x64 bridge ABI");
struct CtzConnectionProof {
  std::uint32_t bytes, metadataComplete, readerCandidates, writerCandidates;
  std::uint32_t writerDefined, metadataUnknown, writableUnknown, localUnknown;
  std::uint32_t nameOrUsersUnknown, coverageFlags, normalWriteIssued, writePending;
  std::uint32_t prepared, probeAttempted, controlledReadPairs, naturalReadPairs;
};
static_assert(sizeof(CtzConnectionProof) == 64, "connection proof counters only");
// Optional live extension. Auth ABI2/Event664/Control104 are unchanged.
struct CtzBridgeLiveState {
  std::uint32_t bytes, version;
  std::uint64_t generation;
  std::uint32_t coverageFlags, eventDrops, eventsPublished, outstanding;
  std::uint32_t targetAlive, captureEnabled;
};
static_assert(sizeof(CtzBridgeLiveState) == 40, "optional live status40");
using CtzBridge = void*;
extern "C" {
__declspec(dllexport) std::uint32_t WINAPI CtzBridgeAbiVersion();
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeDescribeConnection(CtzBridge, CtzConnectionProof*);
// Pure discovery: no observer load, injection, pipe write or credential access.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeDiscoverDesktop(CtzDesktopIdentity*);
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeAttachDesktop(
    const wchar_t* colocatedObserver, CtzBridge* out);
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeStatus(CtzBridge, CtzBridgeState*);
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgePoll(CtzBridge, CtzBridgeEvent*);
// ABI2 uses the one authoritative observer header (Event664/TypedId80).
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgePollV2(CtzBridge, ctz::observer_v2::Event*);
// Empty still fills live state. InitialGap/unknown is not absence of attention.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgePollLive(
    CtzBridge, ctz::observer_v3::LiveEvent*, CtzBridgeLiveState*);
// Optional bootstrap stream: exact registered purpose3/4 metadata only.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgePollBootstrap(
    CtzBridge, ctz::observer_v4::BootstrapEvent*, ctz::observer_v4::BootstrapState*);
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeReadWatermark(CtzBridge, std::uint64_t* capturedSequence);
// Register before sending the private request. Purposes are LoginStart1/Read2.
// Ok commits a control before any write and returns a nonzero per-context ticket.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeRegisterRequest(
    CtzBridge, std::uint32_t purpose, const ctz::observer_v2::TypedId*, std::uint64_t* ticket);
// Only for known-not-admitted requests. Refuses any ticket whose WriteFile was
// invoked (including Pending or unknown outcome); it is not cancellation/rollback.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeDiscardRequest(CtzBridge, std::uint64_t ticket);
// Startup-only bounded fallback: exactly the fixed non-model AccountRead probe
// pair, registered/private IDs, never a caller-supplied payload or auth request.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeProbeConnection(CtzBridge, std::uint32_t timeoutMs);
// At most one private frame is in flight. On Pending/unknown, the bridge owns
// its copied buffer until completion or target death. Never CancelIoEx here.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeWrite(
    CtzBridge, const unsigned char* jsonl, std::uint32_t bytes);
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeFinishWrite(CtzBridge);
// Restores only our IAT entries; loaded code and observer mapping stay resident.
// Refuses while a write is pending. The helper must retain active external-auth
// ownership until target exit; Stop is not an authentication handback.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeStop(CtzBridge);
// Deletes only a stopped/dead-target context. No DLL unload in the target.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeClose(CtzBridge);
#ifdef CTZ_BRIDGE_OWNED_TEST
// Test-only capability: requires direct child of this process, exact pinned
// Node executable/hash, and direct Node child. Absent in production builds.
struct CtzOwnedTarget {
  std::uint32_t ownerPid, childPid;
  std::uint64_t ownerCreation, childCreation;
};
struct CtzOwnedDiagnostics {
  std::uint32_t bytes, visited, metadataUnknown, localUnknown;
  std::uint32_t nameOrUsersUnknown, readerCandidates, writerCandidates, firstUnknownStatus;
  std::uint32_t nonPipeKnown, writableUnknown;
};
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeAttachOwned(
    const CtzOwnedTarget*, const wchar_t* observer, CtzBridge* out);
// Uses the production readiness gate on the exact owned Node connection. v1
// cannot become ready here; metadata-only fixture writes are deliberately off.
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeAttachOwnedProductionGate(
    const CtzOwnedTarget*, const wchar_t* observer, CtzBridge* out);
__declspec(dllexport) CtzBridgeResult WINAPI CtzBridgeOwnedDiagnostics(
    CtzBridge, CtzOwnedDiagnostics*);
#endif
}
