'use strict';
const readline=require('node:readline');
const frames=require('./v3_live_frames.cjs');
const input=readline.createInterface({input:process.stdin});
let natural=0,wrongTyped=false,continued=false;
function fragments(wire){
  const pieces=[wire.slice(0,1),wire.slice(1,4),wire.slice(4,21),wire.slice(21)];
  const next=()=>{if(!pieces.length)return;process.stdout.write(pieces.shift(),()=>setImmediate(next));};next();
}
input.on('line',line=>{
  if(line==='exit'){input.close();process.exit(continued?0:26);}
  let value;try{value=JSON.parse(line);}catch{process.exit(21);}
  if(['account/read','account/rateLimits/read'].includes(value.method)&&typeof value.id==='string'){
    process.stdout.write(frames.response(value.id,value.method));
    if(frames.probes.some(([id])=>id===value.id)&&++natural===2)fragments(frames.first);
  }else if(value.id==='17'&&!value.method&&value.result?.decision==='decline'){wrongTyped=true;}
  else if(value.id===17&&!value.method&&value.result?.decision==='decline'&&wrongTyped&&!continued){continued=true;fragments(frames.tail);}
  else process.exit(22);
});
