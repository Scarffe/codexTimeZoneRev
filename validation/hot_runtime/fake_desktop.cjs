const {spawn} = require('node:child_process');
const readline = require('node:readline');
const path = require('node:path');
const child = spawn(process.execPath,[path.join(__dirname,'fake_app_server.cjs')],{stdio:['pipe','pipe','pipe'],windowsHide:true});
const startedAt = Date.now();
let notifications = 0;
readline.createInterface({input:child.stdout}).on('line', line => {
  const msg = JSON.parse(line);
  if (msg.method) notifications++;
  process.stdout.write(JSON.stringify({event:'child-message',message:msg,parentPid:process.pid,childPid:child.pid,startedAt,notifications})+'\n');
});
child.on('exit',(code,signal)=>{process.stdout.write(JSON.stringify({event:'child-exit',code,signal})+'\n'); process.exit(code||0);});
readline.createInterface({input:process.stdin}).on('line', line => {
  const cmd=JSON.parse(line);
  if (cmd.type==='normal-write') child.stdin.write(JSON.stringify({id:'normal-'+cmd.seq,method:'fixture/read'})+'\n');
  if (cmd.type==='exit') child.stdin.write(JSON.stringify({id:'exit',method:'fixture/exit'})+'\n');
});
process.stdout.write(JSON.stringify({event:'fixture-ready',parentPid:process.pid,childPid:child.pid,startedAt,fixtureStdinHandle:child.stdin._handle.fd,fixtureStdoutHandle:child.stdout._handle.fd,fixtureStderrHandle:child.stderr._handle.fd})+'\n');
