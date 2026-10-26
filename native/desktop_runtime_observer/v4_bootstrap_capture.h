#pragma once
extern bootstrap4::Shared* gBootstrapShared;
std::uint64_t gBootstrapSequence=0;
void ResetBootstrapCapture(){gBootstrapSequence=0;}
void BootstrapIssue(LONG reason,bool dropped=false){
  if(!gBootstrapShared)return;
  InterlockedOr(&gBootstrapShared->bootstrapCoverageFlags,bootstrap4::BootstrapUnknown|reason);
  if(dropped)InterlockedIncrement(&gBootstrapShared->bootstrapDrops);else InterlockedIncrement(&gBootstrapShared->bootstrapRejected);
}
bool PublishBootstrap(bootstrap4::BootstrapEvent* events,unsigned count){
  auto* shared=gBootstrapShared;if(!shared)return false;
  const LONG head=InterlockedCompareExchange(&shared->bootstrapHead,0,0),tail=InterlockedCompareExchange(&shared->bootstrapTail,0,0);
  if(head-tail+static_cast<LONG>(count)>16){BootstrapIssue(bootstrap4::BootstrapQueueOverflow,true);return false;}
  for(unsigned i=0;i<count;++i){
    events[i].generation=shared->runtime.auth.generation;events[i].sequence=++gBootstrapSequence;events[i].observedAtMs=GetTickCount64();
    shared->bootstrapEvents[(static_cast<unsigned>(head)+i)%16]=events[i];
  }
  InterlockedExchangeAdd(&shared->bootstrapPublished,static_cast<LONG>(count));
  InterlockedExchange(&shared->bootstrapHead,head+static_cast<LONG>(count));return true;
}
bool BootstrapPurpose(Purpose purpose){const auto value=static_cast<unsigned>(purpose);return value==3||value==4;}
void BootstrapObserved(RequestControl& control){
  // A correlated response has been consumed even when metadata is partial or
  // its independent ring is full. Do not pin slots needed by authentication.
  InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&control.state),static_cast<LONG>(ControlState::Observed),static_cast<LONG>(ControlState::Active));
}
void OwnedBootstrap(const Frame& frame,RequestControl& control){
  bootstrap4::BootstrapEvent events[9]{};unsigned count=0;
  const auto& fields=frame.bootstrap;
  if(frame.error){
    auto& event=events[count++];event.kind=bootstrap4::BootstrapKind::RequestError;event.requestId=frame.id;
    event.flags=bootstrap4::ErrorPresent|bootstrap4::Incomplete;
    if(frame.errorCode){event.flags|=bootstrap4::ErrorCodePresent;event.rpcErrorCode=frame.fields.rpcErrorCode;}
    BootstrapIssue(bootstrap4::BootstrapRpcError);
  }else if(static_cast<unsigned>(control.purpose)==3){
    unsigned flags=fields.flags|bootstrap4::ResultPresent;
    const bool cursor=(flags&(bootstrap4::CursorPresent|bootstrap4::CursorNull))!=0;
    if(!(flags&bootstrap4::DataPresent)||!cursor||(flags&(bootstrap4::CursorMissing|bootstrap4::CursorTooLong|bootstrap4::IdInvalid|bootstrap4::TooManyItems|bootstrap4::Incomplete))){
      flags|=bootstrap4::Incomplete;BootstrapIssue(bootstrap4::BootstrapProjectionIncomplete);
    }else flags|=bootstrap4::Complete;
    for(unsigned i=0;i<fields.count;++i){auto& event=events[count++];event.kind=bootstrap4::BootstrapKind::PageItem;event.flags=flags|bootstrap4::ThreadIdPresent;
      event.requestId=frame.id;event.index=i;event.count=fields.count;event.valueBytes=static_cast<unsigned>(std::strlen(fields.ids[i]));std::memcpy(event.value,fields.ids[i],event.valueBytes);}
    auto& end=events[count++];end.kind=bootstrap4::BootstrapKind::PageEnd;end.flags=flags;end.requestId=frame.id;end.index=end.count=fields.count;
    if(!(flags&bootstrap4::CursorTooLong)){end.valueBytes=fields.cursorBytes;std::memcpy(end.value,fields.cursor,end.valueBytes);}
    InterlockedIncrement(&gBootstrapShared->bootstrapPages);
  }else{
    auto& event=events[count++];event.kind=bootstrap4::BootstrapKind::ThreadSnapshot;event.requestId=frame.id;
    event.flags=(fields.flags&(bootstrap4::ThreadIdPresent|bootstrap4::StatusPresent|bootstrap4::ActiveFlagsPresent|bootstrap4::IdInvalid|bootstrap4::UnrecognizedStatus|bootstrap4::Incomplete))|bootstrap4::ResultPresent;
    if(!(event.flags&bootstrap4::ThreadIdPresent)||!(event.flags&bootstrap4::StatusPresent)||(event.flags&bootstrap4::Incomplete)||
      (fields.status==live3::Lifecycle::Active&&!(event.flags&bootstrap4::ActiveFlagsPresent))){
      event.flags|=bootstrap4::Incomplete;BootstrapIssue(bootstrap4::BootstrapProjectionIncomplete);
    }else event.flags|=bootstrap4::Complete;
    event.status=fields.status;event.attention=fields.status==live3::Lifecycle::Active?fields.attention:0;
    event.valueBytes=fields.threadBytes;std::memcpy(event.value,fields.threadId,event.valueBytes);
    InterlockedIncrement(&gBootstrapShared->bootstrapSnapshots);
  }
  PublishBootstrap(events,count);BootstrapObserved(control);
}
