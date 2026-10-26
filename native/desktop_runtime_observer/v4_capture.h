#pragma once
#include "v4_projection.h"
extern Shared* gShared;
volatile LONG gCoreLosses = 0;
struct Natural {
  TypedId id{}; Method method=Method::None; std::uint64_t ticket=0;
  bool used=false, admitted=false, responded=false;
};
Natural gNatural[16]{};
TypedId gProofIds[2]{};
unsigned gProofCount=0;
std::uint64_t gWriteTicket=0, gSequence=0;
bool SameId(const TypedId&a,const TypedId&b){return a.kind==b.kind&&(a.kind==IdKind::Number?a.number==b.number:a.kind==IdKind::String&&a.length==b.length&&a.length<=64&&!std::memcmp(a.text,b.text,a.length));}
#include "v3_live_capture.h"
#include "v4_bootstrap_capture.h"
void Loss(LONG flag){BootstrapIssue(bootstrap4::BootstrapStreamGap);LiveLoss(live3::LiveStreamGap);InterlockedIncrement(&gCoreLosses);InterlockedIncrement(&gShared->drops);InterlockedOr(&gShared->coverageFlags,CoverageUnknown|flag);InterlockedExchange(&gShared->writerReady,0);}
bool Publish(Event event){
  const LONG h=InterlockedCompareExchange(&gShared->head,0,0),t=InterlockedCompareExchange(&gShared->tail,0,0);
  if(h-t>=16){Loss(QueueOverflow);return false;}
  event.generation=gShared->generation;event.sequence=++gSequence;event.observedAtMs=GetTickCount64();
  gShared->events[static_cast<unsigned>(h)%16]=event;InterlockedExchange(&gShared->head,h+1);return true;
}
void ResetCapture(){SecureZeroMemory(gNatural,sizeof gNatural);SecureZeroMemory(gProofIds,sizeof gProofIds);gProofCount=0;gWriteTicket=0;gSequence=0;InterlockedExchange(&gCoreLosses,0);ResetLiveCapture();ResetBootstrapCapture();}
bool NaturalRead(Method method){return method>=Method::AccountRead&&method<=Method::ConfigRead;}
void Finalize(Natural&entry){
  if(!entry.used||!entry.admitted||!entry.responded)return;
  bool distinct=true;for(unsigned i=0;i<gProofCount;++i)if(SameId(gProofIds[i],entry.id))distinct=false;
  if(distinct&&gProofCount<2)gProofIds[gProofCount++]=entry.id;
  gShared->writerMatchedPairs=static_cast<LONG>(gProofCount);
  if(gProofCount==2&&!gShared->coverageFlags&&!gShared->writerReady){
    Event event{};event.kind=EventKind::ChannelBound;event.flags=FieldsComplete;event.id=entry.id;
    if(Publish(event))InterlockedExchange(&gShared->writerReady,1);
  }
  entry=Natural{};
}
void OnWriteFrame(const Frame&frame,std::uint64_t ticket){
  OnLiveWrite(frame,ticket);
  if(!frame.hasMethod||!frame.hasId||!NaturalRead(frame.method)||frame.result||frame.error)return;
  Natural*free=nullptr;
  for(auto&entry:gNatural){if(entry.used&&SameId(entry.id,frame.id)){Loss(AssociationAmbiguous);return;}if(!entry.used&&!free)free=&entry;}
  if(!free){Loss(AssociationAmbiguous);return;}
  free->used=true;free->id=frame.id;free->method=frame.method;free->ticket=ticket;
}
void AdmitWrite(std::uint64_t ticket,bool admitted){
  AdmitLiveWrite(ticket,admitted);
  if(!admitted){Loss(RejectedWrite);SecureZeroMemory(gNatural,sizeof gNatural);return;}
  for(auto&entry:gNatural)if(entry.used&&entry.ticket==ticket){entry.admitted=true;Finalize(entry);}
}
void OwnedResponse(const Frame&frame){
  RequestControl*match=nullptr;
  for(auto&control:gShared->controls){
    const LONG state=InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&control.state),0,0);
    if(state==static_cast<LONG>(ControlState::Active)&&control.generation==gShared->generation&&SameId(control.id,frame.id)){
      if(match){Loss(ControlIncomplete);return;}match=&control;
    }
  }
  if(!match)return;
  if(BootstrapPurpose(match->purpose)){OwnedBootstrap(frame,*match);return;}
  Event event=frame.fields;event.id=frame.id;event.direction=1;
  event.flags|=(frame.result?ResultPresent:0u)|(frame.error?ErrorPresent:0u);
  const bool selectedGood=!(event.flags&(SelectedFieldTooLong|SelectedFieldInvalid));
  if(match->purpose==Purpose::AccountLoginStart){
    event.kind=EventKind::OwnedReply;event.method=Method::AccountLoginStart;
    event.emailBytes=event.planBytes=event.accountIdBytes=0;SecureZeroMemory(event.email,sizeof event.email);SecureZeroMemory(event.plan,sizeof event.plan);SecureZeroMemory(event.accountId,sizeof event.accountId);
    event.accountType=AccountType::Unknown;event.authMode=AuthMode::Unknown;event.refreshReason=0;
    event.flags=(frame.result?ResultPresent:0u)|(frame.error?ErrorPresent:0u);
    if(selectedGood&&((frame.result&&event.replyType==ReplyType::ChatgptAuthTokens)||(frame.error&&frame.errorCode)))event.flags|=FieldsComplete;
  }else if(match->purpose==Purpose::AccountRead){
    event.kind=EventKind::OwnedAccountRead;event.method=Method::AccountRead;
    event.replyType=ReplyType::Unknown;
    const bool identity=event.accountType==AccountType::Null||(event.accountType==AccountType::Chatgpt&&event.emailBytes&&event.planBytes&&!(event.flags&(EmailAbsent|EmailNull|PlanAbsent|PlanNull)));
    if(selectedGood&&((frame.result&&identity)||(frame.error&&frame.errorCode)))event.flags|=FieldsComplete;
  }else{Loss(ControlIncomplete);return;}
  if(Publish(event)){
    InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&match->state),static_cast<LONG>(ControlState::Observed),static_cast<LONG>(ControlState::Active));
    InterlockedIncrement(&gShared->ownedControlsObserved);
  }
}
void OnReadFrame(const Frame&frame){
  OnLiveRead(frame);
  if(!frame.hasMethod&&frame.hasId&&(frame.result||frame.error)){
    for(auto&entry:gNatural)if(entry.used&&SameId(entry.id,frame.id)){
      if(frame.result||(frame.error&&frame.errorCode)){entry.responded=true;Finalize(entry);}else Loss(InvalidFrame);
    }
    OwnedResponse(frame);return;
  }
  if(frame.method==Method::Refresh&&frame.hasId){
    Event event{};event.kind=EventKind::RefreshRequest;event.method=Method::Refresh;event.direction=1;event.id=frame.id;
    event.refreshReason=frame.reason;event.flags=frame.previousFlags|(frame.fields.flags&(SelectedFieldInvalid|SelectedFieldTooLong));
    event.accountIdBytes=frame.previousBytes;std::memcpy(event.accountId,frame.previous,frame.previousBytes);
    if(!(event.flags&(SelectedFieldTooLong|SelectedFieldInvalid)))event.flags|=FieldsComplete;
    Publish(event);
  }else if(frame.method==Method::AccountUpdated){
    Event event{};event.kind=EventKind::AccountUpdated;event.method=Method::AccountUpdated;event.direction=1;
    event.authMode=frame.updateMode;event.flags=frame.updateFlags|(frame.fields.flags&(SelectedFieldInvalid|SelectedFieldTooLong));
    event.planBytes=frame.updatePlanBytes;std::memcpy(event.plan,frame.updatePlan,frame.updatePlanBytes);
    if(event.authMode!=AuthMode::Unknown&&!(event.flags&(SelectedFieldTooLong|SelectedFieldInvalid)))event.flags|=FieldsComplete;
    Publish(event);
  }
}
void OnInvalidFrame(bool,bool){Loss(InvalidFrame);}
