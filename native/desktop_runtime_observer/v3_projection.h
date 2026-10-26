#pragma once
#include "v3_api.h"
#include <charconv>
#include <cstring>
#include <system_error>
using namespace ctz::observer_v2;

namespace live3 = ctz::observer_v3;
enum class LiveMethod : unsigned char { None, ThreadStatus, TurnStarted, TurnCompleted, CommandApproval, FileApproval, PermissionsApproval, UserInput, Elicitation, Resolved };
struct LiveFrame {
  LiveMethod method = LiveMethod::None;
  live3::LiveEvent fields{};
  bool invalid = false, threadSeen = false, turnSeen = false, statusSeen = false, activeFlagsSeen = false, requestIdSeen = false;
  LiveFrame() { fields.flags = live3::TurnIdAbsent; }
};
struct Frame {
  LiveFrame live;
  Method method = Method::None;
  TypedId id{};
  bool hasId = false, hasMethod = false, result = false, error = false, errorCode = false, accountObject = false, accountNull = false;
  Event fields{};
  AuthMode updateMode = AuthMode::Unknown;
  unsigned reason = 0, previousBytes = 0, updatePlanBytes = 0;
  unsigned previousFlags = AccountIdAbsent, updateFlags = PlanAbsent;
  char previous[128]{}, updatePlan[64]{};
  Frame() { fields.flags = EmailAbsent | PlanAbsent | AccountIdAbsent; }
};
void OnReadFrame(const Frame&);
void OnWriteFrame(const Frame&, std::uint64_t);
void OnInvalidFrame(bool, bool);
struct Stats {
  unsigned lines = 0, valid = 0, duplicateRejected = 0, rejected = 0, immediate = 0, pending = 0, gorCompleted = 0, drops = 0;
  bool coalesced = false, fragmented = false, immutable = true;
};

