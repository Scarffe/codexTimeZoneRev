#include "../../native/desktop_runtime_observer/v3_capture.h"
#include <algorithm>
#include <cstdio>
#include <string>

// GREEN checks the same production v3 projector/capture used by the DLL.
// Literal source fixtures match the root-observed frozen v2 RED.
live3::Shared fullStorage{};
Shared& storage = fullStorage.auth;
Shared* gShared = &storage;
live3::Shared* gLiveShared = &fullStorage;
Projection reader, writer;
Stats reads, writes;
constexpr char sentinel[] = "SYNTHETIC_LIVE_BODY_ea04b9";

std::uint64_t hashBytes(const std::string& text) {
  std::uint64_t value = 14695981039346656037ull;
  for (const unsigned char c : text) { value ^= c; value *= 1099511628211ull; }
  return value;
}
bool feed(Projection& parser, const std::string& wire, Stats& stats, bool outbound = false, std::uint64_t ticket = 0) {
  const auto before = hashBytes(wire);
  const std::size_t pieces[] = {1, 3, 17, 65536};
  std::size_t at = 0, piece = 0;
  while (at < wire.size()) {
    const auto size = std::min(pieces[piece++ % 4], wire.size() - at);
    parser.feed(wire.data() + at, size, stats, outbound, ticket);
    at += size;
  }
  return before == hashBytes(wire);
}
int main() {
  storage.magic = kMagic; storage.version = 3; storage.bytes = sizeof fullStorage;
  storage.eventBytes = sizeof(Event); storage.controlBytes = sizeof(RequestControl);
  storage.generation = 1; storage.enabled = 1; ResetCapture();
  fullStorage.liveCoverageFlags = live3::LiveUnknown | live3::InitialGap;
  bool immutable = true;
  // Literal expectations below: 15 live events, one auth refresh, no event for
  // the string "17" response to numeric request 17, and no event for large text.
  const char* first =
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"thread-A\",\"status\":{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\"]}}}\n"
    "{\"params\":{\"threadId\":\"thread-A\",\"turn\":{\"id\":\"turn-A\",\"rootTurnId\":null,\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1,\"completedAt\":null,\"durationMs\":null}},\"method\":\"turn/started\"}\n"
    "{\"params\":{\"kind\":\"command\",\"threadId\":\"thread-A\",\"turnId\":\"turn-A\",\"itemId\":\"item-A\",\"startedAtMs\":1,\"environmentId\":null,\"command\":\"SYNTHETIC_LIVE_BODY_ea04b9\"},\"id\":17,\"method\":\"item/commandExecution/requestApproval\"}\n";
  immutable &= feed(reader, first, reads);
  immutable &= feed(writer, "{\"id\":\"17\",\"result\":{\"decision\":\"decline\"}}\n", writes, true, 1); AdmitWrite(1, true);
  immutable &= feed(writer, "{\"result\":{\"decision\":\"decline\"},\"id\":17}\n", writes, true, 2); AdmitWrite(2, true);
  const char* requests =
    "{\"method\":\"item/fileChange/requestApproval\",\"id\":\"file-A\",\"params\":{\"threadId\":\"thread-A\",\"turnId\":\"turn-A\",\"itemId\":\"item-B\",\"startedAtMs\":1}}\n"
    "{\"method\":\"item/permissions/requestApproval\",\"id\":\"permissions-A\",\"params\":{\"threadId\":\"thread-A\",\"turnId\":\"turn-A\",\"itemId\":\"item-C\",\"environmentId\":null,\"startedAtMs\":1,\"cwd\":\"C:/owned-fixture\",\"reason\":null,\"permissions\":{\"network\":null,\"fileSystem\":null}}}\n"
    "{\"method\":\"item/tool/requestUserInput\",\"id\":\"input-A\",\"params\":{\"threadId\":\"thread-A\",\"turnId\":\"turn-A\",\"itemId\":\"item-D\",\"questions\":[],\"isBlocking\":true,\"autoResolutionMs\":null}}\n"
    "{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"thread-A\",\"requestId\":\"input-A\"}}\n"
    "{\"method\":\"item/tool/requestUserInput\",\"id\":18,\"params\":{\"threadId\":\"thread-A\",\"turnId\":\"turn-A\",\"itemId\":\"item-E\",\"questions\":[],\"isBlocking\":false,\"autoResolutionMs\":null}}\n"
    "{\"method\":\"mcpServer/elicitation/request\",\"id\":\"elicitation-A\",\"params\":{\"threadId\":\"thread-A\",\"turnId\":null,\"serverName\":\"owned-fixture\",\"mode\":\"openai/form\",\"_meta\":null,\"message\":\"SYNTHETIC_LIVE_BODY_ea04b9\",\"requestedSchema\":{}}}\n"
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"thread-A\",\"status\":{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\",\"waitingOnUserInput\"]}}}\n"
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"thread-A\",\"status\":{\"type\":\"idle\"}}}\n";
  immutable &= feed(reader, requests, reads);
  const std::string large = "{\"id\":\"unregistered-large\",\"result\":{\"text\":\"" + std::string(262144, 'x') + sentinel + "\"}}\n";
  immutable &= feed(reader, large, reads);
  for (const char* status : {"interrupted", "failed", "completed"}) {
    const std::string wire = std::string("{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-A\",\"turn\":{\"id\":\"turn-A\",\"rootTurnId\":null,\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"") + status + "\",\"error\":null,\"startedAt\":1,\"completedAt\":2,\"durationMs\":1000}}}\n";
    immutable &= feed(reader, wire, reads);
  }
  immutable &= feed(reader, "{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":\"refresh-after-live\",\"params\":{\"reason\":\"unauthorized\"}}\n", reads);
  const LONG initialLive = fullStorage.liveHead;
  const live3::LiveKind kinds[] = {live3::LiveKind::ThreadStatus,live3::LiveKind::TurnStarted,live3::LiveKind::ApprovalRequest,
    live3::LiveKind::ClientReply,live3::LiveKind::ApprovalRequest,live3::LiveKind::ApprovalRequest,live3::LiveKind::UserInputRequest,
    live3::LiveKind::ServerRequestResolved,live3::LiveKind::UserInputRequest,live3::LiveKind::ElicitationRequest,
    live3::LiveKind::ThreadStatus,live3::LiveKind::ThreadStatus,live3::LiveKind::TurnCompleted,live3::LiveKind::TurnCompleted,live3::LiveKind::TurnCompleted};
  bool events=initialLive==15, sequence=true;
  for(LONG i=0;i<initialLive&&i<15;++i){const auto&e=fullStorage.liveEvents[i];events&=e.kind==kinds[i]&&(e.flags&live3::ProjectionComplete);sequence&=e.sequence==static_cast<unsigned>(i+1)&&e.generation==1;}
  const auto&e=fullStorage.liveEvents;
  const bool typedReply=e[2].requestId.kind==IdKind::Number&&e[2].requestId.number==17&&e[3].requestId.kind==IdKind::Number&&e[3].requestId.number==17&&fullStorage.liveOutstanding==4;
  const bool snapshots=e[0].attention==live3::Approval&&e[10].attention==(live3::Approval|live3::UserInput)&&e[11].lifecycle==live3::Lifecycle::Idle&&e[11].kind==live3::LiveKind::ThreadStatus;
  const bool lifecycle=e[1].lifecycle==live3::Lifecycle::InProgress&&e[12].lifecycle==live3::Lifecycle::Interrupted&&e[13].lifecycle==live3::Lifecycle::Failed&&e[14].lifecycle==live3::Lifecycle::Completed;
  const bool blocking=(e[6].flags&(live3::BlockingKnown|live3::Blocking))==(live3::BlockingKnown|live3::Blocking)&&(e[8].flags&live3::BlockingKnown)&&!(e[8].flags&live3::Blocking);
  const bool contexts=!std::strcmp(e[7].threadId,"thread-A")&&!std::strcmp(e[7].turnId,"turn-A")&&e[7].requestId.kind==IdKind::String&&e[7].requestId.length==7&&!std::memcmp(e[7].requestId.text,"input-A",7)&&(e[9].flags&live3::TurnIdNull)&&!e[9].turnId[0];
  const bool initialUnknown=fullStorage.liveCoverageFlags==(live3::LiveUnknown|live3::InitialGap)&&!fullStorage.liveDrops;
  // Establish real natural writer readiness before the live-only overflow test.
  for(unsigned i=0;i<2;++i){const auto id=std::string("bind-")+char('a'+i);const auto ticket=3ull+i;
    immutable&=feed(writer,std::string("{\"id\":\"")+id+"\",\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}\n",writes,true,ticket);AdmitWrite(ticket,true);
    immutable&=feed(reader,std::string("{\"result\":{\"account\":null},\"id\":\"")+id+"\"}\n",reads);
  }
  const bool bound=storage.writerReady&&storage.writerMatchedPairs==2;
  fullStorage.liveTail=fullStorage.liveHead;
  for(unsigned i=0;i<17;++i)immutable&=feed(reader,"{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"thread-A\",\"status\":{\"type\":\"idle\"}}}\n",reads);
  immutable&=feed(reader,"{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":19,\"params\":{\"reason\":\"unauthorized\"}}\n",reads);
  const bool isolated=fullStorage.liveDrops==1&&(fullStorage.liveCoverageFlags&live3::LiveQueueOverflow)&&storage.writerReady&&!storage.drops&&!storage.coverageFlags&&storage.enabled;
  LONG auth = 0;
  for (LONG i = storage.tail; i < storage.head; ++i) {
    const auto& event = storage.events[static_cast<unsigned>(i) % 16];
    if (event.kind == EventKind::RefreshRequest) ++auth;

  }
  const char* bytes = reinterpret_cast<const char*>(&fullStorage);
  const bool privateAbsent = std::search(bytes, bytes + sizeof fullStorage, sentinel, sentinel + sizeof sentinel - 1) == bytes + sizeof fullStorage;
  const bool pass=events&&sequence&&typedReply&&snapshots&&lifecycle&&blocking&&contexts&&initialUnknown&&bound&&isolated&&auth==2&&immutable&&privateAbsent&&!reads.rejected&&!writes.rejected;
  auto b=[](bool value){return value?"true":"false";};
  std::printf("{\"pass\":%s,\"expectedLiveEvents\":15,\"observedLiveEvents\":%ld,\"liveKindsValid\":%s,\"typedExactReply\":%s,\"attentionSnapshots\":%s,\"lifecycleDistinct\":%s,\"blockingDistinct\":%s,\"contextsValid\":%s,\"sequencesValid\":%s,\"initialCoverageUnknown\":%s,\"naturalWriterBound\":%s,\"liveOverflowAuthIsolated\":%s,\"authRefreshObserved\":%ld,\"inputBytesImmutable\":%s,\"privateSentinelAbsent\":%s,\"readerFrames\":%u,\"writerFrames\":%u,\"actualReaderHashRuntimeRun\":false,\"actualDesktopAccess\":false,\"modelRequests\":0,\"credentialReads\":0}\n",b(pass),initialLive,b(events),b(typedReply),b(snapshots),b(lifecycle),b(blocking),b(contexts),b(sequence),b(initialUnknown),b(bound),b(isolated),auth,b(immutable),b(privateAbsent),reads.lines,writes.lines);
  return pass?0:1;
}
