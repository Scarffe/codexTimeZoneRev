#pragma once
// Internal version4 extends the production v3 mapping. External auth ABI2 and
// LiveEvent248/PollLive remain unchanged. No prompt/items/identity payloads.
#include "v3_api.h"

namespace ctz::observer_v4 {
using TypedId = observer_v2::TypedId;
using StartConfig = observer_v2::StartConfig;
using Purpose = observer_v3::ReservedPurpose;
enum class BootstrapKind : std::uint32_t {
  PageItem = 1, PageEnd = 2, ThreadSnapshot = 3, RequestError = 4
};
enum BootstrapFlags : std::uint32_t {
  Complete = 1, DataPresent = 2, CursorPresent = 4, CursorNull = 8,
  CursorMissing = 16, CursorTooLong = 32, IdInvalid = 64, TooManyItems = 128,
  ThreadIdPresent = 256, StatusPresent = 512, ActiveFlagsPresent = 1024,
  ErrorCodePresent = 2048, ResultPresent = 4096, ErrorPresent = 8192,
  Incomplete = 16384, UnrecognizedStatus = 32768
};
enum BootstrapCoverage : LONG {
  BootstrapUnknown = 1, BootstrapQueueOverflow = 2,
  BootstrapProjectionIncomplete = 4, BootstrapRpcError = 8,
  BootstrapStreamGap = 16
};
struct BootstrapEvent {
  std::uint64_t generation, sequence, observedAtMs;
  BootstrapKind kind;
  std::uint32_t flags;
  observer_v3::Lifecycle status;
  std::uint32_t attention;
  TypedId requestId;
  std::uint32_t index, count, valueBytes;
  std::int32_t rpcErrorCode;
  // PageItem/ThreadSnapshot: ID <=63 UTF-8 bytes plus NUL.
  // PageEnd: opaque nextCursor <=64 bytes, length-delimited, no NUL required.
  // CursorPresent and CursorNull differ even when valueBytes is zero.
  char value[64];
};
struct Shared {
  observer_v3::Shared runtime;
  volatile LONG bootstrapHead, bootstrapTail, bootstrapDrops, bootstrapCoverageFlags;
  volatile LONG bootstrapPublished, bootstrapRejected, bootstrapPages, bootstrapSnapshots;
  BootstrapEvent bootstrapEvents[16];
};
// Proposed optional bridge API state; caller sets bytes40/version1.
struct BootstrapState {
  std::uint32_t bytes, version;
  std::uint64_t generation;
  std::uint32_t coverageFlags, eventDrops, eventsPublished, pages, snapshots, captureEnabled;
};
constexpr std::uint32_t kVersion = 4, kMagic = observer_v2::kMagic;
constexpr unsigned kPageLimit = 8, kQueueCapacity = 16, kThreadIdBytes = 63, kCursorBytes = 64;
static_assert(offsetof(BootstrapEvent, requestId) == 40 && offsetof(BootstrapEvent, value) == 136 && sizeof(BootstrapEvent) == 200, "BootstrapEvent200");
static_assert(offsetof(Shared, bootstrapHead) == 15608 && offsetof(Shared, bootstrapEvents) == 15640 && sizeof(Shared) == 18840, "Shared4 bootstrap tail");
static_assert(sizeof(BootstrapState) == 40 && sizeof(StartConfig) == 512, "fixed optional bootstrap state/config");
}
