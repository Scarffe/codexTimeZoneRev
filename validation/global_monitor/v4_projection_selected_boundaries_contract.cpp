#define main projection_limits_baseline_main
#include "v4_projection_limits_contract.cpp"
#undef main

void ownAccountRead() {
  auto& c = gShared->controls[0];
  c.generation = 1; c.purpose = Purpose::AccountRead;
  c.id.kind = IdKind::String; c.id.length = 5;
  std::memcpy(c.id.text, "owned", 5); c.state = ControlState::Active;
}
bool owned(const std::string& unknown, bool email, bool expectedComplete) {
  reset(); ownAccountRead(); Projection parser; Stats stats;
  const auto wire = std::string("{\"id\":\"owned\",\"result\":{") + unknown
    + "\"account\":{\"type\":\"chatgpt\","
    + (email ? "\"email\":\"synthetic@example.invalid\"," : "")
    + "\"planType\":\"plus\"}}}\n";
  parser.feed(wire.data(), wire.size(), stats);
  return stats.rejected == 0 && !gShared->coverageFlags && gShared->head == 1
    && gShared->events[0].kind == EventKind::OwnedAccountRead
    && ((gShared->events[0].flags & FieldsComplete) != 0) == expectedComplete
    && gShared->controls[0].state == ControlState::Observed;
}
int main() {
  const auto key = std::string("\"") + std::string(100, 'k') + "\":null,";
  const bool completeAfterUnknownKey = owned(key, true, true);
  const bool missingSelectedStillIncomplete = owned(key, false, false);
  std::string deep = "\"unretained\":";
  for (unsigned n = 0; n < 80; ++n) deep += "[";
  deep += "null";
  for (unsigned n = 0; n < 80; ++n) deep += "]";
  deep += ",";
  const bool deepOwnedIncomplete = owned(deep, true, false);
  reset(); Projection parser; Stats stats;
  const std::string duplicate = "{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":1,\"id\":2,\"params\":{\"reason\":\"unauthorized\"}}\n";
  parser.feed(duplicate.data(), duplicate.size(), stats);
  const bool selectedDuplicateRejected = stats.rejected == 1 && stats.duplicateRejected == 1
    && (gShared->coverageFlags & InvalidFrame) && gShared->head == 0;
  const bool pass = completeAfterUnknownKey && missingSelectedStillIncomplete
    && deepOwnedIncomplete && selectedDuplicateRejected;
  auto b=[](bool value){return value?"true":"false";};
  std::printf("{\"pass\":%s,\"ownedCompleteAfterUnknownKey\":%s,\"missingSelectedIncomplete\":%s,\"deepOwnedIncomplete\":%s,\"selectedDuplicateRejected\":%s,\"actualProcessAccess\":false,\"modelRequests\":0,\"credentialReads\":0}\n",
    b(pass),b(completeAfterUnknownKey),b(missingSelectedStillIncomplete),b(deepOwnedIncomplete),b(selectedDuplicateRejected));
  return pass ? 0 : 1;
}
