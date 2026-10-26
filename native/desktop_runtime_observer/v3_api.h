#pragma once
// Internal observer v3 contract; root observed the production v2 missing-live RED.
// Existing v2 auth ABI, controls and artifacts remain frozen.
#include "v2_api.h"

namespace ctz::observer_v3 {
using TypedId = observer_v2::TypedId;
using AuthEvent = observer_v2::Event;
using RequestControl = observer_v2::RequestControl;
using StartConfig = observer_v2::StartConfig;
using Role = observer_v2::Role;
using Status = observer_v2::Status;

enum class ReservedPurpose : std::uint32_t {
  AccountLoginStart = 1, AccountRead = 2,
  ThreadLoadedListMetadata = 3, ThreadReadMetadata = 4
};
enum class LiveKind : std::uint32_t {
  ThreadStatus = 1, TurnStarted = 2, TurnCompleted = 3,
  ApprovalRequest = 4, UserInputRequest = 5, ElicitationRequest = 6,
  ClientReply = 7, ServerRequestResolved = 8
};
enum class Lifecycle : std::uint32_t {
  Unknown = 0, NotLoaded = 1, Idle = 2, SystemError = 3, Active = 4,
  InProgress = 5, Completed = 6, Interrupted = 7, Failed = 8
};
enum Attention : std::uint32_t {
  NoAttention = 0, Approval = 1, UserInput = 2
};
enum LiveFlags : std::uint32_t {
  ProjectionComplete = 1, RequestIdPresent = 2,
  TurnIdAbsent = 4, TurnIdNull = 8,
  BlockingKnown = 16, Blocking = 32,
  ExactRequest = 64, ClientErrorReply = 128,
  CommandApproval = 256, FileApproval = 512, PermissionsApproval = 1024,
  AttentionSnapshot = 2048
};
// Unknown is sticky for this capture generation, independently of auth coverage.
// InitialGap records the period before attach, not an inferred absence of work.
enum LiveCoverage : LONG {
  LiveUnknown = 1, InitialGap = 2, LiveQueueOverflow = 4,
  LiveFieldIncomplete = 8, LiveAssociationUnknown = 16,
  LiveOutstandingOverflow = 32, LiveStreamGap = 64
};
struct LiveEvent {
  std::uint64_t generation, sequence, observedAtMs;
  LiveKind kind;
  Lifecycle lifecycle;
  std::uint32_t attention, flags;
  TypedId requestId;
  // UTF-8, nonempty when present, <=63 bytes plus NUL; never truncate IDs.
  // Missing/null turn is represented by flags. Thread ID is always required.
  char threadId[64], turnId[64];
};
struct Shared {
  // Same auth prefix offsets/layout; its internal version is 3, not ABI2.
  // The bridge still marshals AuthEvent664 through its unchanged PollV2 API.
  observer_v2::Shared auth;
  volatile LONG liveHead, liveTail, liveDrops, liveCoverageFlags;
  volatile LONG livePublished, liveRejected, liveOutstanding, liveReserved;
  LiveEvent liveEvents[16];
};
constexpr std::uint32_t kMagic = observer_v2::kMagic, kVersion = 3;
constexpr unsigned kLiveCapacity = 16;
static_assert(sizeof(StartConfig) == 512 && sizeof(AuthEvent) == 664 && sizeof(RequestControl) == 104, "auth ABI retained");
static_assert(offsetof(LiveEvent, requestId) == 40 && offsetof(LiveEvent, threadId) == 120 && sizeof(LiveEvent) == 248, "LiveEvent248");
static_assert(offsetof(Shared, liveHead) == 11608 && offsetof(Shared, liveEvents) == 11640 && sizeof(Shared) == 15608, "Shared3 fixed live tail");
}
