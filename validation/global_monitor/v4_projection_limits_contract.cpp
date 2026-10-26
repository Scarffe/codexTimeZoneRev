#include "../../native/desktop_runtime_observer/v4_capture.h"
#include <cstdio>
#include <string>

// CPU-only production projector/capture contract. No process/pipe/credential I/O.
bootstrap4::Shared whole{};
Shared* gShared = &whole.runtime.auth;
bootstrap4::Shared* gBootstrapShared = &whole;
live3::Shared* gLiveShared = &whole.runtime;

void reset() {
  SecureZeroMemory(&whole, sizeof whole);
  gShared->generation = 1; gShared->enabled = 1;
  ResetCapture();
  gShared->writerReady = 1; gShared->writerMatchedPairs = 2;
}
bool harmless(const std::string& wire) {
  reset(); Projection parser; Stats stats;
  const auto original = wire;
  for (std::size_t at = 0; at < wire.size(); at += 7)
    parser.feed(wire.data() + at, (wire.size() - at < 7 ? wire.size() - at : 7), stats);
  const std::string refresh = "{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":82,\"params\":{\"reason\":\"unauthorized\"}}\n";
  parser.feed(refresh.data(), refresh.size(), stats);
  return wire == original && stats.rejected == 0 && !gShared->coverageFlags
    && gShared->writerReady && gShared->head == 1
    && gShared->events[0].kind == EventKind::RefreshRequest
    && (gShared->events[0].flags & FieldsComplete);
}
bool selectedStillStrict() {
  reset(); Projection parser; Stats stats;
  const auto wire = std::string("{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":\"")
    + std::string(96, 'i') + "\",\"params\":{\"reason\":\"unauthorized\"}}\n";
  parser.feed(wire.data(), wire.size(), stats);
  bool complete = false;
  for (LONG n = gShared->tail; n < gShared->head; ++n)
    complete |= (gShared->events[n % 16].flags & FieldsComplete) != 0;
  const bool longAuthIdRejected = !complete && (gShared->coverageFlags || gShared->head);
  reset(); parser = Projection{}; stats = Stats{};
  const auto principal = std::string("{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":83,\"params\":{\"reason\":\"unauthorized\",\"previousAccountId\":\"")
    + std::string(140, 'p') + "\"}}\n";
  parser.feed(principal.data(), principal.size(), stats);
  const bool principalIncomplete = gShared->head == 1
    && !(gShared->events[0].flags & FieldsComplete)
    && (gShared->events[0].flags & SelectedFieldTooLong);
  return longAuthIdRejected && principalIncomplete;
}
bool malformedStillRejected() {
  reset(); Projection parser; Stats stats;
  const std::string wire = "{\"id\":\"ordinary\",\"result\":{\"ignored\":[1,]}}\n";
  parser.feed(wire.data(), wire.size(), stats);
  return stats.rejected == 1 && (gShared->coverageFlags & InvalidFrame);
}
int main() {
  const auto unknownKey = std::string("{\"id\":\"ordinary\",\"result\":{\"")
    + std::string(96, 'k') + "\":{\"text\":\"SYNTHETIC_OMITTED_BODY\"}}}\n";
  std::string rootKeys = "{\"id\":\"ordinary\",\"result\":null";
  for (unsigned i = 0; i < 20; ++i) rootKeys += ",\"unknown" + std::to_string(i) + "\":null";
  rootKeys += "}\n";
  std::string deep = "{\"id\":\"ordinary\",\"result\":{\"ignored\":";
  for (unsigned i = 0; i < 80; ++i) deep += "{\"unknown\":";
  deep += "null";
  for (unsigned i = 0; i < 80; ++i) deep += "}";
  deep += "}}\n";
  const auto longMethod = std::string("{\"method\":\"") + std::string(100, 'm') + "\",\"params\":{\"irrelevant\":true}}\n";
  const auto longId = std::string("{\"id\":\"") + std::string(160, 'i') + "\",\"result\":null}\n";
  const bool key = harmless(unknownKey), keys = harmless(rootKeys), nested = harmless(deep);
  const bool method = harmless(longMethod), id = harmless(longId);
  const bool strict = selectedStillStrict(), framing = malformedStillRejected();
  const bool pass = key && keys && nested && method && id && strict && framing;
  auto b=[](bool value){return value?"true":"false";};
  std::printf("{\"pass\":%s,\"unknownLongKey\":%s,\"manyRootKeys\":%s,\"deepUnknown\":%s,\"unknownLongMethod\":%s,\"unregisteredLongId\":%s,\"selectedAuthStrict\":%s,\"malformedRejected\":%s,\"actualProcessAccess\":false,\"modelRequests\":0,\"credentialReads\":0}\n",
    b(pass),b(key),b(keys),b(nested),b(method),b(id),b(strict),b(framing));
  return pass ? 0 : 1;
}
