#!/usr/bin/env node
// Original CodexTimeZone Soft Orbit geometry. Build-time tool only.
// node scripts/generate-brand-icons.cjs --sharp-module <installed sharp directory>
// Optional: --output-root <repo root> --preview-dir <new evidence directory>
// No install/download and no silent alternate renderer; committed PNG/ICO are runtime assets.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const options = {};
for (let i=2;i<process.argv.length;i+=2) {
  const key=process.argv[i];
  if (!['--sharp-module','--output-root','--preview-dir'].includes(key) || !process.argv[i+1]) {
    throw new Error('Usage: node scripts/generate-brand-icons.cjs --sharp-module <installed module path> [--output-root <repo>] [--preview-dir <directory>]');
  }
  options[key]=process.argv[i+1];
}
if (!options['--sharp-module']) throw new Error('Explicit --sharp-module is required; this tool never downloads a renderer.');
const sharp = require(path.resolve(options['--sharp-module']));
const root = path.resolve(options['--output-root'] || path.join(__dirname,'..'));
const source = path.join(root,'flutter_app/assets/source');
const resources = path.join(root,'flutter_app/windows/runner/resources');
const sizes = [16,20,24,32,48,64,128,256];
const palette = {navy:'#18243a',blue:'#92b7ff',cyan:'#8ce0d4',white:'#edf4ff'};
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const generated = {};
function write(relative, bytes) {
  const target = path.join(root,relative);
  fs.mkdirSync(path.dirname(target),{recursive:true});
  fs.writeFileSync(target,bytes);
  generated[relative.replaceAll('\\','/')]={sha256:hash(bytes),bytes:Buffer.byteLength(bytes)};
}
function arc(start,end) {
  return Array.from({length:161},(_,i)=>{
    const angle=(start+(end-start)*i/160)*Math.PI/180;
    return [116+69*Math.cos(angle),139+69*Math.sin(angle)];
  });
}
function svg(small,tray) {
  const ring=tray?20:small?18:15;
  const hand=tray?19:small?17:14;
  const star=small||tray?25:23;
  const inset=small?6:8;
  const coords=[[183,68-star],[190,61],[183+star,68],[190,75],
                [183,68+star],[176,75],[183-star,68],[176,61]];
  const points=list=>list.map(([x,y])=>`${x.toFixed(5)},${y.toFixed(5)}`).join(' ');
  const line=(coords,color,width)=>`<polyline points="${points(coords)}" fill="none" stroke="${color}" stroke-width="${width}" stroke-linejoin="round" stroke-linecap="round"/>`;
  return ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">',
    '<title>CodexTimeZone Soft Orbit — original clock, open orbit and star</title>',
    `<rect x="${inset}" y="${inset}" width="${256-inset*2}" height="${256-inset*2}" rx="52" fill="${palette.navy}"/>`,
    line(arc(-8,220),tray?palette.white:palette.blue,ring),
    line(arc(220,264),palette.cyan,ring),
    line([[116,139],[116,101]],palette.cyan,hand),
    line([[116,139],[145,156]],palette.white,hand),
    `<polygon points="${points(coords)}" fill="${palette.cyan}"/>`,
    '</svg>',''].join('\n');
}
function ico(images) {
  const header=Buffer.alloc(6+16*images.length);
  header.writeUInt16LE(1,2); header.writeUInt16LE(images.length,4);
  let offset=header.length;
  images.forEach((image,i)=>{
    const entry=6+16*i, size=sizes[i]===256?0:sizes[i];
    header[entry]=size; header[entry+1]=size;
    header.writeUInt16LE(1,entry+4); header.writeUInt16LE(32,entry+6);
    header.writeUInt32LE(image.length,entry+8); header.writeUInt32LE(offset,entry+12);
    offset+=image.length;
  });
  return Buffer.concat([header,...images]);
}
async function main() {
  fs.mkdirSync(source,{recursive:true}); fs.mkdirSync(resources,{recursive:true});
  const preview=options['--preview-dir'] && path.resolve(options['--preview-dir']);
  if (preview) fs.mkdirSync(preview,{recursive:true});
  for (const [family,tray] of [['app',false],['tray',true]]) {
    const master=svg(false,tray), small=svg(true,tray);
    write(`flutter_app/assets/source/soft_orbit_${family}.svg`,master);
    write(`flutter_app/assets/source/soft_orbit_${family}_small.svg`,small);
    const images=[];
    for (const size of sizes) {
      const bytes=await sharp(Buffer.from(size<=24?small:master),{density:288}).resize(size,size).png().toBuffer();
      images.push(bytes);
      if (preview) fs.writeFileSync(path.join(preview,`${family}_${size}.png`),bytes);
    }
    if (!tray) write('flutter_app/assets/app_icon.png',images[images.length-1]);
    write(`flutter_app/windows/runner/resources/${tray?'tray':'app'}_icon.ico`,ico(images));
  }
  const manifest={
    artwork:'Original CodexTimeZone Soft Orbit; clock, open orbit and four-point star',
    canonicalGenerator:'scripts/generate-brand-icons.cjs',
    canonicalGeneratorSha256:hash(fs.readFileSync(__filename)),
    rasterizer:'sharp/libvips SVG; density 288; Lanczos3 resize',
    rendererVersions:sharp.versions,
    sizes,palette,generated,
  };
  fs.writeFileSync(path.join(source,'brand-generation.json'),JSON.stringify(manifest,null,2)+'\n');
  console.log(`Generated original app/tray assets (${sizes.join(', ')}px); sharp ${sharp.versions.sharp}, libvips ${sharp.versions.vips}.`);
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
