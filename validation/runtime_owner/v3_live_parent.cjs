'use strict';
const {spawn}=require('node:child_process');
const readline=require('node:readline');
const crypto=require('node:crypto');
const path=require('node:path');
const frames=require('./v3_live_frames.cjs');
const child=spawn(process.execPath,[path.join(__dirname,'v3_live_server.cjs')],{
  stdio:['pipe','pipe','pipe'],windowsHide:true,
  env:{SystemRoot:process.env.SystemRoot,WINDIR:process.env.WINDIR,TEMP:process.env.TEMP,TMP:process.env.TMP}});
let phase='idle',collected='',stderrBytes=0,lineBuffer='',replyCount=0;
const control=value=>process.stdout.write(JSON.stringify(value)+'\n');
child.stderr.on('data',data=>{stderrBytes+=data.length;});
child.stdout.on('data',data=>{
  if(!['baseline','probe'].includes(phase)){control({event:'unexpected-stream'});return;}
  const chunk=data.toString('utf8');collected+=chunk;
  if(phase==='probe'){
    lineBuffer+=chunk;
    let end;
    while((end=lineBuffer.indexOf('\n'))>=0){
      const line=lineBuffer.slice(0,end);lineBuffer=lineBuffer.slice(end+1);
      let value;try{value=JSON.parse(line);}catch{control({event:'invalid-frame'});return;}
      if(value.method==='item/commandExecution/requestApproval'&&value.id===17&&replyCount===0){
        child.stdin.write(JSON.stringify({id:'17',result:{decision:'decline'}})+'\n');
        child.stdin.write(JSON.stringify({result:{decision:'decline'},id:17})+'\n');
        replyCount=2;
      }
    }
  }
  const expected=phase==='baseline'?frames.baseline:frames.observed;
  if(Buffer.byteLength(collected)<Buffer.byteLength(expected))return;
  const event=phase==='baseline'?'baseline-complete':'probe-complete';
  control({event,bytes:Buffer.byteLength(collected),frames:[...collected].filter(x=>x==='\n').length,
    hashEqual:crypto.createHash('sha256').update(collected).digest('hex')===crypto.createHash('sha256').update(expected).digest('hex'),
    byteEqual:collected===expected,stderrEmpty:stderrBytes===0,replyCount});
  phase=phase==='baseline'?'waiting':'done';collected='';
});
child.on('error',()=>{control({event:'child-error'});process.exit(23);});
const input=readline.createInterface({input:process.stdin});
input.on('line',line=>{
  if(line==='warmup'&&phase==='idle'){
    phase='baseline';
    for(let i=0;i<3;++i)child.stdin.write(JSON.stringify({id:`baseline-${i}`,method:'account/read',params:{refreshToken:false}})+'\n');
  }else if(line==='probe'&&phase==='waiting'){
    phase='probe';
    for(const [id,method]of frames.probes)child.stdin.write(JSON.stringify({id,method,params:{refreshToken:false}})+'\n');
  }else if(line==='exit'){
    const timer=setTimeout(()=>{child.kill();process.exit(24);},1000);
    child.once('exit',code=>{clearTimeout(timer);process.exit(code===0?0:25);});
    child.stdin.write('exit\n');
  }
});
control({event:'spawned',parentPid:process.pid,childPid:child.pid,nodeVersion:process.versions.node,uvVersion:process.versions.uv});
