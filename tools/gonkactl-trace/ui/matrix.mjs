import {translate,chooseLanguage} from './matrix-i18n.mjs';
import {causalEvidence,ruleCommit} from './causal.mjs';
export const participants = ['node0','node1','node2','node3','node4','node5-1','node5-2'];
export const heights = [306550,306551,306552,306553];
export const matrixHeights = data => Number.isSafeInteger(data.from)&&Number.isSafeInteger(data.to)&&data.from>0&&data.to>=data.from&&data.to-data.from<4?Array.from({length:data.to-data.from+1},(_,i)=>data.from+i):heights;
const unique = xs => [...new Set(xs)];
// These query projections contain unordered member/vote lists. Preserve raw
// pages for evidence, but do not call a changed iteration order a conflict.
const canonicalApplication = value => Array.isArray(value)?value.map(canonicalApplication).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonicalApplication(value[k])])):value;

export function buildMatrix(data) {
  const actors=data.actors??[], events=data.events??[];
  const cells=[];
  for(const node of participants) for(const height of matrixHeights(data)) {
    const identities=unique(actors.filter(a=>a.kind==='consensus_identity'&&a.participant===node).map(a=>a.id));
    const sets=(data.validator_sets??[]).filter(s=>s.height===height);
    const versions=unique(sets.map(s=>JSON.stringify([s.membership_complete,s.total,s.quorum,
      (s.validators??[]).map(v=>[v.Address,v.Power]).sort((a,b)=>a[0].localeCompare(b[0]))])));
    const set=sets[0], id=identities.length===1?identities[0]:undefined;
    const entries=(set?.validators??[]).filter(v=>v.Address===id);
    let membership='unknown',power=null;
    if(identities.length>1 || versions.length>1 || entries.length>1) membership='conflict';
    else if(id && entries.length===1) {membership='in'; power=Number.isSafeInteger(entries[0].Power)&&entries[0].Power>=0?entries[0].Power:null;}
    else if(id && set?.membership_complete) {membership='out';power=0;}
    const related=id?events.filter(e=>e.validator_id===id&&e.height===height):[];
    // Group certificate statements only. Local signer and jail records remain
    // separate; proximity or shared height does not prove event equivalence.
    const signatures=new Map();
    for(const e of related.filter(e=>e.kind==='vote.certificate'&&e.temporality==='historical')) {
      const key=JSON.stringify([e.network_id,e.height,e.round,e.phase,e.block_id,e.validator_id,
        e.block_id&&!e.block_id.startsWith('unknown')?'':e.event_id]);
      const group=signatures.get(key)??[];group.push(e);signatures.set(key,group);
    }
    cells.push({node,height,id,membership,power,sets,identities,
      certificates:[...signatures.values()],
      signing:related.filter(e=>e.kind==='signer.signed'&&e.temporality==='historical'),
      snapshots:related.filter(e=>e.temporality==='snapshot'&&e.kind==='vote.snapshot'),
      jails:id?events.filter(e=>e.validator_id===id&&e.kind==='validator.jailed.liveness'&&e.height<=height):[],
    });
  }
  return cells;
}

export function changesAt(cells,height) {
  const heights=unique(cells.map(c=>c.height)).sort((a,b)=>a-b);
  const previous=heights[heights.indexOf(height)-1];
  if(previous===undefined)return [];
  return participants.flatMap(node=>{
    const before=cells.find(c=>c.node===node&&c.height===previous), after=cells.find(c=>c.node===node&&c.height===height);
    if(before.power===null||after.power===null)return [{node,before,after,unknown:true}];
    return before.membership!==after.membership||before.power!==after.power?[{node,before,after,unknown:false}]:[];
  });
}

export function admissionEvidence(data) {
  const cells=buildMatrix({...data,from:306550,to:306553}),before=cells.find(c=>c.node==='node5-2'&&c.height===306552),after=cells.find(c=>c.node==='node5-2'&&c.height===306553);
  const id=after.id;
  const changes=(data.membership_changes??[]).filter(c=>id&&c.validator_id===id&&c.height===306553);
  const update=changes.length===1&&changes[0].update_matches&&changes[0].emitted_height===306551&&changes[0].activation_distance===2&&changes[0].new_power===after.power?changes[0]:null;
  const prior=(data.prior_identity_sets??[]).filter(s=>id&&(s.validators??[]).some(v=>v.Address===id&&v.Power>0)).sort((a,b)=>a.height-b.height)[0];
  const certificates=(data.certificates??[]).filter(c=>[306551,306552].includes(c.height));
  const oldSets=(data.validator_sets??[]).filter(s=>s.height===306551);
  const oldQuorum=oldSets.length===1&&oldSets[0].membership_complete?oldSets[0].quorum:null;
  const sufficientOld=certificates.filter(c=>c.height===306551&&id&&!c.signers.includes(id)&&Number.isSafeInteger(c.power)&&Number.isSafeInteger(oldQuorum)&&oldQuorum>0&&c.quorum===oldQuorum&&c.power>=oldQuorum);
  const set=after.sets.length===1?after.sets[0]:null;
  const known=before.membership==='out'&&after.membership==='in'&&after.power!==null&&set?.membership_complete&&Number.isSafeInteger(set.total)&&Number.isSafeInteger(set.quorum);
  return {id,before,after,changes,update,prior,certificates,sufficientOld,
    remaining:known?set.total-after.power:null,quorum:known?set.quorum:null,
    signingRecords:after.certificates.flat().length+after.signing.length};
}

