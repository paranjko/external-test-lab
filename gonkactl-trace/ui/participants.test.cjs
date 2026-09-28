const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('typescript');
const api={};vm.runInNewContext(ts.transpileModule(fs.readFileSync(__dirname+'/net.gonka.Consensus/participants.ts','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports:api,Map,Set,BigInt});
const event=(id,overrides={})=>({event_id:id,kind:'vote.certificate',validator_id:'key',height:100,round:0,phase:'PRECOMMIT',block_id:'block',trace_ts_ns:'100',temporality:'historical',source_refs:[id],...overrides});
const data={actors:[{id:'key',kind:'consensus_identity',participant:'node5-1'}],events:[event('a'),event('b'),event('other-target',{block_id:'conflict'}),event('snapshot',{temporality:'snapshot'}),event('unmapped',{validator_id:'other'}),event('recv',{kind:'vote.received',observer_id:'node1'}),event('jail-a',{kind:'validator.jailed.liveness',round:-1}),event('jail-b',{kind:'validator.jailed.liveness',round:0})]};
const facts=api.participantFacts(data);
assert.equal(api.participants.length,7);
assert.equal(facts.length,4);
assert.equal(facts.find(f=>f.kind==='certificate'&&f.target==='block').events.length,2);
assert.equal(facts.find(f=>f.kind==='receive').node,'node1');
assert.equal(facts.find(f=>f.kind==='receive').sender,'node5-1');
assert.equal(facts.find(f=>f.kind==='jail').events.length,2);
const inferred=api.participantFacts({...data,events:[event('inferred',{kind:'signer.signed',phase:'PREVOTE',derivation:'inferred'})]});
assert.equal(inferred[0].kind,'prevote?');
let selected=[];const renderer=api.participantTrack(facts.filter(f=>f.node==='node5-1'),f=>selected=f);
const ctx={save(){},restore(){},fillText(){}};
renderer.render({ctx,size:{width:200},timescale:{timeToPx:t=>Number(t),timeSpan:{start:{toTime:()=>0n},end:{toTime:()=>200n}}}});
assert.equal(renderer.getHeight(),40);assert.equal(renderer.onMouseClick({x:99,y:13}),true);
assert.equal(selected.length,2); // two targets remain distinct within a visual cluster
assert.ok(new Set(Object.values(api.symbols)).size>=9);
const certificate=facts.find(f=>f.kind==='certificate'&&f.target==='block');
let lines=0;const overlayContext={save(){},restore(){},setLineDash(){},beginPath(){},moveTo(){},lineTo(){lines++;},stroke(){}};
api.receiptOverlay(()=>[certificate],[certificate,{...certificate,node:'node1'}]).render(overlayContext,{timeToPx:t=>Number(t),pxBounds:{left:0,right:200}}, {},[
  {node:{uri:'gonka/participant/node5-1'},verticalBounds:{top:0}},
  {node:{uri:'gonka/participant/node1'},verticalBounds:{top:40}},
]);
assert.equal(lines,1,'same-block agreement line missing');
console.log('PASS: seven lanes, evidence deduplication, conflicting targets retained, jail deduplication, receiver attribution, snapshot/unknown exclusion, semantic icons and cluster selection');
