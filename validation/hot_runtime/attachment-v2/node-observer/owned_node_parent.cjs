'use strict';
const {spawn}=require('node:child_process');
const readline=require('node:readline');
const crypto=require('node:crypto');
const path=require('node:path');
const frames=require('./fixture_frames.cjs');
const nonce=process.env.CTZ_OWNED_NONCE;
if (!/^[a-f0-9]{32}$/.test(nonce || '') || process.env.CTZ_OWNED_NO_CREDENTIALS !== '1') process.exit(11);
const childEnv={SystemRoot:process.env.SystemRoot,WINDIR:process.env.WINDIR,TEMP:process.env.TEMP,TMP:process.env.TMP,CTZ_OWNED_NONCE:nonce,CTZ_OWNED_NO_CREDENTIALS:'1'};
const child=spawn(process.execPath,[path.join(__dirname,'owned_fake_server.cjs'),nonce],{stdio:['pipe','pipe','pipe'],windowsHide:true,env:childEnv});
const expected=Buffer.from(frames.all), hash=crypto.createHash('sha256');
let count=0, lineCount=0, collected='', completed=false, stderrBytes=0;
const control=value => process.stdout.write(JSON.stringify(value)+'\n');
child.stderr.on('data',data => { stderrBytes+=data.length; });
child.stdout.on('data',data => {
  // This is the one original stdout reader; raw bytes are never copied to broker stdout.
  if (completed) { control({event:'extra-bytes',nonce,bytes:data.length}); return; }
  hash.update(data); count+=data.length; collected+=data.toString('utf8');
  for (const byte of data) if (byte===10) ++lineCount;
  if (!completed && count>=expected.length) {
    completed=true;
    const digest=hash.digest('hex');
    control({event:'complete',nonce,bytes:count,frames:lineCount,byteEqual:collected===frames.all,hashEqual:digest===crypto.createHash('sha256').update(expected).digest('hex'),continued:collected.includes('"method":"fixture/continued"'),stderrEmpty:stderrBytes===0});
  }
});
child.on('error',() => { control({event:'child-error',nonce}); process.exit(12); });
child.on('exit',code => { if (!completed || code!==0) control({event:'child-exit-failed',nonce,code}); });
const input=readline.createInterface({input:process.stdin});
input.on('line',line => {
  if (line==='go') child.stdin.write('go\n');
  else if (line==='exit') {
    const timer=setTimeout(() => { child.kill(); process.exit(13); },1000);
    child.once('exit',code => { clearTimeout(timer); process.exit(code===0 ? 0 : 13); });
    child.stdin.write('exit\n');
  }
});
control({event:'ready',nonce,parentPid:process.pid,childPid:child.pid,nodeVersion:process.versions.node,uvVersion:process.versions.uv});
