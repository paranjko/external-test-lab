import type {TrackRenderer, Overlay} from '../../public/track';
import type {time} from '../../base/time';

type Row = {[key: string]: any};
export const participants = ['node0','node1','node2','node3','node4','node5-1','node5-2'];
export const symbols: {[kind: string]: string} = {proposal:'△', prevote:'○', precommit:'●', certificate:'✓', execution:'▣', finalizing:'◩', epoch:'⚑', power:'↕', jail:'⊠', receive:'⇥'};
for(const kind of ['proposal','prevote','precommit']) symbols[kind+'?']=symbols[kind]+'?';
export type Fact = {node: string; kind: string; height: number; round: number; target: string; ts: bigint; last: bigint; events: string[]; refs: string[]; sender?: string; detail: string};

// A presentation reduction, not new protocol evidence. Different targets,
// identities, observation kinds and rounds never collapse into one fact.
export function participantFacts(data: Row): Fact[] {
  const identity = new Map<string,string>((data.actors ?? []).filter((a: Row)=>a.kind==='consensus_identity' && participants.includes(a.participant)).map((a: Row)=>[a.id,a.participant]));
  const facts = new Map<string,Fact>();
  for (const e of data.events ?? []) {
    if (e.temporality!=='historical' || !/^\d+$/.test(e.trace_ts_ns ?? '')) continue;
    let node = '', kind = '', sender: string | undefined;
    const local = /^node[0-4]$/.test(e.observer_id) ? e.observer_id : '';
    if (e.kind==='vote.certificate') {node=identity.get(e.validator_id) ?? '';kind='certificate';}
    else if (e.kind==='validator.jailed.liveness') {node=identity.get(e.validator_id) ?? '';kind='jail';}
    else if (e.kind==='vote.received') {node=local;kind='receive';sender=identity.get(e.validator_id);}
    else if (e.kind==='signer.signed' && ['observed','inferred'].includes(e.derivation)) {node=identity.get(e.validator_id) ?? '';kind=e.phase==='PREVOTE'?'prevote':e.phase==='PRECOMMIT'?'precommit':'proposal';if(e.derivation==='inferred')kind+='?';}
    else if (e.kind==='proposal.received' || e.kind==='proposal.complete') {node=local;kind='proposal';}
    else if (e.kind==='epoch.changed') {node=local;kind='epoch';}
    else if (e.kind==='application.executed') {node=local;kind='execution';}
    else if (e.kind==='commit.finalizing') {node=local;kind='finalizing';}
    if (!node || !kind) continue;
    const round = kind==='jail' || kind==='epoch' ? -1 : e.round;
    const key=JSON.stringify([node,kind,e.kind,e.height,round,e.phase,e.block_id,e.validator_id ?? '']);
    const ts=BigInt(e.trace_ts_ns);
    let f=facts.get(key);
    if (!f) {f={node,kind,height:e.height,round,target:e.block_id,ts,last:ts,events:[],refs:[],sender,
      detail:e.kind+'; '+e.time_basis+'; '+e.derivation}; facts.set(key,f);}
    if (ts<f.ts) f.ts=ts;
    if (ts>f.last) f.last=ts;
    f.events.push(e.event_id); f.refs.push(...e.source_refs);
  }
  // Power changes only, not thousands of unchanged V(H) samples.
  const times = new Map<string,Row>();
  for (const m of data.measurements ?? []) if (m.metric==='membership.active_power' && m.trace_ts_ns!==undefined) times.set(m.height+'/'+m.target,m);
  for (const c of data.membership_changes ?? []) {
    const node=identity.get(c.validator_id), m=times.get(c.height+'/'+c.validator_id);
    if (!node || !m || c.old_power===c.new_power) continue;
    const ts=BigInt(m.trace_ts_ns);
    facts.set('power/'+c.id,{node,kind:'power',height:c.height,round:-1,target:c.validator_id,ts,last:ts,events:[],refs:c.source_refs ?? [],detail:`Power ${c.old_power ?? '?'} → ${c.new_power ?? '?'}; ${m.measurement_basis}`});
  }
  for(const f of facts.values()) {f.events=[...new Set(f.events)];f.refs=[...new Set(f.refs)];}
  return [...facts.values()].sort((a,b)=>a.ts<b.ts?-1:a.ts>b.ts?1:0);
}

