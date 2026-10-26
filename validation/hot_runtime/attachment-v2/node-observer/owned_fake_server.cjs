'use strict';
const readline = require('node:readline');
const frames = require('./fixture_frames.cjs');
if (process.argv[2] !== process.env.CTZ_OWNED_NONCE || process.env.CTZ_OWNED_NO_CREDENTIALS !== '1') process.exit(21);
const input = readline.createInterface({input:process.stdin});
const seen = new Set(); let started=false, done=false;
input.on('line', async line => {
  if (line === 'exit') { input.close(); process.exit(done ? 0 : 22); }
  if (line === 'go' && !started) {
    started=true; process.stdout.write(frames.prefix);
    const pieces=[1,2,3,5,7,11]; let at=0, index=0;
    while (at < frames.last.length) {
      const n=pieces[index++ % pieces.length]; process.stdout.write(frames.last.slice(at,at+n)); at+=n;
      await new Promise(resolve => setTimeout(resolve,3));
    }
    return;
  }
  let value; try { value=JSON.parse(line); } catch { process.exit(23); }
  const validId=value.id === 101 || value.id === 'owned-string-2';
  if (!started || done || !validId || seen.has(value.id) || JSON.stringify(value.result) !== '{"fixtureAck":true}' || Object.keys(value).sort().join(',') !== 'id,result') process.exit(24);
  seen.add(value.id);
  if (seen.size===2) { done=true; process.stdout.write(frames.final); }
});
