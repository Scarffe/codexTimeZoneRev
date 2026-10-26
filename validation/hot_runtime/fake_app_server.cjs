const readline = require('node:readline');
let authRevision = 0;
readline.createInterface({input:process.stdin}).on('line', line => {
  let req; try { req = JSON.parse(line); } catch { process.stdout.write(JSON.stringify({method:'fixture/parseError'})+'\n'); return; }
  if (req.method === 'fixture/exit') process.exit(0);
  if (req.method === 'fixture/auth-update') { authRevision++; process.stdout.write(JSON.stringify({method:'account/updated',params:{authMode:'fixture',authRevision}})+'\n'); }
  process.stdout.write(JSON.stringify({id:req.id,result:{fixture:true,authRevision}})+'\n');
});
