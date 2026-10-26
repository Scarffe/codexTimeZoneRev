const {spawn}=require('node:child_process');
const readline=require('node:readline');
const path=require('node:path');
const script=path.resolve(__dirname,'..','fake_app_server.cjs');
const children={};const startedAt=Date.now();
for(const role of ['target','control']){
  const child=spawn(process.execPath,[script],{stdio:['pipe','pipe','pipe'],windowsHide:true});children[role]=child;
  readline.createInterface({input:child.stdout}).on('line',line=>process.stdout.write(JSON.stringify({event:'child-message',role,message:JSON.parse(line),parentPid:process.pid,childPid:child.pid,startedAt})+'\n'));
}
readline.createInterface({input:process.stdin}).on('line',line=>{
 const command=JSON.parse(line);const child=children[command.role];
 child.stdin.write(JSON.stringify({id:command.seq,method:command.type==='exit'?'fixture/exit':'fixture/read'})+'\n');
});
let exits=0;for(const child of Object.values(children))child.on('exit',()=>{if(++exits===2)process.exit(0);});
process.stdout.write(JSON.stringify({event:'fixture-ready',parentPid:process.pid,targetPid:children.target.pid,controlPid:children.control.pid,startedAt})+'\n');