export function applicationEvidence(data) {
  const report=data.application;
  if(!report)return null;
  const prefix='/productscience/inference/inference/';
  const get=(height,path)=>{
    const queries=(report.queries??[]).filter(q=>q.height===height&&q.path===path);
    const good=queries.filter(q=>q.status==='reported');
    const versions=unique(good.map(q=>JSON.stringify(canonicalApplication(q.pages))));
    const pages=versions.length===1?good[0].pages:[];
    const expected=path.endsWith('current_epoch_group_data')?'epoch_group_data':path.includes('all_poc_v2_store_commits/')?'commits':path.includes('poc_v2_validations_for_stage/')?'poc_validation':'items';
    const shape=pages.length>0&&pages.every(p=>expected==='epoch_group_data'?p.epoch_group_data&&Array.isArray(p.epoch_group_data.validation_weights):Array.isArray(p[expected]));
    return {queries,known:good.length>0&&versions.length===1&&shape,conflict:versions.length>1,pages:shape?pages:[]};
  };
  const old=get(306529,prefix+'current_epoch_group_data'),fresh=get(306549,prefix+'current_epoch_group_data');
  const group=fresh.pages?.[0]?.epoch_group_data;
  const stage=group?.poc_start_block_height,epoch=group?.epoch_index;
  const commits=get(306550,prefix+'all_poc_v2_store_commits/'+stage);
  const validations=get(306550,prefix+'poc_v2_validations_for_stage/'+stage);
  const excluded=get(306550,prefix+'excluded_participants/'+epoch);
  const addressLabel=address=>{
    const ids=unique((report.identities??[]).filter(i=>i.address===address&&i.height===306550).map(i=>i.validator));
    const labels=unique((data.actors??[]).filter(a=>ids.includes(a.id)&&a.participant).map(a=>a.participant));
    return ids.length===1&&labels.length===1?labels[0]:address;
  };
  const before=old.pages?.[0]?.epoch_group_data?.validation_weights??[];
  const after=group?.validation_weights??[];
  const allCommits=commits.pages.flatMap(p=>p.commits??[]);
  const allVotes=validations.pages.flatMap(p=>p.poc_validation??[]).flatMap(p=>p.poc_validation??[]);
  const addresses=unique([...before,...after].map(w=>w.member_address).concat(allCommits.map(c=>c.participant_address)));
  const rows=addresses.map(address=>({address,label:addressLabel(address),
    decisions:(report.decision_logs??[]).filter(l=>l.height===306548&&[l.fields.participant,l.fields.participantAddress,l.fields.addr].includes(address)),
    before:old.known?before.find(w=>w.member_address===address)?.weight??'not in group':'unknown',
    after:fresh.known?after.find(w=>w.member_address===address)?.weight??'not in group':'unknown',
    commits:commits.known?allCommits.filter(c=>c.participant_address===address).map(c=>c.count):null,
    votes:validations.known?allVotes.filter(v=>v.participant_address===address).map(v=>({validator:addressLabel(v.validator_participant_address),weight:v.validated_weight,self:v.validator_participant_address===address})):null,
  })).sort((a,b)=>a.label.localeCompare(b.label));
  return {report,old,fresh,group,commits,validations,excluded,rows,
    queries:[...old.queries,...fresh.queries,...commits.queries,...validations.queries,...excluded.queries]};
}

