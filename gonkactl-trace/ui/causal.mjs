// A replay of the pinned Gonka slot rule, not a heuristic assignment of peers.
// Original: inference-chain/x/inference/calculations/slots.go at this commit.
export const ruleCommit='4d687ed6782bcea3931d2d9135bf322f84e190ab';
const canonical=v=>Array.isArray(v)?v.map(canonical).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;
export function consistentQuery(report,height,path) {
 const queries=(report?.queries??[]).filter(q=>q.height===height&&q.path===path&&q.status==='reported');
 const versions=new Set(queries.map(q=>JSON.stringify(canonical(q.pages))));
 return versions.size===1?{pages:queries[0].pages,queries}:null;
}
export async function replaySlots(snapshot,participant,model,slots) {
 const entries=(snapshot.model_voting_powers??[]).find(m=>m.model_id===model)?.voting_powers;
 if(!entries||!Number.isInteger(slots)||slots<1||slots>1000)throw Error('Invalid slot inputs');
 const sorted=entries.filter(e=>BigInt(e.voting_power)>0n).sort((a,b)=>a.address<b.address?-1:a.address>b.address?1:0);
 const total=sorted.reduce((s,e)=>s+BigInt(e.voting_power),0n),network=BigInt(snapshot.total_network_weight);
 if(total<=0n||network<=0n)throw Error('Invalid snapshot weight');
 const count=total>=network?slots:Number(total*BigInt(slots)/network),result=[];
 for(let i=0;i<count;i++) {
  const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(`${snapshot.app_hash}${participant}${model}${i}`));
  let r=new DataView(hash).getBigUint64(0,false)%total;
  for(const entry of sorted){if(r<BigInt(entry.voting_power)){result.push(entry.address);break;}r-=BigInt(entry.voting_power);}
 }
 return result;
}

// A missing chain record is not a runtime diagnosis. Attach only observations
// for this assigned peer, this validation interval and this preservation row.
export function missingApprovalEvidence(report, peer, rows, from, to) {
 const logs=(report.decision_logs??[]).filter(l=>l.node===peer.label&&l.height>=from&&l.height<to&&['poc.worker_filter','poc.no_workers'].includes(l.kind));
 const zero=logs.some(l=>l.kind==='poc.worker_filter'&&l.fields.numNodes==='0');
 const positive=logs.some(l=>l.kind==='poc.worker_filter'&&Number(l.fields.numNodes)>0);
 const preserved=(rows.find(r=>r.address===peer.address)?.decisions??[]).filter(l=>l.kind==='participant.preserved');
 // node5 is a host stream, not a proven binding to node5-1 or node5-2.
 const host=peer.label.replace(/-\d+$/,'');
 const sources=(report.log_sources??[]).filter(s=>s.node===host&&s.component==='api');
 return {status:zero?(positive?'mixed_workers':'zero_workers'):'unexplained',logs,preserved,sources,
  laterContainer:sources.some(s=>s.process?.created&&s.window_end&&Date.parse(s.process.created)>Date.parse(s.window_end)),
  identityBound:host===peer.label};
}
export async function causalEvidence(data,application,admission) {
 if(!application?.fresh.known||!application?.validations.known)return null;
 const prefix='/productscience/inference/inference/',report=application.report;
 const snapshotQuery=consistentQuery(report,306544,prefix+'poc_validation_snapshot/306530');
 const paramsQuery=consistentQuery(report,306549,prefix+'params');
 const snapshot=snapshotQuery?.pages?.[0]?.snapshot,params=paramsQuery?.pages?.[0]?.params?.poc_params;
 if(!snapshotQuery?.pages?.[0]?.found||!snapshot||String(snapshot.poc_stage_start_height)!=='306530'||!params?.poc_v2_enabled)return null;
 const label=a=>application.rows.find(r=>r.address===a)?.label??a;
 const validations=application.validations.pages.flatMap(p=>p.poc_validation??[]).flatMap(p=>p.poc_validation??[]);
 const slots=Number(params.validation_slots),threshold=Number(params.validation_vote_threshold_bps);
 if(!Number.isInteger(threshold)||threshold<=0||threshold>10000)return null;
 const rows=[];
 for(const row of application.rows.filter(r=>r.commits?.length)) {
  const commits=application.commits.pages.flatMap(p=>p.commits??[]).filter(c=>c.participant_address===row.address);
  for(const model of [...new Set(commits.map(c=>c.model_id))]) {
   const assigned=await replaySlots(snapshot,row.address,model,slots);
   const votes=validations.filter(v=>v.participant_address===row.address&&v.model_id===model);
   const peers=assigned.map(a=>{const matches=votes.filter(v=>v.validator_participant_address===a);const weights=[...new Set(matches.map(v=>String(v.validated_weight)))];const peer={label:label(a),address:a,vote:weights.length===1?(BigInt(weights[0])>0n?'yes':'no'):weights.length>1?'conflict':'missing'};if(peer.vote==='missing')peer.explanation=missingApprovalEvidence(report,peer,application.rows,306544,306548);return peer;});
   const positive=peers.filter(p=>p.vote==='yes').length;
   rows.push({label:row.label,model,peers,positive,slots,threshold,passed:positive*10000>slots*threshold});
  }
 }
 const staking=[];
 for(const h of [306529,306550]) {
  const query=consistentQuery(report,h,'/cosmos/staking/v1beta1/validators');
  if(!query)continue;
  for(const v of query.pages.flatMap(p=>p.validators??[])) {
   if(!v.consensus_pubkey?.key)continue;
   const raw=Uint8Array.from(atob(v.consensus_pubkey.key),c=>c.charCodeAt(0));
   const hash=await crypto.subtle.digest('SHA-256',raw);
   const id=Array.from(new Uint8Array(hash).slice(0,20),b=>b.toString(16).padStart(2,'0')).join('').toUpperCase();
   if(id===admission.id)staking.push({height:h,jailed:v.jailed,power:v.tokens,sources:query.queries});
  }
 }
 return {rows,slots,threshold,snapshot: snapshotQuery,params:paramsQuery,staking,
  unjailed:staking.some(s=>s.height===306529&&s.jailed===true)&&staking.some(s=>s.height===306550&&s.jailed===false),
  workerLogs:(report.decision_logs??[]).filter(l=>l.kind==='poc.worker_filter'&&l.node==='node1'&&l.height>=306544&&l.height<306548),
  preservationLogs:(report.decision_logs??[]).filter(l=>l.kind.startsWith('preservation.')),
  preserved:application.rows.filter(r=>r.decisions.some(l=>l.kind==='participant.preserved')),
  remaining:admission.remaining,quorum:admission.quorum};
}