// Normal JSONL projection only. Unknown text, token values, arrays and strings have no storage.
struct Projection {
  enum class Path : unsigned char { Other, Root, Params, Result, Error, Account, Workspace, ThreadStatus, Turn, ActiveFlags };
  enum class Key : unsigned char { Other, Method, Id, Params, Result, Error, AuthMode, Plan, Reason, Previous, Type, Account, Email, Workspace, AccountId, Code, ThreadId, TurnId, Turn, Status, ActiveFlags, RequestId, IsBlocking };
  enum class State : unsigned char { KeyOrEnd, KeyOnly, Colon, Value, Comma, ArrayOrEnd, ArrayValue, ArrayComma };
  enum class Mode : unsigned char { None, String, Number, Literal };
  enum class Capture : unsigned char { None, Key, Method, Id, IdNumber, Code, AuthMode, Reason, Previous, UpdatePlan, Type, Email, Plan, AccountId, ReplyType, ThreadId, TurnId, ThreadStatus, TurnStatus, ActiveFlag, ResolvedId, ResolvedNumber, Blocking };
  struct Context { Path path; State state; Key key; bool object; unsigned seen; } stack[32]{};
  unsigned depth = 0, keyCount = 0, length = 0, unicodeLeft = 0, unicodeValue = 0, high = 0;
  unsigned numberState = 0, literalAt = 0, literalLength = 0;
  Mode mode = Mode::None; Capture capture = Capture::None;
  bool started = false, done = false, invalid = false, duplicate = false, spans = false;
  bool isKey = false, escape = false, tooLong = false, integral = true;
  char token[320]{}, rootKeys[16][64]{};
  const char* literal = nullptr;
  Frame frame;
  static bool space(char c) { return c==' ' || c=='\r' || c=='\t' || c=='\n'; }
  bool equal(const char* value) const { const auto n=std::strlen(value); return n==length && !std::memcmp(token,value,n); }
  static int hex(char c) { return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1; }
  unsigned capacity() const {
    switch(capture) { case Capture::Email:return 320; case Capture::Previous:case Capture::AccountId:return 128;
      case Capture::Id:case Capture::ResolvedId:return 64; case Capture::None:return 0; default:return 63; }
  }
  static bool liveCapture(Capture c) { return c >= Capture::ThreadId; }
  void selectedInvalid() { if(liveCapture(capture))frame.live.invalid=true;else frame.fields.flags|=SelectedFieldInvalid; }
  void selectedTooLong() { if(liveCapture(capture))frame.live.invalid=true;else frame.fields.flags|=SelectedFieldTooLong; }
  void append(unsigned c) {
    if(capture==Capture::None)return;
    if(!c){ if(capture==Capture::Key||capture==Capture::Method||capture==Capture::Id)invalid=true; else selectedInvalid(); tooLong=true; return; }
    if(length>=capacity()){tooLong=true;return;} token[length++]=static_cast<char>(c);
  }
  void codepoint(unsigned c) {
    if(capture==Capture::None)return;
    if(c>=0xd800&&c<=0xdbff){high=c;return;}
    if(high){if(c<0xdc00||c>0xdfff){selectedInvalid();tooLong=true;high=0;return;}c=0x10000+((high-0xd800)<<10)+(c-0xdc00);high=0;}
    if(c>=0xdc00&&c<=0xdfff){selectedInvalid();tooLong=true;return;}
    if(c<128)append(c);else if(c<2048){append(0xc0|(c>>6));append(0x80|(c&63));}
    else if(c<65536){append(0xe0|(c>>12));append(0x80|((c>>6)&63));append(0x80|(c&63));}
    else {append(0xf0|(c>>18));append(0x80|((c>>12)&63));append(0x80|((c>>6)&63));append(0x80|(c&63));}
  }
  Key key() const {
    if(equal("method"))return Key::Method;if(equal("id"))return Key::Id;if(equal("params"))return Key::Params;
    if(equal("result"))return Key::Result;if(equal("error"))return Key::Error;if(equal("authMode"))return Key::AuthMode;
    if(equal("planType"))return Key::Plan;if(equal("reason"))return Key::Reason;if(equal("previousAccountId"))return Key::Previous;
    if(equal("type"))return Key::Type;if(equal("account"))return Key::Account;if(equal("email"))return Key::Email;
    if(equal("workspaceRouting"))return Key::Workspace;if(equal("chatgptAccountId"))return Key::AccountId;if(equal("code"))return Key::Code;
    if(equal("threadId"))return Key::ThreadId;if(equal("turnId"))return Key::TurnId;if(equal("turn"))return Key::Turn;
    if(equal("status"))return Key::Status;if(equal("activeFlags"))return Key::ActiveFlags;if(equal("requestId"))return Key::RequestId;if(equal("isBlocking"))return Key::IsBlocking;
    return Key::Other;
  }
  Method method() const {
    if(equal("account/read"))return Method::AccountRead;if(equal("account/rateLimits/read"))return Method::RateLimitsRead;
    if(equal("thread/list"))return Method::ThreadList;if(equal("thread/read"))return Method::ThreadRead;
    if(equal("model/list"))return Method::ModelList;if(equal("config/read"))return Method::ConfigRead;
    if(equal("account/login/start"))return Method::AccountLoginStart;if(equal("account/chatgptAuthTokens/refresh"))return Method::Refresh;
    if(equal("account/updated"))return Method::AccountUpdated;return Method::None;
  }
  LiveMethod liveMethod() const {
    if(equal("thread/status/changed"))return LiveMethod::ThreadStatus;if(equal("turn/started"))return LiveMethod::TurnStarted;if(equal("turn/completed"))return LiveMethod::TurnCompleted;
    if(equal("item/commandExecution/requestApproval"))return LiveMethod::CommandApproval;if(equal("item/fileChange/requestApproval"))return LiveMethod::FileApproval;
    if(equal("item/permissions/requestApproval"))return LiveMethod::PermissionsApproval;if(equal("item/tool/requestUserInput"))return LiveMethod::UserInput;
    if(equal("mcpServer/elicitation/request"))return LiveMethod::Elicitation;if(equal("serverRequest/resolved"))return LiveMethod::Resolved;return LiveMethod::None;
  }
  void valueDone(){if(!depth){invalid=true;return;}auto&c=stack[depth-1];c.state=c.object?State::Comma:State::ArrayComma;}
  void close(){if(!depth){invalid=true;return;}--depth;if(!depth)done=true;else valueDone();}
  void push(bool object,Path path){if(depth==32){invalid=true;return;}stack[depth++]={path,object?State::KeyOrEnd:State::ArrayOrEnd,Key::Other,object,0};}
  void startString(bool keyValue,Capture selected){mode=Mode::String;isKey=keyValue;capture=selected;length=0;escape=false;unicodeLeft=0;unicodeValue=0;high=0;tooLong=false;}
  void stringDone(){
    if(high){tooLong=true;selectedInvalid();}
    if(isKey){
      if(tooLong){invalid=true;return;}
      if(depth==1){if(keyCount==16){invalid=true;return;}for(unsigned i=0;i<keyCount;++i)if(std::strlen(rootKeys[i])==length&&!std::memcmp(rootKeys[i],token,length)){invalid=true;duplicate=true;return;}
        std::memcpy(rootKeys[keyCount],token,length);rootKeys[keyCount++][length]=0;}
      auto&c=stack[depth-1];c.key=key();
      if(c.path!=Path::Other&&c.key!=Key::Other){const unsigned bit=1u<<static_cast<unsigned>(c.key);if(c.seen&bit){if(c.path==Path::ThreadStatus||c.path==Path::Turn||c.path==Path::ActiveFlags||c.key>=Key::ThreadId)frame.live.invalid=true;else frame.fields.flags|=SelectedFieldInvalid;}c.seen|=bit;}
      c.state=State::Colon;
    }else{
      if(tooLong)selectedTooLong();
      switch(capture){
        case Capture::Method:frame.hasMethod=true;if(tooLong)invalid=true;else {frame.method=method();frame.live.method=liveMethod();}break;
        case Capture::Id:if(tooLong)invalid=true;else{frame.hasId=true;frame.id.kind=IdKind::String;frame.id.length=length;std::memcpy(frame.id.text,token,length);}break;
        case Capture::AuthMode:frame.updateMode=equal("apikey")?AuthMode::ApiKey:equal("chatgpt")?AuthMode::Chatgpt:equal("chatgptAuthTokens")?AuthMode::ChatgptAuthTokens:AuthMode::Other;break;
        case Capture::Reason:frame.reason=equal("unauthorized")?1u:0u;break;
        case Capture::Previous:frame.previousFlags&=~AccountIdAbsent;if(tooLong)frame.previousFlags|=SelectedFieldTooLong;else{frame.previousBytes=length;std::memcpy(frame.previous,token,length);}break;
        case Capture::UpdatePlan:frame.updateFlags&=~PlanAbsent;if(tooLong)frame.updateFlags|=SelectedFieldTooLong;else{frame.updatePlanBytes=length;std::memcpy(frame.updatePlan,token,length);}break;
        case Capture::Type:frame.fields.accountType=equal("chatgpt")?AccountType::Chatgpt:equal("apiKey")||equal("apikey")?AccountType::ApiKey:AccountType::Other;break;
        case Capture::ReplyType:frame.fields.replyType=equal("chatgptAuthTokens")?ReplyType::ChatgptAuthTokens:ReplyType::Other;break;
        case Capture::Email:frame.fields.flags&=~EmailAbsent;if(!tooLong){frame.fields.emailBytes=length;std::memcpy(frame.fields.email,token,length);}break;
        case Capture::Plan:frame.fields.flags&=~PlanAbsent;if(!tooLong){frame.fields.planBytes=length;std::memcpy(frame.fields.plan,token,length);}break;
        case Capture::AccountId:frame.fields.flags&=~AccountIdAbsent;if(!tooLong){frame.fields.accountIdBytes=length;std::memcpy(frame.fields.accountId,token,length);}break;
        case Capture::ThreadId:if(tooLong||!length)frame.live.invalid=true;else{frame.live.threadSeen=true;std::memcpy(frame.live.fields.threadId,token,length);}break;
        case Capture::TurnId:if(tooLong||!length)frame.live.invalid=true;else{frame.live.turnSeen=true;frame.live.fields.flags&=~(live3::TurnIdAbsent|live3::TurnIdNull);std::memcpy(frame.live.fields.turnId,token,length);}break;
        case Capture::ResolvedId:if(tooLong)frame.live.invalid=true;else{frame.live.requestIdSeen=true;frame.live.fields.requestId.kind=IdKind::String;frame.live.fields.requestId.length=length;std::memcpy(frame.live.fields.requestId.text,token,length);}break;
        case Capture::ThreadStatus:
          frame.live.statusSeen=true;frame.live.fields.lifecycle=equal("notLoaded")?live3::Lifecycle::NotLoaded:equal("idle")?live3::Lifecycle::Idle:equal("systemError")?live3::Lifecycle::SystemError:equal("active")?live3::Lifecycle::Active:live3::Lifecycle::Unknown;
          if(frame.live.fields.lifecycle==live3::Lifecycle::Unknown)frame.live.invalid=true;break;
        case Capture::TurnStatus:
          frame.live.statusSeen=true;frame.live.fields.lifecycle=equal("inProgress")?live3::Lifecycle::InProgress:equal("completed")?live3::Lifecycle::Completed:equal("interrupted")?live3::Lifecycle::Interrupted:equal("failed")?live3::Lifecycle::Failed:live3::Lifecycle::Unknown;
          if(frame.live.fields.lifecycle==live3::Lifecycle::Unknown)frame.live.invalid=true;break;
        case Capture::ActiveFlag:if(equal("waitingOnApproval"))frame.live.fields.attention|=live3::Approval;else if(equal("waitingOnUserInput"))frame.live.fields.attention|=live3::UserInput;else frame.live.invalid=true;break;
        case Capture::Blocking:frame.live.invalid=true;break;
        default:break;
      }
      valueDone();
    }
    mode=Mode::None;capture=Capture::None;SecureZeroMemory(token,sizeof token);length=0;
  }
  void stringByte(char c){
    if(unicodeLeft){int h=hex(c);if(h<0){invalid=true;return;}unicodeValue=unicodeValue*16+static_cast<unsigned>(h);if(!--unicodeLeft)codepoint(unicodeValue);return;}
    if(escape){escape=false;switch(c){case'u':unicodeLeft=4;unicodeValue=0;return;case'"':append('"');return;case'\\':append('\\');return;case'/':append('/');return;case'b':append('\b');return;case'f':append('\f');return;case'n':append('\n');return;case'r':append('\r');return;case't':append('\t');return;default:invalid=true;return;}}
    unsigned b=static_cast<unsigned char>(c);if(c=='\\')escape=true;else if(c=='"')stringDone();else if(b<32)invalid=true;else append(b);
  }
  bool numberByte(char c){bool digit=c>='0'&&c<='9';switch(numberState){
    case 1:if(!digit){invalid=true;return true;}numberState=c=='0'?2u:3u;break;
    case 2:if(c=='.'){numberState=4;integral=false;}else if(c=='e'||c=='E'){numberState=6;integral=false;}else return false;break;
    case 3:if(digit){}else if(c=='.'){numberState=4;integral=false;}else if(c=='e'||c=='E'){numberState=6;integral=false;}else return false;break;
    case 4:if(!digit){invalid=true;return true;}numberState=5;break;
    case 5:if(digit){}else if(c=='e'||c=='E'){numberState=6;integral=false;}else return false;break;
    case 6:if(c=='+'||c=='-')numberState=7;else if(digit)numberState=8;else invalid=true;break;
    case 7:if(!digit)invalid=true;else numberState=8;break;case 8:if(!digit)return false;break;default:invalid=true;break;}
    append(static_cast<unsigned char>(c));return true;
  }
  void numberDone(){if(numberState!=2&&numberState!=3&&numberState!=5&&numberState!=8){invalid=true;return;}
    std::int64_t n=0;if((capture==Capture::IdNumber||capture==Capture::Code||capture==Capture::ResolvedNumber)&&integral&&!tooLong){auto p=std::from_chars(token,token+length,n);if(p.ec==std::errc{}&&p.ptr==token+length){if(capture==Capture::IdNumber){frame.hasId=true;frame.id.kind=IdKind::Number;frame.id.number=n;}else if(capture==Capture::ResolvedNumber){frame.live.requestIdSeen=true;frame.live.fields.requestId.kind=IdKind::Number;frame.live.fields.requestId.number=n;}else if(n>=INT32_MIN&&n<=INT32_MAX){frame.fields.rpcErrorCode=static_cast<std::int32_t>(n);frame.errorCode=true;}}}
    mode=Mode::None;capture=Capture::None;SecureZeroMemory(token,sizeof token);length=0;valueDone();}
  Capture selected() const {if(!depth)return Capture::None;const auto&c=stack[depth-1];
    if(c.path==Path::Root){if(c.key==Key::Method)return Capture::Method;if(c.key==Key::Id)return Capture::Id;}
    if(c.path==Path::Params){if(c.key==Key::AuthMode)return Capture::AuthMode;if(c.key==Key::Plan)return Capture::UpdatePlan;if(c.key==Key::Reason)return Capture::Reason;if(c.key==Key::Previous)return Capture::Previous;
      if(c.key==Key::ThreadId)return Capture::ThreadId;if(c.key==Key::TurnId)return Capture::TurnId;if(c.key==Key::RequestId)return Capture::ResolvedId;if(c.key==Key::IsBlocking)return Capture::Blocking;}
    if(c.path==Path::ThreadStatus&&c.key==Key::Type)return Capture::ThreadStatus;
    if(c.path==Path::Turn){if(c.key==Key::Id)return Capture::TurnId;if(c.key==Key::Status)return Capture::TurnStatus;}
    if(c.path==Path::ActiveFlags)return Capture::ActiveFlag;
    if(c.path==Path::Result&&c.key==Key::Type)return Capture::ReplyType;
    if(c.path==Path::Account){if(c.key==Key::Type)return Capture::Type;if(c.key==Key::Email)return Capture::Email;if(c.key==Key::Plan)return Capture::Plan;}
    if(c.path==Path::Workspace&&c.key==Key::AccountId)return Capture::AccountId;
    if(c.path==Path::Error&&c.key==Key::Code)return Capture::Code;return Capture::None;}
  void startValue(char c){auto&parent=stack[depth-1];const Capture target=selected();
    if(parent.path==Path::Root&&parent.key==Key::Result)frame.result=true;
    if(parent.path==Path::Root&&parent.key==Key::Error)frame.error=true;
    if(c=='"'){startString(false,target);return;}
    if(c=='{'||c=='['){Path path=Path::Other;if(c=='{'){
      if(parent.path==Path::Root&&parent.key==Key::Params)path=Path::Params;
      if(parent.path==Path::Root&&parent.key==Key::Result)path=Path::Result;
      if(parent.path==Path::Root&&parent.key==Key::Error)path=Path::Error;
      if(parent.path==Path::Result&&parent.key==Key::Account){path=Path::Account;frame.accountObject=true;}
      if(parent.path==Path::Result&&parent.key==Key::Workspace)path=Path::Workspace;
      if(parent.path==Path::Params&&parent.key==Key::Status)path=Path::ThreadStatus;
      if(parent.path==Path::Params&&parent.key==Key::Turn)path=Path::Turn;}
      if(c=='['&&parent.path==Path::ThreadStatus&&parent.key==Key::ActiveFlags){path=Path::ActiveFlags;frame.live.activeFlagsSeen=true;}
      if(liveCapture(target))frame.live.invalid=true;
      push(c=='{',path);return;}
    if(c=='-'||(c>='0'&&c<='9')){mode=Mode::Number;capture=target==Capture::Id?Capture::IdNumber:target==Capture::Code?Capture::Code:target==Capture::ResolvedId?Capture::ResolvedNumber:Capture::None;if(liveCapture(target)&&target!=Capture::ResolvedId)frame.live.invalid=true;length=0;tooLong=false;integral=true;numberState=c=='-'?1u:c=='0'?2u:3u;append(static_cast<unsigned char>(c));return;}
    literal=c=='t'?"true":c=='f'?"false":c=='n'?"null":nullptr;if(!literal){invalid=true;return;}
    if(liveCapture(target)){
      if(target==Capture::Blocking&&(c=='t'||c=='f')){frame.live.fields.flags|=live3::BlockingKnown;if(c=='t')frame.live.fields.flags|=live3::Blocking;}
      else if(target==Capture::TurnId&&c=='n'){frame.live.turnSeen=true;frame.live.fields.flags&=~live3::TurnIdAbsent;frame.live.fields.flags|=live3::TurnIdNull;}
      else frame.live.invalid=true;
    }
    if(c=='n'){
      if(parent.path==Path::Result&&parent.key==Key::Account){frame.accountNull=true;frame.fields.accountType=AccountType::Null;}
      if(target==Capture::AuthMode)frame.updateMode=AuthMode::None;
      if(target==Capture::Email){frame.fields.flags&=~EmailAbsent;frame.fields.flags|=EmailNull;}
      if(target==Capture::Plan){frame.fields.flags&=~PlanAbsent;frame.fields.flags|=PlanNull;}
      if(target==Capture::AccountId){frame.fields.flags&=~AccountIdAbsent;frame.fields.flags|=AccountIdNull;}
      if(target==Capture::Previous){frame.previousFlags&=~AccountIdAbsent;frame.previousFlags|=AccountIdNull;}
      if(target==Capture::UpdatePlan){frame.updateFlags&=~PlanAbsent;frame.updateFlags|=PlanNull;}}
    mode=Mode::Literal;literalAt=1;literalLength=static_cast<unsigned>(std::strlen(literal));capture=Capture::None;
  }
  void byte(char c){if(invalid)return;if(mode==Mode::String){stringByte(c);return;}if(mode==Mode::Literal){if(c!=literal[literalAt++]){invalid=true;return;}if(literalAt==literalLength){mode=Mode::None;valueDone();}return;}
    if(mode==Mode::Number){if(numberByte(c))return;numberDone();if(invalid)return;}if(space(c))return;if(done){invalid=true;return;}
    if(!started){if(c!='{'){invalid=true;return;}started=true;push(true,Path::Root);return;}if(!depth){invalid=true;return;}auto&current=stack[depth-1];
    switch(current.state){case State::KeyOrEnd:if(c=='}'){close();return;}[[fallthrough]];case State::KeyOnly:if(c=='"')startString(true,current.path==Path::Other?Capture::None:Capture::Key);else invalid=true;return;
      case State::Colon:if(c==':')current.state=State::Value;else invalid=true;return;case State::Value:startValue(c);return;
      case State::Comma:if(c=='}')close();else if(c==',')current.state=State::KeyOnly;else invalid=true;return;
      case State::ArrayOrEnd:if(c==']'){close();return;}[[fallthrough]];case State::ArrayValue:startValue(c);return;
      case State::ArrayComma:if(c==']')close();else if(c==',')current.state=State::ArrayValue;else invalid=true;return;}}
  void feed(const char*input,std::size_t count,Stats&stats,bool writer=false,std::uint64_t ticket=0){if(started||mode!=Mode::None)spans=true;unsigned completed=0;
    for(std::size_t i=0;i<count;++i){char c=input[i];if(c!='\n'){byte(c);continue;}byte(c);++stats.lines;++completed;
      if(!invalid&&started&&done&&!depth&&mode==Mode::None&&!(frame.result&&frame.error)){++stats.valid;if(writer)OnWriteFrame(frame,ticket);else OnReadFrame(frame);}
      else{++stats.rejected;if(duplicate)++stats.duplicateRejected;OnInvalidFrame(writer,duplicate);}if(spans)stats.fragmented=true;*this=Projection{};}
    if(completed>1)stats.coalesced=true;}
};
static_assert(sizeof(Projection)<4096,"constant projection storage");
