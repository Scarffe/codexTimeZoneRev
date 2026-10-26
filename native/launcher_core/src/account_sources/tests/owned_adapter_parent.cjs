'use strict';
// Sole child-stdout reader. Only hash/count oracle receipts reach the Rust test.
const {spawn}=require('node:child_process');
const crypto=require('node:crypto');
const path=require('node:path');
const readline=require('node:readline');
const child=spawn(process.execPath,[path.join(__dirname,'owned_adapter_server.cjs')],{
  stdio:['pipe','pipe','pipe'],windowsHide:true,
  env:{SystemRoot:process.env.SystemRoot,WINDIR:process.env.WINDIR,TEMP:process.env.TEMP,TMP:process.env.TMP}});
const digest=crypto.createHash('sha256');
let bytes=0,frames=0,stderr='',pending=[],allHashes=true,exiting=false;
const output=value=>process.stdout.write(JSON.stringify(value)+'\n');
function flush(){
  while(pending.length&&bytes>=pending[0].bytes){
    const oracle=pending.shift();
    const equal=bytes===oracle.bytes&&frames===oracle.frames&&digest.copy().digest('hex')===oracle.sha256;
    allHashes=allHashes&&equal;
    const {sha256,...counts}=oracle;
    output({...counts,event:'oracle',hashEqual:equal,allHashesEqual:allHashes});
  }
}
child.stdout.on('data',data=>{
  digest.update(data);bytes+=data.length;
  for(const byte of data)if(byte===10)++frames;
  flush();
});
child.stderr.on('data',data=>{
  stderr+=data.toString('utf8');let end;
  while((end=stderr.indexOf('\n'))>=0){
    const line=stderr.slice(0,end);stderr=stderr.slice(end+1);
    let oracle;try{oracle=JSON.parse(line);}catch{output({event:'fixture-failed',code:1});continue;}
    if(oracle.event!=='oracle'||!Number.isSafeInteger(oracle.bytes)){output({event:'fixture-failed',code:2});continue;}
    pending.push(oracle);flush();
  }
});
child.on('error',()=>{output({event:'fixture-failed',code:3});process.exitCode=23;});
child.on('close',code=>{if(!exiting)output({event:'fixture-failed',code:4});process.stdout.write('',()=>process.exit(code===0&&exiting?0:24));});
readline.createInterface({input:process.stdin}).on('line',line=>{
  let value;try{value=JSON.parse(line);}catch{output({event:'fixture-failed',code:5});return;}
  if(value.op==='baseline')for(let i=0;i<3;++i)child.stdin.write(JSON.stringify({id:`owned-baseline-${i}`,method:'account/read',params:{refreshToken:false}})+'\n');
  if(value.op==='exit')exiting=true;
  child.stdin.write(JSON.stringify({id:`owned-control-${value.ticket}`,method:'fixture/control',params:{op:value.op==='baseline'?'snapshot':value.op,ticket:value.ticket}})+'\n');
});
output({event:'spawned',ownerPid:process.pid,childPid:child.pid});
