#pragma once
// Authoritative accepted v2 native ABI; private channel only.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstddef>
#include <cstdint>

namespace ctz::observer_v2 {
enum class Role : std::uint32_t { NodeFixture = 1, PinnedCodexDesktop = 2 };
enum class Status : std::uint32_t { Started = 1, Stopped = 2, InvalidConfig = 10, IdentityNotProven = 11, ModuleNotProven = 12, HandleNotProven = 13, ImportConflict = 14, NotQuiescent = 15 };
enum class IdKind : std::uint32_t { None = 0, Number = 1, String = 2 };
struct TypedId {
  IdKind kind;
  std::uint32_t length;
  std::int64_t number;
  char text[64];
};
enum class Purpose : std::uint32_t { AccountLoginStart = 1, AccountRead = 2 };
enum class ControlState : LONG { Free = 0, Registering = 1, Active = 2, Observed = 3 };
struct RequestControl {
  volatile ControlState state;
  Purpose purpose;
  std::uint64_t generation, ticket;
  TypedId id;
};
enum class EventKind : std::uint32_t {
  ChannelBound = 1, RefreshRequest = 2, AccountUpdated = 3,
  OwnedReply = 4, OwnedAccountRead = 5
};
enum class Method : std::uint32_t {
  None = 0, AccountRead = 1, RateLimitsRead = 2, ThreadList = 3,
  ThreadRead = 4, ModelList = 5, ConfigRead = 6, AccountLoginStart = 7,
  Refresh = 8, AccountUpdated = 9
};
enum class AuthMode : std::uint32_t {
  Unknown = 0, None = 1, ApiKey = 2, Chatgpt = 3,
  ChatgptAuthTokens = 4, Other = 5
};
enum class AccountType : std::uint32_t { Unknown = 0, Null = 1, Chatgpt = 2, ApiKey = 3, Other = 4 };
enum class ReplyType : std::uint32_t { Unknown = 0, ChatgptAuthTokens = 1, Other = 2 };
enum EventFlags : std::uint32_t {
  ResultPresent = 1, ErrorPresent = 2, FieldsComplete = 4,
  EmailAbsent = 8, PlanAbsent = 16, AccountIdAbsent = 32, SelectedFieldTooLong = 64, EmailNull = 128, PlanNull = 256, AccountIdNull = 512, SelectedFieldInvalid = 1024
};
struct Event {
  EventKind kind;
  Method method;
  std::uint32_t direction, flags;
  std::uint64_t generation, sequence, observedAtMs;
  TypedId id;
  std::int32_t rpcErrorCode;
  AuthMode authMode;
  AccountType accountType;
  std::uint32_t refreshReason;
  std::uint32_t emailBytes, planBytes, accountIdBytes;
  ReplyType replyType;
  // accountId = workspaceRouting.chatgptAccountId for OwnedAccountRead, or
  // previousAccountId for RefreshRequest; otherwise always empty. Native-only.
  char email[320], plan[64], accountId[128];
};
struct ModuleProof {
  std::uint64_t imageSize;
  std::uint32_t imageTimestamp, reserved;
  unsigned char sha256[32];
};
struct HandleProof {
  std::uint64_t exactStdoutReader, ownerCreationFileTime, childCreationFileTime;
  std::uint32_t ownerPid, childPid;
  std::uint64_t candidateWriter;
};
struct StartConfig {
  std::uint32_t magic, version, bytes, role;
  std::uint64_t ownerGeneration;
  ModuleProof expectedModule;
  HandleProof establishedStdio;
  std::uint32_t mappingVersion, mappingBytes;
  wchar_t mappingName[196];
};
static_assert(sizeof(TypedId) == 80 && sizeof(RequestControl) == 104 && sizeof(Event) == 664, "fixed event/control ABI");
static_assert(sizeof(ModuleProof) == 48 && sizeof(HandleProof) == 40, "fixed proof ABI");
static_assert(offsetof(StartConfig, expectedModule) == 24 && offsetof(StartConfig, mappingName) == 120 && sizeof(StartConfig) == 512, "Start512v2");


enum Coverage : LONG { CoverageUnknown = 1, QueueOverflow = 2, InvalidFrame = 4, AssociationAmbiguous = 8, RejectedWrite = 16, ControlIncomplete = 32 };
struct Shared {
  std::uint32_t magic, version, bytes, eventBytes, controlBytes, brokerPid, ownerPid, childPid;
  std::uint64_t generation, readerHandle, candidateWriter;
  volatile LONG state, enabled, head, tail, drops, lines, rejects, duplicateRejects;
  volatile LONG immediate, pending, gor, gorAborted, zeroReads, apiInvariant;
  volatile LONG coalesced, fragmented, iatRestored, protectionRestored;
  volatile LONG writerMatchedPairs, writerReady, coverageFlags, writerFrames, ownedControlsObserved, reservedCounter;
  RequestControl controls[8];
  Event events[16];
};
static_assert(offsetof(Shared, generation) == 32 && offsetof(Shared, state) == 56, "Shared2 header");
static_assert(offsetof(Shared, controls) == 152 && offsetof(Shared, events) == 984 && sizeof(Shared) == 11608, "Shared2 fixed arrays");
constexpr std::uint32_t kMagic = 0x4f4e4f42, kVersion = 2;
// Start/Stop keep the scoped v1 success codes 1/2; NotQuiescent remains 15.
}
