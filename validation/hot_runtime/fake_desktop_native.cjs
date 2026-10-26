const {spawn} = require('node:child_process');
const readline = require('node:readline');
const child = spawn(process.argv[2], ['--fixture-server'], {stdio:['pipe','pipe','pipe'],windowsHide:true});
const startedAt = Date.now();
readline.createInterface({input:child.stdout}).on('line', line => {
  const message=JSON.parse(line);
  process.stdout.write(JSON.stringify({event:'child-message',message,parentPid:process.pid,childPid:child.pid,startedAt})+'\n');
});
readline.createInterface({input:process.stdin}).on('line', line => {
  const command=JSON.parse(line);
  child.stdin.write(JSON.stringify({id:'normal-'+command.seq,method:command.type==='exit'?'fixture/exit':'fixture/read'})+'\n');
});
child.on('exit',(code,signal)=>{process.stdout.write(JSON.stringify({event:'child-exit',code,signal})+'\n');process.exit(code||0);});
process.stdout.write(JSON.stringify({event:'fixture-ready',parentPid:process.pid,childPid:child.pid,startedAt})+'\n');
