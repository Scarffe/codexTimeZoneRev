'use strict';
// Synthetic JWTs only. Never serialize a token into stdout, stderr or receipts.
const crypto=require('node:crypto');
const readline=require('node:readline');
const digest=crypto.createHash('sha256');
let bytes=0,frames=0,active=null,firstLogin=null,heldLogin=null,heldRead=null;
let holdB=false,holdReadB=false,logins=0,reads=0,baseline=0,probes=0,late=0,good=0,bad=0,valid=true;
function out(value){const wire=JSON.stringify(value)+'\n';const data=Buffer.from(wire);digest.update(data);bytes+=data.length;++frames;process.stdout.write(data);}
function oracle(ticket){process.stderr.write(JSON.stringify({event:'oracle',ticket,bytes,frames,sha256:digest.copy().digest('hex'),
  logins,reads,baseline,probes,lateAuthFrames:late,heldLogin:heldLogin!==null,heldRead:heldRead!==null,
  goodRefreshResponses:good,badRefreshResponses:bad,validSyntheticTokens:valid,activeIsB:active==='B',modelRequests:0})+'\n');}
function fail(){valid=false;process.stderr.write(JSON.stringify({event:'fixture-failed'})+'\n');process.exit(22);}
function token(credentials,refresh){
  if(!credentials||!['synthetic-account-A','synthetic-account-B'].includes(credentials.chatgptAccountId)||credentials.chatgptPlanType!=='plus'||typeof credentials.accessToken!=='string')return null;
  const marker=credentials.chatgptAccountId.slice(-1),parts=credentials.accessToken.split('.');
  if(parts.length!==3||parts[0]!=='e30'||parts[2]!==`synthetic-${refresh?'refreshed':'signature'}-${marker}`)return null;
  let claims;try{claims=JSON.parse(Buffer.from(parts[1],'base64url').toString('utf8'));}catch{return null;}
  return claims['https://api.openai.com/auth']?.chatgpt_account_id===credentials.chatgptAccountId&&claims.email===`synthetic-${marker}@example.invalid`?marker:null;
}
function ack(id){out({result:{type:'chatgptAuthTokens'},id});out({method:'account/updated',params:{authMode:'chatgptAuthTokens',planType:'plus'}});}
function account(id){out({result:{account:active?{type:'chatgpt',email:`synthetic-${active}@example.invalid`,planType:'plus'}:null,
  ...(active?{workspaceRouting:{chatgptAccountId:`synthetic-account-${active}`}}:{})},id});}
function control(params){
  switch(params.op){
    case 'snapshot':break;
    case 'hold-b':holdB=true;holdReadB=true;break;
    case 'late-a':if(!firstLogin)return fail();ack(firstLogin);late+=2;break;
    case 'release-login':if(!heldLogin)return fail();ack(heldLogin);heldLogin=null;break;
    case 'release-read':if(!heldRead)return fail();account(heldRead);heldRead=null;holdReadB=false;break;
    case 'refresh-bad':out({method:'account/chatgptAuthTokens/refresh',id:7701,params:{reason:'unauthorized',previousAccountId:'synthetic-account-A'}});break;
    case 'refresh-good':out({method:'account/chatgptAuthTokens/refresh',id:'owned-refresh-good-B',params:{reason:'unauthorized',previousAccountId:'synthetic-account-B'}});break;
    case 'exit':oracle(params.ticket);process.stderr.write('',()=>process.stdout.write('',()=>process.exit(0)));return;
    default:return fail();
  }
  oracle(params.ticket);
}
readline.createInterface({input:process.stdin}).on('line',line=>{
  let value;try{value=JSON.parse(line);}catch{return fail();}
  if(value.method==='fixture/control')return control(value.params||{});
  if(value.method==='thread/loaded/list'){
    if(value.params?.limit!==8||value.params?.cursor!==null)return fail();
    return out({id:value.id,result:{data:['00000000-0000-7000-8000-000000000001'],nextCursor:null}});
  }
  if(value.method==='thread/read'){
    if(value.params?.threadId!=='00000000-0000-7000-8000-000000000001'||value.params?.includeTurns!==false)return fail();
    return out({id:value.id,result:{thread:{id:value.params.threadId,status:{type:'active',activeFlags:['waitingOnApproval']},turns:[],preview:'SYNTHETIC_BODY_EXCLUDED'}}});
  }
  if(value.method==='account/read'){
    if(value.params?.refreshToken!==false)return fail();++reads;
    if(typeof value.id==='string'&&value.id.startsWith('owned-baseline-'))++baseline;
    const probe=typeof value.id==='string'&&value.id.startsWith('thread/read:ctz-p-');if(probe)++probes;
    if(active==='B'&&holdReadB&&!probe){if(heldRead)return fail();heldRead=value.id;return;}
    return account(value.id);
  }
  if(value.method==='account/login/start'){
    if(value.params?.type!=='chatgptAuthTokens')return fail();
    const marker=token(value.params,false);if(!marker)return fail();active=marker;++logins;
    if(marker==='A'&&!firstLogin)firstLogin=value.id;
    if(marker==='B'&&holdB){heldLogin=value.id;holdB=false;return;}
    return ack(value.id);
  }
  if(!value.method&&value.id===7701){++bad;return fail();}
  if(!value.method&&value.id==='owned-refresh-good-B'){
    if(token(value.result,true)!=='B'||active!=='B')return fail();++good;
    return out({id:'owned-refresh-continued',result:{continued:true}});
  }
  return fail();
});
