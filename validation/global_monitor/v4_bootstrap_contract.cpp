#include "../../native/desktop_runtime_observer/v4_capture.h"
#include "../../native/desktop_runtime_observer/v4_bootstrap_api.h"
#include <algorithm>
#include <cstdio>
#include <iterator>
#include <string>

// Production v4 bootstrap projection/capture, same core as the observer DLL.
bootstrap4::Shared whole{};
Shared& storage = whole.runtime.auth;
Shared* gShared = &storage;
bootstrap4::Shared* gBootstrapShared = &whole;
live3::Shared* gLiveShared = &whole.runtime;
Projection reader, writer;
Stats reads, writes;
constexpr char sentinel[] = "SYNTHETIC_BOOTSTRAP_BODY_4bb6e2";
std::uint64_t hashBytes(const std::string& text) {
  std::uint64_t value = 14695981039346656037ull;
  for (const unsigned char c : text) { value ^= c; value *= 1099511628211ull; }
  return value;
}
bool feed(Projection& parser, const std::string& wire, Stats& stats, bool outbound=false, std::uint64_t ticket=0) {
  const auto before=hashBytes(wire);const std::size_t pieces[]={1,3,17,65536};std::size_t at=0,index=0;
  while(at<wire.size()){const auto size=std::min(pieces[index++%4],wire.size()-at);parser.feed(wire.data()+at,size,stats,outbound,ticket);at+=size;}
  return before==hashBytes(wire);
}
void control(unsigned slot,unsigned purpose,const char* text) {
  auto& c=storage.controls[slot];SecureZeroMemory(&c,sizeof c);c.purpose=static_cast<Purpose>(purpose);c.generation=1;c.ticket=slot+1;
  c.id.kind=IdKind::String;c.id.length=static_cast<unsigned>(std::strlen(text));std::memcpy(c.id.text,text,c.id.length);c.state=ControlState::Active;
}
int main() {
  storage.magic=kMagic;storage.version=4;storage.bytes=sizeof whole;
  storage.eventBytes=sizeof(Event);storage.controlBytes=sizeof(RequestControl);storage.generation=1;storage.enabled=1;
  whole.runtime.liveCoverageFlags=live3::LiveUnknown|live3::InitialGap;ResetCapture();bool immutable=true;
  for(unsigned i=0;i<2;++i){const auto id=std::string("bind-")+char('a'+i);const auto ticket=1ull+i;
    immutable&=feed(writer,std::string("{\"id\":\"")+id+"\",\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}\n",writes,true,ticket);AdmitWrite(ticket,true);
    immutable&=feed(reader,std::string("{\"result\":{\"account\":null},\"id\":\"")+id+"\"}\n",reads);
  }
  const bool baseline=storage.writerReady&&storage.writerMatchedPairs==2&&!storage.coverageFlags&&!storage.drops;
  immutable&=feed(reader,std::string("{\"result\":{\"data\":[\"unregistered-must-not-export\"],\"nextCursor\":null,\"preview\":\"")+std::string(262144,'x')+sentinel+"\"},\"id\":\"unregistered\"}\n",reads);
  const bool unregisteredIgnored=whole.bootstrapHead==0;
  control(0,3,"thread/read:ctz-bootstrap-page");
  immutable&=feed(reader,"{\"result\":{\"data\":[\"00000000-0000-7000-8000-000000000001\",\"00000000-0000-7000-8000-000000000002\"],\"nextCursor\":\"00000000-0000-7000-8000-000000000002\"},\"id\":\"thread/read:ctz-bootstrap-page\"}\n",reads);
  control(1,4,"thread/read:ctz-bootstrap-thread");
  immutable&=feed(reader,"{\"result\":{\"thread\":{\"id\":\"00000000-0000-7000-8000-000000000001\",\"status\":{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\",\"waitingOnUserInput\"]},\"turns\":[],\"preview\":\"SYNTHETIC_BOOTSTRAP_BODY_4bb6e2\"}},\"id\":\"thread/read:ctz-bootstrap-thread\"}\n",reads);
  control(2,4,"thread/read:ctz-bootstrap-error");
  immutable&=feed(reader,"{\"error\":{\"code\":-32001,\"message\":\"SYNTHETIC_BOOTSTRAP_BODY_4bb6e2\"},\"id\":\"thread/read:ctz-bootstrap-error\"}\n",reads);
  immutable&=feed(reader,"{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":7901,\"params\":{\"reason\":\"unauthorized\"}}\n",reads);
  const LONG baseEvents=whole.bootstrapHead;
  const auto first=whole.bootstrapEvents[0],second=whole.bootstrapEvents[1],end=whole.bootstrapEvents[2],snapshot=whole.bootstrapEvents[3],error=whole.bootstrapEvents[4];
  const bool page=baseEvents==5&&first.kind==bootstrap4::BootstrapKind::PageItem&&first.index==0&&first.count==2&&first.valueBytes==36&&second.index==1&&
    end.kind==bootstrap4::BootstrapKind::PageEnd&&end.count==2&&(end.flags&bootstrap4::Complete)&&(end.flags&bootstrap4::CursorPresent)&&!(end.flags&bootstrap4::CursorNull)&&end.valueBytes==36&&!std::memcmp(end.value,second.value,36);
  const bool status=snapshot.kind==bootstrap4::BootstrapKind::ThreadSnapshot&&snapshot.status==live3::Lifecycle::Active&&snapshot.attention==3&&(snapshot.flags&bootstrap4::Complete)&&snapshot.valueBytes==36;
  const bool errorCode=error.kind==bootstrap4::BootstrapKind::RequestError&&(error.flags&bootstrap4::ErrorCodePresent)&&error.rpcErrorCode==-32001&&(error.flags&bootstrap4::Incomplete);
  bool sequence=true;for(LONG i=0;i<baseEvents&&i<5;++i)sequence&=whole.bootstrapEvents[i].sequence==static_cast<unsigned>(i+1)&&whole.bootstrapEvents[i].generation==1;
  control(3,3,"thread/read:ctz-bootstrap-empty");
  immutable&=feed(reader,"{\"id\":\"thread/read:ctz-bootstrap-empty\",\"result\":{\"data\":[],\"nextCursor\":null}}\n",reads);
  const auto empty=whole.bootstrapEvents[5];
  const bool nullCursor=empty.kind==bootstrap4::BootstrapKind::PageEnd&&(empty.flags&bootstrap4::CursorNull)&&!(empty.flags&bootstrap4::CursorPresent)&&(empty.flags&bootstrap4::Complete)&&empty.count==0&&empty.valueBytes==0;
  control(4,3,"thread/read:ctz-bootstrap-missing-cursor");
  immutable&=feed(reader,"{\"id\":\"thread/read:ctz-bootstrap-missing-cursor\",\"result\":{\"data\":[]}}\n",reads);
  const auto missingCursor=whole.bootstrapEvents[6];
  const bool cursorUnknown=(missingCursor.flags&bootstrap4::CursorMissing)&&(missingCursor.flags&bootstrap4::Incomplete)&&!(missingCursor.flags&(bootstrap4::CursorNull|bootstrap4::Complete));
  control(5,4,"thread/read:ctz-bootstrap-missing-status");
  immutable&=feed(reader,"{\"id\":\"thread/read:ctz-bootstrap-missing-status\",\"result\":{\"thread\":{\"id\":\"00000000-0000-7000-8000-000000000001\"}}}\n",reads);
  const auto missingStatus=whole.bootstrapEvents[7];
  const bool statusUnknown=missingStatus.status==live3::Lifecycle::Unknown&&(missingStatus.flags&bootstrap4::Incomplete)&&!(missingStatus.flags&(bootstrap4::StatusPresent|bootstrap4::Complete));
  const bool controlsObserved=std::all_of(std::begin(storage.controls),std::begin(storage.controls)+6,[](const RequestControl& c){return c.state==ControlState::Observed;});
  whole.bootstrapTail=whole.bootstrapHead;
  for(unsigned i=0;i<17;++i){const auto id=std::string("thread/read:ctz-bootstrap-fill-")+std::to_string(i);control(0,4,id.c_str());
    immutable&=feed(reader,std::string("{\"id\":\"")+id+"\",\"result\":{\"thread\":{\"id\":\"00000000-0000-7000-8000-000000000001\",\"status\":{\"type\":\"idle\"}}}}\n",reads);
  }
  immutable&=feed(reader,"{\"method\":\"account/chatgptAuthTokens/refresh\",\"id\":7902,\"params\":{\"reason\":\"unauthorized\"}}\n",reads);
  unsigned authRefresh=0;for(LONG i=storage.tail;i<storage.head;++i)if(storage.events[static_cast<unsigned>(i)%16].kind==EventKind::RefreshRequest)++authRefresh;
  for(LONG i=whole.bootstrapTail;i<whole.bootstrapHead;++i)sequence&=whole.bootstrapEvents[static_cast<unsigned>(i)%16].sequence==static_cast<unsigned>(i+1);
  const char* begin=reinterpret_cast<const char*>(&whole);
  const bool privateAbsent=std::search(begin,begin+sizeof whole,sentinel,sentinel+sizeof sentinel-1)==begin+sizeof whole;
  const bool independentAuth=storage.writerReady&&!storage.drops&&!storage.coverageFlags&&authRefresh==2&&storage.enabled;
  const bool overflow=whole.bootstrapDrops==1&&(whole.bootstrapCoverageFlags&bootstrap4::BootstrapQueueOverflow)&&storage.controls[0].state==ControlState::Observed;
  const bool pass=baseline&&page&&status&&errorCode&&unregisteredIgnored&&nullCursor&&cursorUnknown&&statusUnknown&&controlsObserved&&overflow&&sequence&&independentAuth&&privateAbsent&&immutable&&!reads.rejected&&!writes.rejected&&whole.runtime.liveHead==0;
  auto b=[](bool value){return value?"true":"false";};
  std::printf("{\"pass\":%s,\"baseBootstrapEvents\":%ld,\"pageAndOpaqueCursor\":%s,\"statusAndAttention\":%s,\"errorCodeOnly\":%s,\"unregisteredIgnored\":%s,\"nullCursorDistinct\":%s,\"missingCursorUnknown\":%s,\"missingStatusUnknown\":%s,\"controlsReleased\":%s,\"overflowAuthIsolated\":%s,\"sequencesValid\":%s,\"authRefreshObserved\":%u,\"inputBytesImmutable\":%s,\"privateBodyExcluded\":%s,\"liveEvents\":%ld,\"actualDesktopAccess\":false,\"modelRequests\":0,\"credentialReads\":0}\n",b(pass),baseEvents,b(page),b(status),b(errorCode),b(unregisteredIgnored),b(nullCursor),b(cursorUnknown),b(statusUnknown),b(controlsObserved),b(overflow&&independentAuth),b(sequence),authRefresh,b(immutable),b(privateAbsent),whole.runtime.liveHead);
  return pass?0:1;
}