export function participantTrack(facts: Fact[], select: (facts: Fact[])=>void): TrackRenderer {
  let hits: {x:number;y:number;facts:Fact[]}[]=[];
  return {
    getHeight:()=>40,
    render({ctx,timescale,size}) {
      hits=[];
      const cells=new Map<string,{x:number;y:number;facts:Fact[]}>();
      const start=timescale.timeSpan.start.toTime(), end=timescale.timeSpan.end.toTime();
      let lo=0,hi=facts.length;
      while(lo<hi) {const mid=(lo+hi)>>>1;if(facts[mid].ts<start)lo=mid+1;else hi=mid;}
      for(let i=lo;i<facts.length && facts[i].ts<=end;i++) {
        const f=facts[i];
        const x=timescale.timeToPx(f.ts as time);
        if(x<0 || x>size.width) continue;
        const row=['power','jail','epoch'].includes(f.kind)?1:0;
        const key=Math.floor(x/22)+'/'+row;
        let cell=cells.get(key);
        if(!cell) {cell={x:Math.floor(x/22)*22+11,y:row?30:13,facts:[]};cells.set(key,cell);}
        cell.facts.push(f);
      }
      ctx.save();ctx.font='17px sans-serif';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillStyle='#273e55';
      for(const cell of cells.values()) {
        const kinds=[...new Set(cell.facts.map(f=>f.kind))];
        ctx.fillText(kinds.length===1?symbols[kinds[0]]:'⊞',cell.x,cell.y);
        if(cell.facts.length>1) {ctx.font='9px sans-serif';ctx.fillText(String(cell.facts.length),cell.x+6,cell.y-10);ctx.font='17px sans-serif';}
        hits.push(cell);
      }
      ctx.restore();
    },
    onMouseClick({x,y}) {const hit=hits.find(h=>Math.abs(h.x-x)<12 && Math.abs(h.y-y)<15);if(!hit)return false;select(hit.facts);return true;},
  };
}

// A selected receipt relation, not a reconstructed send timestamp or latency.
export function receiptOverlay(selected: ()=>Fact[], facts: Fact[] = []): Overlay {
  return {render(ctx,timescale,_size,tracks) {
    const chosen=selected();
    // Undirected agreement links are distinct from message delivery.
    if(chosen.length===1 && chosen[0].kind==='certificate' && chosen[0].target && !chosen[0].target.startsWith('unknown')) {
      const target=chosen[0];
      const points=facts.filter(f=>f.kind==='certificate' && f.height===target.height && f.round===target.round && f.target===target.target).flatMap(f=>{
        const track=tracks.find(t=>t.node.uri==='gonka/participant/'+f.node);
        const x=timescale.timeToPx(f.ts as time);
        return track && x>=timescale.pxBounds.left && x<=timescale.pxBounds.right ? [{x,y:track.verticalBounds.top+13}]:[];
      }).sort((a,b)=>a.y-b.y);
      if(points.length>1) {ctx.save();ctx.strokeStyle='#637386';ctx.setLineDash([2,4]);ctx.beginPath();ctx.moveTo(points[0].x,points[0].y);for(const p of points.slice(1))ctx.lineTo(p.x,p.y);ctx.stroke();ctx.restore();}
    }
    const f=selected().find(f=>f.kind==='receive' && f.sender && f.sender!==f.node);
    if(!f) return;
    const from=tracks.find(t=>t.node.uri==='gonka/participant/'+f.sender);
    const to=tracks.find(t=>t.node.uri==='gonka/participant/'+f.node);
    if(!from || !to) return;
    const x=timescale.timeToPx(f.ts as time);
    if(x<timescale.pxBounds.left || x>timescale.pxBounds.right)return;
    const y1=from.verticalBounds.top+13,y2=to.verticalBounds.top+13;
    ctx.save();ctx.strokeStyle='#344a60';ctx.fillStyle='#344a60';ctx.lineWidth=2;
    ctx.setLineDash([4,3]);ctx.beginPath();ctx.moveTo(x,y1);ctx.lineTo(x,y2);ctx.stroke();ctx.setLineDash([]);
    const d=y2>y1?1:-1;ctx.beginPath();ctx.moveTo(x-5,y2-d*7);ctx.lineTo(x,y2);ctx.lineTo(x+5,y2-d*7);ctx.stroke();ctx.restore();
  }};
}