export async function mountMatrix(data,root,session,language='en') {
  const heights=matrixHeights(data),incident=heights.includes(306553)&&data.meta?.incident==='GNK-LAB-2026-0001';
  const cells=buildMatrix(data), observations=new Map((data.observations??[]).map(o=>[o.observation_id,o]));
  const admission=admissionEvidence(data);
  const application=incident?applicationEvidence(data):null;
  let causal=null,causalError=null;
  try{causal=await causalEvidence(data,application,admission);}catch(e){causalError=e.message;}
  let selected=cells.find(c=>c.node==='node5-2'&&c.height===heights.at(-1))??cells[0];
  let evidencePage=0;
  const t=text=>translate(text,language);
  const el=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=tag==='pre'?text:t(text);if(cls)e.className=cls;return e;};
  const append=(parent,...children)=>{children.flat().filter(Boolean).forEach(c=>parent.append(c));return parent;};
  const button=(text,fn)=>{const b=el('button',text);b.type='button';b.onclick=fn;return b;};
  const detail=(title,body)=>append(el('details'),el('summary',title),body);
  const pre=value=>el('pre',typeof value==='string'?value:JSON.stringify(value,null,2));
  const state=c=>c.membership==='in'?`In set · power ${c.power??'?'}`:c.membership==='out'?'Not in complete set':c.membership==='conflict'?'≠ Conflicting evidence':'? Membership unknown';
  const offline=!!document.getElementById('gonka-report-data');
  const timeline=height=>offline?'incident.pftrace':`/gonka/?session=${session}&view=timeline&height=${height}&lang=${language}`;
  const selector=document.getElementById('language');
  if(selector)selector.onchange=()=>{
    language=selector.value==='ru'?'ru':'en';
    try{localStorage.setItem('gonka-matrix-language',language);}catch{}
    const url=new URL(location.href);url.searchParams.set('lang',language);history.replaceState(null,'',url);
    updateChrome(language,session);render();
  };
  function observation(o) {
    return detail(`${o.observer_id} · ${o.source_kind} · collected ${o.collected_at||'unknown'}`,
      append(el('div'),el('p',`Source: ${o.source_ref||'not retained'}`),el('p',`Observation time: ${o.observed_at||'unknown'}`),
        el('p',o.excerpt?'Retained excerpt below; this viewer does not open the full original file':'No excerpt retained; original file is not opened by this viewer'),pre(o.excerpt||o.attributes||{})));
  }
  function evidence(records) {
    const wrap=el('div'), pages=Math.max(1,Math.ceil(records.length/8));
    evidencePage=Math.min(evidencePage,pages-1);
    append(wrap,el('p',`${records.length} records · page ${evidencePage+1}/${pages}`));
    if(pages>1)append(wrap,button('Previous records',()=>{evidencePage=Math.max(0,evidencePage-1);render();}),button('Next records',()=>{evidencePage=Math.min(pages-1,evidencePage+1);render();}));
    for(const e of records.slice(evidencePage*8,evidencePage*8+8)) {
      const refs=unique(e.source_refs??[]), obs=refs.map(id=>observations.get(id)).filter(Boolean);
      append(wrap,detail(`${e.kind} · H${e.height} R${e.round} · ${e.verification||'verification unknown'}`,
        append(el('div'),el('p',`Derivation: ${e.derivation} · ${e.temporality} · ${e.time_basis}`),
          el('p',`Event time: ${e.occurred_at||'unknown'} · ${refs.length} observation references, not independent confirmations`),
          pre(e),obs.map(observation),refs.length>obs.length?el('p','Some referenced observations are unavailable in this subset'):null)));
    }
    return wrap;
  }
  function render() {
    root.replaceChildren();
    const say=(ru,en)=>language==='ru'?ru:en;
    const title=el('h1',incident?'What changed at the halt boundary?':say('Состояния участников в выбранном диапазоне','Participant states in the selected range'));
    append(root,title,el('p',`H${heights[0]}–H${heights.at(-1)} · `+say('сохранённые свидетельства, не текущее состояние сети','retained evidence, not live network health'),'subtitle'));
    append(root,el('p',`${data.meta?.incident??'?'} · ${data.meta?.network_id??'?'}`,'dataset-label'));
    if(!incident)append(root,el('p',say('Показаны последние четыре высоты выбранной трассы, причинная схема GNK-LAB-2026-0001 к этому диапазону не применяется','Showing the last four heights of the selected trace; the GNK-LAB-2026-0001 causal narrative does not apply to this range')));
    if(causal) {
      const story=el('section',undefined,'causal-story');story.id='causal-story';
      append(story,el('h2',say('Как сеть потеряла кворум','How the network lost quorum')),
        el('p',say('Работающие node3 и node4 потеряли вес после проверки PoC, а node5-2 вернулся с весом, без которого новый набор не мог завершить блок','Working node3 and node4 lost their power after PoC validation, while node5-2 returned with power that the new set needed to finalize a block')));
      const flow=el('ol',undefined,'causal-flow');
      const card=(icon,title,text,proof)=>{
        const c=el('li');append(c,el('h3',icon+' '+title),el('p',text),detail(say('Почему · свидетельства и правило','Why · evidence and rule'),proof));append(flow,c);
      };
      card('↻',say('1 · Перенос прежнего веса','1 · Carry forward previous weight'),
        say('H306530 → H306548 · node1 и node5-2 сохранены для inference, их прежний вычислительный вес переносится без нового PoC','H306530 → H306548 · node1 and node5-2 are preserved for inference; their previous compute weight carries forward without a new PoC'),
        append(el('div'),pre(causal.preserved.map(r=>({participant:r.label,evidence:r.decisions.filter(l=>l.kind==='participant.preserved')}))),pre(causal.preservationLogs),
          el('p',say('Отбор preserved использует группу приложения и вычислительные веса, это не проверка доступности consensus-подписанта','Preservation uses application membership and compute weights, not a consensus-signer availability check'))));
      const votes=el('div');
      for(const r of causal.rows) {
        const line=el('p',undefined,'vote-line');
        append(line,el('strong',r.label+' ← '));
        for(const p of r.peers)append(line,el('span',(p.vote==='yes'?'✓ ':p.vote==='no'?'✕ ':'? ')+p.label+' · '+say(p.vote==='yes'?'подтвердил':p.vote==='no'?'отклонил':p.vote==='conflict'?'ответы противоречат друг другу':'нет подтверждения',p.vote==='yes'?'approved':p.vote==='no'?'rejected':p.vote==='conflict'?'conflicting reports':'no approval'),p.vote==='yes'?'vote-yes':'vote-missing'));
        append(line,el('strong',` → ${r.positive}/${r.slots} · `+say(r.passed?'порог пройден':'порог не пройден',r.passed?'threshold passed':'threshold not passed')));append(votes,line);
        for(const p of r.peers.filter(p=>p.explanation)) {
          const why=p.explanation,body=el('div');
          append(body,el('p',say(`Факт: в сохранённом полном ответе PoC v2 нет проверки от ${p.label} для ${r.label} и модели ${r.model}, это не отрицательный голос`,`Fact: the retained complete PoC v2 response contains no validation by ${p.label} for ${r.label} and model ${r.model}; this is not a negative vote`)));
          append(body,el('p',why.status==='zero_workers'?say('Наблюдение API: при попытках проверки после фильтрации оставалось 0 ML-нод, выполнить проверку было некому','API observation: validation attempts retained 0 ML nodes after filtering; no worker was available'):why.status==='mixed_workers'?say('В журнале есть попытки и с нулём, и с доступными ML-нодами, одной нехваткой работников результат не объясняется','Logs include attempts with both zero and available ML nodes; worker shortage alone does not explain the result'):say('Причина на стороне API не установлена: в этом наборе нет привязанной к проверяющему записи, объясняющей отсутствие результата','The API-side cause is not established: this bundle contains no peer-bound record explaining the missing result')));
          if(why.preserved.length)append(body,el('p',say('Возможное объяснение по правилу: участник помечен preserved, а filterNodesForValidation исключает preserved ML-ноды, строка журнала о срабатывании именно этого фильтра не сохранена','Rule-based explanation: the participant is marked preserved and filterNodesForValidation excludes preserved ML nodes; no retained log line proves that this particular filter fired')));
          if(why.laterContainer)append(body,el('p',say('Доступный API-контейнер создан после конца исторического окна, его логи не объясняют действия проверяющего в этом PoC','The available API container was created after the historical window; its logs do not explain this peer’s behavior during that PoC')));
          if(!why.identityBound)append(body,el('p',say('node5 – имя сервера, связь его текущего API-процесса с историческим ключом проверяющего не доказана','node5 is a host label; its current API process has not been bound to the historical validator identity')));
          append(body,el('p',say('Для уточнения нужны API-логи проверяющего за H306544–H306547 с составом ML-нод и причиной их исключения, утрата consensus-ключа сама по себе не объясняет отсутствие PoC-транзакции','To resolve this, retain the peer’s API logs for H306544–H306547, ML-node inventory and filter reasons; loss of a consensus key alone does not explain a missing PoC transaction')),
            detail(say('Исходные ответы и журналы','Source responses and logs'),pre({validation_queries:application.validations.queries,...why})));
          const explanation=detail(p.label+' → '+r.label+' · '+say('Почему нет подтверждения?','Why no approval?'),body);explanation.className='missing-approval';append(votes,explanation);
        }
      }
      card('✓',say('2 · PoC выполнен, но подтверждений недостаточно','2 · PoC submitted, approvals insufficient'),
        say(`H306544–H306548 · Нужно строго больше ${causal.threshold/100}% из ${causal.slots} слотов, собственное подтверждение не заменяет недостающее`,`H306544–H306548 · Strictly more than ${causal.threshold/100}% of ${causal.slots} slots are required; self-approval does not replace a missing approval`),
        append(el('div'),pre(causal.snapshot),pre(causal.params),el('p',say('Назначения ниже пересчитаны из app hash и весов snapshot, а не подобраны по имеющимся голосам','Assignments below are replayed from the snapshot app hash and weights, not guessed from existing votes'))));
      // The peer relationships are the main explanation, not hidden raw evidence.
      append(flow.lastElementChild,votes);
      card('⊘',say('3 · Назначенный проверяющий не получил ML-работника','3 · Assigned validator had no ML worker'),
        causal.workerLogs.some(l=>l.fields.numNodes==='0')?
          say('node1 · API запустил проверку, но после фильтрации получил 0 ML-нод, подтверждение для node3 не появилось до расчёта','node1 · API started validation but retained 0 ML nodes after filtering; node3 had no approval from node1 before calculation'):
          say('В этом наборе нет журнала API, позволяющего объяснить недостающее подтверждение node1','This dataset has no API log explaining the missing node1 approval'),
        append(el('div'),pre(causal.workerLogs),el('p',say('Правило API исключает preserved-ноды из PoC validation, тогда как snapshot расчёта слотов содержит веса node1 и node5-2, это несогласованность между отбором проверяющего и доступностью его ML-работника','The API excludes preserved nodes from PoC validation, while the slot snapshot contains node1 and node5-2 weights: validator selection and ML-worker eligibility disagree')),
          el('p',say('Это объяснение по правилу, а не сохранённая запись конкретной ветки фильтра, для каждого отсутствующего подтверждения ограничения и доступные источники показаны выше','This is a rule-based explanation, not a retained record of a particular filter branch; each missing approval has its own limitations and sources above'))));
      card('−',say('4 · Новый расчёт исключает node3 и node4','4 · Calculation excludes node3 and node4'),
        say('H306548 · node0 проходит PoC, node1 и node5-2 проходят по переносу веса, node3 и node4 не проходят ни по одной из этих веток','H306548 · node0 passes PoC; node1 and node5-2 enter through preservation; node3 and node4 enter through neither route'),
        pre(application.rows.map(r=>({participant:r.label,old:r.before,new:r.after,decision:r.decisions}))));
      card('↥',say('5 · Повторное назначение снимает jail','5 · Reassignment clears jail'),
        causal.unjailed?say('node5-2 · Историческое состояние меняется с jailed=true на jailed=false и вес 54, обновление веса в форке SDK явно снимает jail','node5-2 · Historical state changes from jailed=true to jailed=false with power 54; the SDK fork explicitly clears jail when updating power'):
          say('Для сравнения jail недостаточно согласованных исторических ответов','Consistent historical responses are insufficient to compare jail status'),
        append(el('div'),pre(causal.staking),el('p',say('Gonka Cosmos SDK v0.53.3-ps19-observability · x/staking/keeper/compute.go · updateValidator: validator.Jailed = false','Gonka Cosmos SDK v0.53.3-ps19-observability · x/staking/keeper/compute.go · updateValidator: validator.Jailed = false'))));
      card('■',say('6 · Новый набор теряет возможность завершить блок','6 · The new set cannot finalize a block'),
        say(`H306551 → H306553 · Старый набор принимает обновление, после его применения без node5-2 остаётся ${causal.remaining??'?'} при кворуме ${causal.quorum??'?'}`,`H306551 → H306553 · The old set accepts the update; after activation, power without node5-2 is ${causal.remaining??'?'} against quorum ${causal.quorum??'?'}`),
        append(el('div'),pre(admission.changes),pre(admission.certificates),el('p',say('Для трёх участников код допускает концентрацию до 40%, ограничение веса не гарантирует кворум при недоступности одного из них','For three participants the code allows up to 40% concentration; the power cap does not guarantee quorum with one unavailable participant'))));
      append(story,flow);
      if(Number.isSafeInteger(causal.remaining)&&Number.isSafeInteger(causal.quorum)&&admission.after.sets.length===1) {
        const total=admission.after.sets[0].total,bar=el('div',undefined,'quorum-bar');
        const available=el('div',say(`Остальные: максимум ${causal.remaining}`,`Others: at most ${causal.remaining}`),'quorum-available');available.style.width=`${100*causal.remaining/total}%`;
        const missing=el('div',`node5-2: ${total-causal.remaining}`,'quorum-missing');missing.style.width=`${100*(total-causal.remaining)/total}%`;
        const threshold=el('span',say(`Кворум ${causal.quorum}`,`Quorum ${causal.quorum}`),'quorum-marker');threshold.style.left=`${100*causal.quorum/total}%`;
        append(bar,available,missing,threshold);append(story,el('h3',say('Вес после обновления · не число серверов','Power after activation · not server count')),bar,
          el('p',say('Расчёт условный: если node5-2 не подписывает, даже подписи всех остальных недостаточно','Conditional calculation: if node5-2 does not sign, even all other signatures are insufficient')));
      }
      append(story,detail(say('Границы расследования','Investigation boundaries'),append(el('div'),
        el('p',say('Пересчёт слотов использует код версии, сообщённой текущим бинарником, криптографическая привязка исторического бинарника ещё не выполнена','Slot replay uses the revision reported by the current binary; the historical binary has not been cryptographically bound')),
        el('p',say('Утрата consensus-ключа не доказывается отсутствием голосов, это отдельный вопрос к JOIN-артефактам и архивам, он не меняет показанный расчёт кворума','Missing votes do not prove consensus-key loss; JOIN artifacts and backups are a separate investigation, which does not change the quorum arithmetic')),
        pre({rule_commit:ruleCommit,slot_rule:'calculations/slots.go',validation_rule:'module/chainvalidation.go',worker_rule:'decentralized-api/poc/validator.go',cap_rule:'keeper/bitcoin_rewards.go'}))));
      append(root,story);
    } else if(causalError)append(root,el('p',say('Пересчёт причинной цепочки не выполнен: ','Causal replay failed: ')+causalError,'uncertain'));
    const changes=changesAt(cells,selected.height);
    const summary=el('section',undefined,'summary');
    append(summary,el('h2',selected.height===heights[0]?`Baseline H${selected.height}`:`H${selected.height-1} → H${selected.height}`),
      el('p',selected.height===heights[0]?'First height in this prototype; the preceding state is not included':changes.length?changes.map(c=>c.unknown?`${c.node}: comparison unknown`:`${c.node}: ${c.before.membership==='out'?'out':c.before.power} → ${c.after.membership==='out'?'out':c.after.power}`).join(' · '):'No membership or power change in the retained sets at this transition; this says nothing about signing availability'));
    append(root,summary);
    if(application) {
      const app=el('section',undefined,'summary');app.id='application-sequence';
      append(app,el('h2','Application sequence before the validator update'),
        el('p','Historical application state collected later from REST; matching replies are corroborating reports, not independently verified state proofs'));
      const sequence=el('ol');
      append(sequence,
        el('li',application.old.known?'H306529 · The previous application group is retained below; its weights are not the same thing as the live consensus set.':'H306529 · Previous application group is missing or conflicting.'),
        el('li',application.commits.known?`PoC stage ${application.group?.poc_start_block_height} · Retained v2 commitments and validation reports are compared below. A commitment is not successful admission.`:'PoC v2 input is missing or conflicting; no absence-of-participation conclusion is available.'),
        el('li',application.fresh.known?`By H306549 · Application group ${application.group?.epoch_group_id}, epoch ${application.group?.epoch_index}, reports total weight ${application.group?.total_weight}. The participant comparison shows who is no longer in this group.`:'H306549 · New application group is missing or conflicting.'),
        el('li','H306551 → H306553 · The application update becomes effective in consensus; exact emitted changes are listed below. The group decision precedes this activation.'),
        el('li',admission.remaining!==null?`After activation · Other members have at most ${admission.remaining} voting power against quorum ${admission.quorum}, conditional on node5-2 not signing.`:'After activation · Quorum arithmetic remains unavailable.'));
      append(app,sequence);
      const comparison=el('table'),header=el('tr');
      for(const label of ['Participant','Previous group weight','New group weight','PoC v2 commit counts','Validation reports','Application decision at H306548'])append(header,el('th',label));
      append(comparison,append(el('thead'),header));const rows=el('tbody');
      for(const r of application.rows) {
        const tr=el('tr');append(tr,el('th',r.label),el('td',String(r.before)),el('td',String(r.after)),
          el('td',r.commits===null?'unknown':r.commits.length?r.commits.join(', '):'no retained v2 commit'),
          el('td',r.votes===null?'unknown':r.votes.length?r.votes.map(v=>`${v.validator}${v.self?' (self)':''}: ${v.weight}`).join('; '):'no retained v2 validation'),
          append(el('td'),...unique(r.decisions.map(l=>l.kind==='poc.rejected_no_majority'?'Rejected: no majority; inspect guardian counts':l.kind==='poc.accepted_majority'?`Accepted: ${l.fields.validSlots}/${l.fields.totalSlots} valid slots`:l.kind==='participant.preserved'?`Preserved from previous epoch: ${l.fields.preservedWeight}`:l.kind==='weight.pipeline'?`Weight pipeline: ${l.fields.before_collateral} → ${l.fields.final}`:l.kind==='participant.poc'?`PoC contribution: ${l.fields.pocWeight}`:l.kind)).map(s=>el('p',s)),r.decisions.length?detail('Decision log evidence',pre(r.decisions)):el('p','No decision log in this selection')));
        append(rows,tr);
      }
      append(comparison,rows);append(app,comparison,
        el('p','Decision logs report rejection for lack of majority and preserved-participant reuse; this is more specific than a validator update. They do not prove why the missing PoC validations were not submitted, or independently reproduce the historical algorithm. Commit counts are not final voting power. Empty excluded_participants does not prove eligibility.','uncertain'),
        detail('Application receipts behind this comparison',append(el('div'),application.queries.map(q=>detail(`${q.node} · H${q.height} · ${q.path} · ${q.status}`,pre(q))))),
        detail('All application queries, gaps and parameters',append(el('div'),pre(application.report.limits),application.report.queries.map(q=>detail(`${q.node} · H${q.height} · ${q.path} · ${q.status}`,pre(q))))));
      append(root,detail(say('Подробное сравнение групп, PoC и исходных ответов','Detailed groups, PoC and source responses'),app));
    }
    if(incident) {
    const emitted=(data.membership_changes??[]).filter(c=>c.emitted_height===306551&&c.height===306553);
    append(root,detail('H306551 explicitly removes weights before H306553 activation',append(el('div'),
      el('p','Zero is an explicit removal in the emitted update, not an inference from missing signatures. Application selection inputs are shown above when available.'),
      emitted.map(c=>{const actor=(data.actors??[]).find(a=>a.id===c.validator_id);return detail(`${actor?.participant||c.validator_id}: ${c.old_power??'?'} → ${c.new_power??'?'} · update match ${c.update_matches}`,pre(c));}))));
    const why=el('section',undefined,'summary');why.id='admission-explanation';
    append(why,el('h2','How could node5-2 enter the validator set without signing?'),
      el('p','Being assigned voting power and producing a consensus signature are separate steps. The existing validator set finalizes a block; the application returns a public key and power update. The incoming validator does not need to co-sign its own activation as a member of the old set.'),
      el('p',admission.prior?`Earlier history: this identity already appears with positive power at retained H${admission.prior.height}. ${admission.before.membership==='out'&&admission.after.membership==='in'?'H306553 is a return to the active set, not its initial JOIN or registration.':'Re-entry at this boundary is not established by the selected sets.'}`:'Earlier membership is not established by this subset; this boundary must not be called the initial JOIN.'),
      el('ol'));
    const steps=why.querySelector('ol');
    append(steps,el('li',admission.update?`H306551 · The retained application update assigns node5-2 power ${admission.update.new_power}; its activation is matched to H306553.`:'H306551 · A matching activation update is not established in this subset.'),
      el('li',admission.sufficientOld.length?'Old-set decision · A retained H306551 certificate reaches the old quorum without node5-2. No new-validator signature is needed to finalize that block.':'Old-set decision · Sufficient certificate evidence without node5-2 is not established here.'),
      el('li',`H306553 · ${state(admission.after)}. This is an assignment of voting power, not proof that its signer is working.`),
      el('li',admission.remaining!==null?`After activation · Even if every other member signs, their combined power is ${admission.remaining}; quorum is ${admission.quorum}. ${admission.remaining<admission.quorum?'They cannot commit a block without additional signing power.':'This arithmetic alone does not establish a quorum failure.'}`:'After activation · Complete membership arithmetic is unavailable.'));
    append(why,el('p',admission.signingRecords?`The selected height contains ${admission.signingRecords} historical signing records for this identity; inspect their verification and derivation.`:'No historical signing record for this identity is retained at H306553. This does not prove that the key never signed, or that no registration transaction was signed.'),
      detail('Evidence for this explanation',append(el('div'),
        detail('Earlier retained set, not registration time',pre(admission.prior??'Not available')),
        detail('Application update → effective membership, with source references',pre(admission.changes)),
        detail('Old-set certificate variants and observations',append(el('div'),...admission.certificates.map(c=>detail(`H${c.height} · power ${c.power} / quorum ${c.quorum} · ${c.verification}`,append(el('div'),pre(c),(c.source_refs??[]).map(id=>observations.get(id)).filter(Boolean).map(observation)))))),
        detail('Before and after validator sets',pre([...admission.before.sets,...admission.after.sets])))),
      el('p','Still open: why Gonka assigned this identity positive weight again after the recorded jail, which registration/eligibility checks applied, and whether the intended signer key was available. This view does not reconstruct that application decision or prove key loss.','uncertain'));
    const spec=el('a','Protocol reference: CometBFT v0.38.21 · FinalizeBlock and ValidatorUpdate');
    spec.href='https://github.com/cometbft/cometbft/blob/v0.38.21/spec/abci/abci%2B%2B_methods.md#finalizeblock';spec.target='_blank';spec.rel='noopener noreferrer';
    append(why,el('p','Protocol context: ABCI updates carry a public key and voting power, not the incoming validator’s consensus signature; an update from H takes effect at H+2. This describes activation, not Gonka’s registration or proof-of-possession rules.'),spec);
    append(root,detail('Why could node5-2 enter without signing? · activation is not signer readiness',why));
    }
    const layout=el('div',undefined,'layout'), main=el('section'), panel=el('aside');
    const table=el('table');table.setAttribute('aria-label',t('Participant state by height'));
    const head=el('tr');append(head,el('th','Identity'));
    for(const h of heights) {
      const set=(data.validator_sets??[]).filter(s=>s.height===h);
      const th=el('th');th.scope='col';append(th,el('div',`H${h}`),el('small',set.length===1?`Total ${set[0].total??'?'} · quorum ${set[0].quorum??'?'}`:'Set missing or multiple versions'));
      if((data.events??[]).some(e=>e.height===h&&e.kind==='epoch.changed'&&e.temporality==='historical'))append(th,el('small','Epoch-change records'));
      append(head,th);
    }
    append(table,append(el('thead'),head));
    const body=el('tbody');
    for(const node of participants) {
      const row=el('tr'),rowHeader=el('th',node);rowHeader.scope='row';append(row,rowHeader);
      for(const h of heights) {
        const c=cells.find(c=>c.node===node&&c.height===h),cell=el('td');
        const b=button(state(c),()=>{selected=c;evidencePage=0;render();});
        b.className='cell '+(c.membership==='out'?'absent':'');b.setAttribute('aria-label',`${node} H${h}: ${t(state(c))}`);b.setAttribute('aria-pressed',String(c===selected));
        append(b,el('small',c.certificates.length?`Certificate evidence: ${c.certificates.length} statement${c.certificates.length===1?'':'s'}`:c.signing.length?`Signer records: ${c.signing.length}`:'No historical signing record in selection'));
        if(c.jails.length)append(b,el('small','Earlier jail records · current status unknown','uncertain'));
        append(cell,b);append(row,cell);
      }
      append(body,row);
    }
    append(table,body);append(main,table,el('p','“Not in complete set” concerns this consensus identity at this height, not whether a machine was running. No signing record does not prove inactivity.','note'));
    append(panel,el('h2',`${selected.node} · H${selected.height}`),el('p',state(selected),'state'),
      el('p','Membership from retained V(H); no independent verification is performed by this screen'),
      detail('Identity attribution',pre((data.actors??[]).filter(a=>selected.identities.includes(a.id)))),
      detail('Validator set and its source references',pre(selected.sets)),
      el('h3','Historical signing evidence'),
      el('p',`${selected.certificates.length} certificate statements · ${selected.signing.length} local signer records`),
      el('p','Grouping preserves network, height, round, phase, block and identity; records remain below. Statement count is not confidence, quorum or proof of delivery'),
      evidence([...selected.certificates.flat(),...selected.signing]));
    append(panel,detail(`Earlier jail records (${selected.jails.length}) · duration not established`,append(el('div'),
      el('p','Separate records, not a count of distinct jail episodes. Current jail status and its effect on membership are not inferred'),
      selected.jails.map(e=>detail(`H${e.height} · ${e.time_basis}`,append(el('div'),pre(e),(e.source_refs??[]).map(id=>observations.get(id)).filter(Boolean).map(observation)))))));
    const link=el('a',offline?say('Скачать трейс для Perfetto','Download trace for Perfetto'):'Inspect this height in Perfetto');link.href=timeline(selected.height);if(offline)link.download='incident.pftrace';append(panel,link);
    append(layout,main,panel);append(root,layout);
    const snapshots=(data.events??[]).filter(e=>e.temporality==='snapshot'&&e.height===selected.height);
    append(root,detail(`Separate snapshot evidence at H${selected.height} (${snapshots.length} records)`,append(el('div'),
      el('p','Historical subject, separate collection time. These records are not historical message delivery or continuation of the timeline'),
      snapshots.map(e=>detail(`${e.kind} · observer ${e.observer_id} · ${e.verification}`,append(el('div'),pre(e),(e.source_refs??[]).map(id=>observations.get(id)).filter(Boolean).map(observation)))))));
    append(root,detail('Coverage, attribution and open questions',append(el('div'),
      el('p','This prototype covers four heights, plus earlier retained jail records. It does not establish the earliest node2 participation, reset timing, or post-halt synchronization'),
      pre(data.findings??[]),pre(data.coverage??[]),pre(data.application?.limits??[]),pre(data.application?.queries?.filter(q=>q.status!=='reported')??[]))));
  }
  render();
}

