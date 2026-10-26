#pragma once
// Fixed live metadata only; caller holds the same bounded capture guard as auth.
extern live3::Shared* gLiveShared;
struct LiveOutstanding { live3::LiveEvent opened{}; std::uint64_t serial=0; bool used=false; };
struct LiveReply { live3::LiveEvent event{}; std::uint64_t ticket=0, serial=0; unsigned slot=0; bool used=false; };
LiveOutstanding gLiveOutstanding[16]{};
LiveReply gLiveReplies[16]{};
std::uint64_t gLiveSequence=0, gLiveRequestSerial=0;

void ResetLiveCapture() {
  SecureZeroMemory(gLiveOutstanding,sizeof gLiveOutstanding);
  SecureZeroMemory(gLiveReplies,sizeof gLiveReplies);
  gLiveSequence=gLiveRequestSerial=0;
}
void LiveLoss(LONG reason) {
  if(!gLiveShared)return;
  InterlockedIncrement(&gLiveShared->liveDrops);
  InterlockedOr(&gLiveShared->liveCoverageFlags,live3::LiveUnknown|reason);
}
bool PublishLive(live3::LiveEvent event) {
  if(!gLiveShared)return false;
  const LONG h=InterlockedCompareExchange(&gLiveShared->liveHead,0,0),t=InterlockedCompareExchange(&gLiveShared->liveTail,0,0);
  if(h-t>=16){LiveLoss(live3::LiveQueueOverflow);return false;}
  event.generation=gLiveShared->auth.generation;
  event.sequence=++gLiveSequence;event.observedAtMs=GetTickCount64();
  gLiveShared->liveEvents[static_cast<unsigned>(h)%16]=event;
  InterlockedExchange(&gLiveShared->liveHead,h+1);
  InterlockedIncrement(&gLiveShared->livePublished);return true;
}
bool SameLiveThread(const char* a,const char* b){return !std::memcmp(a,b,64);}
void ClearOutstanding(unsigned slot) {
  if(gLiveOutstanding[slot].used){gLiveOutstanding[slot]=LiveOutstanding{};InterlockedDecrement(&gLiveShared->liveOutstanding);}
}
bool OpenLive(live3::LiveEvent event) {
  LiveOutstanding* available=nullptr;
  for(auto&entry:gLiveOutstanding){
    if(entry.used&&SameId(entry.opened.requestId,event.requestId)){LiveLoss(live3::LiveAssociationUnknown);return false;}
    if(!entry.used&&!available)available=&entry;
  }
  if(!available){LiveLoss(live3::LiveOutstandingOverflow);return false;}
  available->opened=event;available->serial=++gLiveRequestSerial;available->used=true;
  InterlockedIncrement(&gLiveShared->liveOutstanding);
  return PublishLive(event);
}
void OnLiveRead(const Frame& frame) {
  const auto& fields=frame.live;
  if(fields.method==LiveMethod::None)return;
  if(fields.invalid||!fields.threadSeen){InterlockedIncrement(&gLiveShared->liveRejected);LiveLoss(live3::LiveFieldIncomplete);return;}
  auto event=fields.fields;event.flags|=live3::ProjectionComplete;
  switch(fields.method){
    case LiveMethod::ThreadStatus:
      if(!fields.statusSeen||(event.lifecycle==live3::Lifecycle::Active&&!fields.activeFlagsSeen)){LiveLoss(live3::LiveFieldIncomplete);return;}
      event.kind=live3::LiveKind::ThreadStatus;event.flags|=live3::AttentionSnapshot;
      if(event.lifecycle!=live3::Lifecycle::Active)event.attention=live3::NoAttention;
      PublishLive(event);return;
    case LiveMethod::TurnStarted:
    case LiveMethod::TurnCompleted:
      if(!fields.turnSeen||(event.flags&(live3::TurnIdAbsent|live3::TurnIdNull))||!fields.statusSeen||
        (fields.method==LiveMethod::TurnStarted?event.lifecycle!=live3::Lifecycle::InProgress:
          event.lifecycle!=live3::Lifecycle::Completed&&event.lifecycle!=live3::Lifecycle::Interrupted&&event.lifecycle!=live3::Lifecycle::Failed)){
        LiveLoss(live3::LiveFieldIncomplete);return;
      }
      event.kind=fields.method==LiveMethod::TurnStarted?live3::LiveKind::TurnStarted:live3::LiveKind::TurnCompleted;
      PublishLive(event);return;
    case LiveMethod::Resolved:
      if(!fields.requestIdSeen){LiveLoss(live3::LiveFieldIncomplete);return;}
      event.kind=live3::LiveKind::ServerRequestResolved;event.flags|=live3::RequestIdPresent|live3::ExactRequest;
      for(unsigned i=0;i<16;++i){auto&entry=gLiveOutstanding[i];
        if(entry.used&&SameId(entry.opened.requestId,event.requestId)&&SameLiveThread(entry.opened.threadId,event.threadId)){
          std::memcpy(event.turnId,entry.opened.turnId,64);
          event.flags=(event.flags&~(live3::TurnIdAbsent|live3::TurnIdNull))|(entry.opened.flags&(live3::TurnIdAbsent|live3::TurnIdNull));
          ClearOutstanding(i);break;
        }
      }
      PublishLive(event);return;
    default:break;
  }
  if(!frame.hasId||frame.result||frame.error||!fields.turnSeen||
    (fields.method!=LiveMethod::Elicitation&&(event.flags&(live3::TurnIdAbsent|live3::TurnIdNull)))){LiveLoss(live3::LiveFieldIncomplete);return;}
  event.requestId=frame.id;event.flags|=live3::RequestIdPresent;
  event.lifecycle=live3::Lifecycle::Unknown;
  switch(fields.method){
    case LiveMethod::CommandApproval:event.kind=live3::LiveKind::ApprovalRequest;event.attention=live3::Approval;event.flags|=live3::CommandApproval;break;
    case LiveMethod::FileApproval:event.kind=live3::LiveKind::ApprovalRequest;event.attention=live3::Approval;event.flags|=live3::FileApproval;break;
    case LiveMethod::PermissionsApproval:event.kind=live3::LiveKind::ApprovalRequest;event.attention=live3::Approval;event.flags|=live3::PermissionsApproval;break;
    case LiveMethod::UserInput:
      if(!(event.flags&live3::BlockingKnown)){LiveLoss(live3::LiveFieldIncomplete);return;}
      event.kind=live3::LiveKind::UserInputRequest;event.attention=live3::UserInput;break;
    case LiveMethod::Elicitation:event.kind=live3::LiveKind::ElicitationRequest;event.attention=live3::UserInput;break;
    default:return;
  }
  OpenLive(event);
}
void OnLiveWrite(const Frame& frame,std::uint64_t ticket) {
  if(frame.hasMethod||!frame.hasId||(!frame.result&&!frame.error))return;
  for(unsigned i=0;i<16;++i){auto&entry=gLiveOutstanding[i];
    if(!entry.used||!SameId(entry.opened.requestId,frame.id))continue;
    LiveReply* available=nullptr;
    for(auto&reply:gLiveReplies){if(reply.used&&reply.serial==entry.serial){LiveLoss(live3::LiveAssociationUnknown);return;}if(!reply.used&&!available)available=&reply;}
    if(!available){LiveLoss(live3::LiveOutstandingOverflow);return;}
    available->used=true;available->ticket=ticket;available->serial=entry.serial;available->slot=i;
    available->event=entry.opened;available->event.kind=live3::LiveKind::ClientReply;
    available->event.attention=live3::NoAttention;available->event.flags|=live3::ExactRequest;
    if(frame.error)available->event.flags|=live3::ClientErrorReply;
    return;
  }
}
void AdmitLiveWrite(std::uint64_t ticket,bool admitted) {
  for(auto&reply:gLiveReplies){
    if(!reply.used||reply.ticket!=ticket)continue;
    auto&entry=gLiveOutstanding[reply.slot];
    if(admitted&&entry.used&&entry.serial==reply.serial){PublishLive(reply.event);ClearOutstanding(reply.slot);}
    else if(!admitted)LiveLoss(live3::LiveStreamGap);
    reply=LiveReply{};
  }
}
