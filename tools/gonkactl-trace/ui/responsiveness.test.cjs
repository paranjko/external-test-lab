// Exercise the actual TypeScript controller without a browser or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(__dirname+'/net.gonka.Consensus/index.ts','utf8');
const compiled = ts.transpileModule(source, {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText;
const m = (tag, ...children) => ({tag,children});
m.redraw = () => {};
const exportsObject = {};
vm.runInNewContext(compiled, {exports:exportsObject,require(name) {
  if(name==='mithril') return m;
  if(name.endsWith('/time')) return {Time:{fromRaw:x=>x}};
  if(name.endsWith('/high_precision_time_span')) return {HighPrecisionTimeSpan:{fromTime:(start,end)=>({start,end})}};
  return {};
},setTimeout:()=>1,clearTimeout:()=>{},Map,Set,BigInt,URL,console});
const Plugin = exportsObject.default;
const p = new Plugin();
p.state = {height:306553,preset:'overview',round:0,viewport_ns:['0','1041568414009975']};
p.data = {meta:{from:131833,to:306552,focus_height:306553,end_ns:'1041568414009975'},
  events:Array.from({length:30000},(_,i)=>({event_id:'event'+i,height:131833+i,trace_ts_ns:String(BigInt(i)*5000000000n)})),
  observations:Array.from({length:35000},(_,i)=>({event_id:'event'+(i%30000),source_ref:'source'+i})),
  round_summaries:[],certificates:[],coverage:Array.from({length:1815},(_,i)=>'note'+i)};
p.heights=Array.from({length:7000},(_,i)=>131833+i);
p.eventByID=new Map(p.data.events.map(e=>[e.event_id,e]));
p.selectRange('incident');
assert.equal(BigInt(p.state.viewport_ns[1])-BigInt(p.state.viewport_ns[0]),600000000000n);
assert.equal(p.state.height,306553);
p.selectRange('node2');
assert.deepEqual(Array.from(p.state.viewport_ns),['0','696000000000']);
assert.equal(p.state.height,131833);
p.selectRange('all');
assert.equal(p.state.viewport_ns[0],'0');
p.selectRange('incident');
const saved=JSON.stringify(p.state.viewport_ns);
p.selectRange('saved');
assert.equal(JSON.stringify(p.state.viewport_ns),saved);
let linearLookups=0;
p.data.events.find=()=>{linearLookups++;throw Error('Quadratic event lookup');};
p.evidence();
p.search='event29999';
p.evidence();
assert.equal(linearLookups,0);
function countTag(tree,tag) {
  if(!tree || typeof tree!=='object') return 0;
  return (tree.tag===tag?1:0)+Object.values(tree).reduce((n,v)=>n+countTag(v,tag),0);
}
assert.ok(countTag(p.controls(),'option')<10,'height control expanded thousands of options');
assert.equal(countTag(p.coverage(),'li'),50);
p.coveragePage=36;
assert.equal(countTag(p.coverage(),'li'),15);
console.log('PASS: safe default range, early epochs, explicit full/saved range, indexed evidence, bounded height controls and coverage');
