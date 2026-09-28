const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const code = ts.transpileModule(fs.readFileSync(__dirname+'/net.gonka.Consensus/epoch_bands.ts','utf8'), {
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS},
}).outputText;
const api={}; vm.runInNewContext(code,{exports:api,Map,BigInt});
const event=(kind,height,t,temporality='historical')=>({kind,height,trace_ts_ns:String(t),temporality});
const bands=api.epochBands([
  event('epoch.changed',20,12),event('epoch.changed',20,13),
  event('header.timestamp',20,10),event('epoch.changed',90,22),
  event('header.timestamp',90,20),event('epoch.changed',300,40),
  event('header.timestamp',302,45),event('epoch.changed',370,999,'snapshot'),
]);
assert.equal(bands.length,2);
assert.equal(bands[0].start,10n); assert.equal(bands[0].end,20n);
assert.equal(bands[1].end,45n); assert.equal(bands[1].partial,true);
assert.equal(api.epochBands([event('epoch.changed',20,10)]).length,0);
const rects=[];
const ctx={save(){},restore(){},beginPath(){},rect(){},clip(){},fillRect(...r){rects.push(r)},measureText(){return {width:50}},fillText(){}};
api.epochOverlay(bands).render(ctx,{timeToPx:t=>Number(t)-10,pxBounds:{left:5,right:20}},{width:20,height:100});
assert.ok(rects.every(([x,y,w])=>x>=5 && w>=0 && x+w<=20));
console.log('PASS: epoch deduplication, header anchors, source gaps, snapshot exclusion, partial tail and viewport clipping');