function updateChrome(language,session) {
  document.documentElement.lang=language;
  document.title=translate('Gonka · state matrix prototype',language);
  document.getElementById('brand').textContent=translate('Gonka · incident investigation · prototype',language);
  const link=document.getElementById('timeline');link.textContent=translate('Open detailed timeline in Perfetto',language);link.href=`/gonka/?session=${session}&view=timeline&lang=${language}`;
  if(document.getElementById('gonka-report-data')){link.textContent=language==='ru'?'Скачать трейс для Perfetto':'Download trace for Perfetto';link.href='incident.pftrace';link.download='incident.pftrace';}
  document.getElementById('language').value=language;
}

if(typeof document!=='undefined') {
  const root=document.getElementById('matrix');
  if(root) {
    const embedded=document.getElementById('gonka-report-data');
    const saved=embedded?JSON.parse(embedded.textContent):null;
    const session=saved?.meta?.fingerprint??new URLSearchParams(location.search).get('session');
    let stored;try{stored=localStorage.getItem('gonka-matrix-language');}catch{}
    const language=chooseLanguage(location.search,stored,navigator.language);
    updateChrome(language,session);
    root.textContent=translate('Loading four-height state comparison…',language);
    if(!/^[a-f0-9]{24}$/.test(session??''))root.textContent=translate('Invalid session',language);
    else {
      (saved?Promise.resolve(saved):fetch(`/api/session/${session}/matrix`).then(r=>{if(!r.ok)throw Error(`HTTP ${r.status}`);return r.json();})).then(data=>{
        if(data.meta.fingerprint!==session)throw Error('Dataset mismatch');
        return mountMatrix(data,root,session,language);
      }).catch(e=>{root.textContent=translate(`Matrix unavailable: ${e.message}`,language);});
    }
  }
}
