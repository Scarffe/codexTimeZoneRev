#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const root=path.resolve(process.argv[2]||path.join(__dirname,'..'));
const file=path.join(root,'flutter_app/assets/source/brand-generation.json');
assert.ok(fs.existsSync(file),'original brand generation manifest exists');
const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const sizes=[16,20,24,32,48,64,128,256];
assert.deepEqual(manifest.sizes,sizes);
assert.equal(hash(fs.readFileSync(path.join(root,manifest.canonicalGenerator))),manifest.canonicalGeneratorSha256,'generator provenance');
let checked=0;
for(const [relative,record] of Object.entries(manifest.generated)){
  const bytes=fs.readFileSync(path.join(root,relative));
  assert.equal(bytes.length,record.bytes,`${relative} byte size`);
  assert.equal(hash(bytes),record.sha256,`${relative} sha256`);
  if(relative.endsWith('.ico')) {
    assert.equal(bytes.readUInt16LE(0),0);assert.equal(bytes.readUInt16LE(2),1);assert.equal(bytes.readUInt16LE(4),8);
    for(let i=0;i<8;i++) {
      const e=6+16*i,s=bytes[e]||256,length=bytes.readUInt32LE(e+8),start=bytes.readUInt32LE(e+12);
      assert.equal(s,sizes[i]);assert.equal(bytes[e+1]||256,sizes[i]);
      assert.equal(bytes.readUInt16LE(e+6),32);
      const png=bytes.subarray(start,start+length);
      assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
      assert.equal(png.readUInt32BE(16),s);assert.equal(png.readUInt32BE(20),s);
      assert.equal(png[25],6,'RGBA PNG frame');
      checked++;
    }
  }
}
assert.ok(!JSON.stringify(manifest).includes('C:\\Users\\'),'manifest has no host absolute paths');
console.log(`Original brand provenance and ${checked} ICO frames verified.`);
