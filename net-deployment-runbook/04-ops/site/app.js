const cfg=window.GDC_CONFIG;
const gatewayStatus=window.GDC_GATEWAY_STATE;
const $=id=>document.getElementById(id);
const chainRpcHost=cfg.nodes.find(node=>node.name===cfg.gatewayNode)?.publicHost||cfg.nodes[0]?.publicHost;
$('chain-id').textContent=cfg.chainId;$('model-id').textContent=cfg.model;
if(cfg.telegramBot){$('contact').textContent='Open Telegram bot';$('contact').href=cfg.telegramBot}else{$('contact').textContent='Telegram bot is not configured yet';$('contact').removeAttribute('href')}
$('grafana-network').href=cfg.grafanaNetwork||cfg.grafana;
$('grafana-inference').href=cfg.grafanaInference;
const cards=new Map();
let observedNodes=cfg.nodes.map(node=>({...node}));
function nodeKey(node){return node.address||node.name}
function createCard(node){
  const el=document.createElement('article');
  el.className=`node ${node.mode||'active'}`;
  el.innerHTML=`<h3></h3><div class="status" data-k="status"></div><small data-k="scope"></small><div class="metric"><span>height</span><b data-k="height"></b></div><div class="metric"><span>chain sync</span><b data-k="sync"></b></div><div class="metric"><span>peers</span><b data-k="peers"></b></div><div class="metric software"><span>software</span><b data-k="versions"></b></div>`;
  el.querySelector('h3').textContent=node.name;
  set(el,'status',node.mode==='skip'?'SKIP':'checking…');
  set(el,'scope',node.mode==='skip'?node.reason:node.address);
  set(el,'height',node.mode==='skip'?'–':'…');
  set(el,'sync',node.mode==='skip'?'not joined':'…');
  set(el,'peers',node.mode==='skip'?'–':'…');
  set(el,'versions',node.mode==='skip'?'not running':'checking');
  if(node.mode==='skip')el.querySelector('[data-k="status"]').className='status skip';
  $('nodes').append(el);
  cards.set(nodeKey(node),el);
  return el;
}
for(const node of observedNodes)createCard(node);
async function json(url){const r=await fetch(url,{cache:'no-store'});if(!r.ok)throw new Error(`${r.status}`);return r.json()}
async function text(url){const r=await fetch(url,{cache:'no-store'});if(!r.ok)throw new Error(`${r.status}`);return r.text()}
function set(card,key,value){card.querySelector(`[data-k="${key}"]`).textContent=value}
function setUtcTime(id,date,label){const el=$(id);el.dateTime=date.toISOString();const value=new Intl.DateTimeFormat('en-GB',{timeZone:'UTC',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).format(date).replace(',','');el.textContent=`${label} ${value} UTC`}
function escapeHtml(value){return String(value).replace(/[&<>'"]/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char]))}
function syncStatus(value){
  const normalized = value === null || value === undefined ? '' : String(value).trim().toLowerCase();
  if (normalized === 'true' || value === true) return 'sync in progress';
  if (normalized === 'false' || value === false) return 'in sync';
  return 'checking';
}

function softwareVersions(state){
  const chain=state?.node_version?.version||'unknown';
  const dapi=state?.api_version?.version||'unknown';
  const ml=[...new Set((state?.mlnodes||[]).map(node=>node.version).filter(Boolean))];
  return `chain ${chain} · DAPI ${dapi} · MLNode ${ml.length?ml.join(', '):'unreported'}`;
}

function participantNode(participant){
  let endpoint;
  try{endpoint=new URL(participant.inference_url)}catch{endpoint=null}
  const host=endpoint?.hostname||'';
  const catalog=(cfg.nodeCatalog||cfg.nodes).find(node=>node.address===participant.address||node.publicHost===host);
  return {
    ...(catalog||{}),
    name:catalog?.name||host||`${participant.address.slice(0,10)}…`,
    address:participant.address,
    publicHost:catalog?.publicHost||host,
    statusBase:catalog?.statusBase||'',
    participantStatus:String(participant.status||'UNKNOWN'),
  };
}

async function reconcileParticipants(){
  const state=await json('/status/participants');
  const participants=Array.isArray(state.participant)?state.participant:[];
  const next=participants.map(participantNode).sort((left,right)=>left.name.localeCompare(right.name));
  const liveKeys=new Set(next.map(nodeKey));
  for(const [key,card] of cards){if(!liveKeys.has(key)){card.remove();cards.delete(key)}}
  for(const node of next){
    let card=cards.get(nodeKey(node));
    if(!card)card=createCard(node);
    card.querySelector('h3').textContent=node.name;
    set(card,'scope',node.address);
  }
  observedNodes=next;
  validatorMapController?.update(observedNodes);
  return Number(state.block_height)||0;
}

let validatorMapController;
async function initValidatorMap(){
  if(typeof window==='undefined')return;
  const container=$('validator-map'),shell=$('validator-map-shell'),button=$('validator-map-fullscreen');
  if(!container||!shell||!button)return;
  const module=await import('https://unpkg.com/leaflet@1.9.4/dist/leaflet-src.esm.js');
  const L=module.default??module;
  const bounds=[[-58,-175],[84,175]];
  const darkTiles='https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
  const lightTiles='https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
  const isLight=()=>getComputedStyle(document.documentElement).colorScheme.includes('light');
  const map=L.map(container,{center:[20,0],zoom:2,minZoom:1,maxZoom:10,zoomSnap:.1,maxBounds:bounds,maxBoundsViscosity:1,worldCopyJump:true,zoomControl:true,attributionControl:false});
  const tiles=L.tileLayer(isLight()?lightTiles:darkTiles,{subdomains:'abcd',maxZoom:20}).addTo(map);
  const markers=L.layerGroup().addTo(map);
  const primary=getComputedStyle(document.documentElement).getPropertyValue('--primary-color').trim();
  const update=nodes=>{
    markers.clearLayers();
    const groups=new Map();
    let validatorCount=0;
    for(const node of nodes){
      const lat=Number(node.geo?.latitude),lon=Number(node.geo?.longitude);
      if(!Number.isFinite(lat)||!Number.isFinite(lon))continue;
      const validator={ownerAddress:node.address||'',ip:node.ip||'',licenseCount:0,geo:{lat,lon,city:node.geo.city||'Unknown',country:node.geo.country||'Unknown',isp:'unverified'}};
      const key=`${lat.toFixed(1)},${lon.toFixed(1)}`;
      if(!groups.has(key))groups.set(key,[]);
      groups.get(key).push(validator);
      validatorCount+=1;
    }
    for(const validators of groups.values()){
      const first=validators[0],count=validators.length,radius=Math.min(5+Math.sqrt(count)*3,18);
      const rows=validators.map(v=>`<li><span>${escapeHtml(v.ip||'IP unavailable')}</span><span>${escapeHtml(v.ownerAddress.slice(0,10))}</span><span>${escapeHtml(v.licenseCount)}</span></li>`).join('');
      const popup=`<section class="validator-popup"><strong>${escapeHtml(first.geo.city)}, ${escapeHtml(first.geo.country)}</strong><p>${count} validator${count===1?'':'s'} at this location</p><ul>${rows}</ul></section>`;
      L.circleMarker([first.geo.lat,first.geo.lon],{radius,color:primary,weight:1,opacity:.95,fillColor:primary,fillOpacity:.7,className:'validator-marker'}).addTo(markers).bindPopup(popup,{closeButton:true,maxWidth:340});
    }
    container.dataset.validatorCount=String(validatorCount);
    container.dataset.markerCount=String(groups.size);
  };
  const fit=()=>{map.invalidateSize({animate:false,pan:false});map.fitBounds(bounds,{animate:false})};
  map.on('zoomend',()=>{map.panInsideBounds(bounds,{animate:false});map.invalidateSize({animate:false,pan:false});tiles.redraw()});
  const observer=new ResizeObserver(fit);observer.observe(container);
  const setFullscreen=open=>{shell.classList.toggle('is-fullscreen',open);button.setAttribute('aria-pressed',String(open));button.textContent=open?'Close':'Fullscreen';fit();setTimeout(fit,240)};
  button.addEventListener('click',()=>setFullscreen(!shell.classList.contains('is-fullscreen')));
  const onKeydown=event=>{if(event.key==='Escape'&&shell.classList.contains('is-fullscreen'))setFullscreen(false)};
  document.addEventListener('keydown',onKeydown);
  const theme=window.matchMedia('(prefers-color-scheme: light)'),onTheme=()=>tiles.setUrl(isLight()?lightTiles:darkTiles);
  theme.addEventListener('change',onTheme);
  window.addEventListener('pagehide',()=>{observer.disconnect();theme.removeEventListener('change',onTheme);document.removeEventListener('keydown',onKeydown);map.remove()},{once:true});
  update(observedNodes);fit();
  return {update};
}
initValidatorMap().then(controller=>{validatorMapController=controller;validatorMapController?.update(observedNodes)}).catch(()=>{$('validator-map').textContent='Validator map is unavailable'});
async function refresh(){let healthy=0,best=0;
  try{best=await reconcileParticipants()}catch{}
  await Promise.all(observedNodes.filter(n=>n.mode!=='skip').map(async n=>{const card=cards.get(nodeKey(n));if(!card)return;if(!n.statusBase){set(card,'status',`${n.participantStatus.toLowerCase()} (chain)`);card.querySelector('[data-k="status"]').className=n.participantStatus==='ACTIVE'?'status ok':'status bad';set(card,'height',best?best.toLocaleString():'–');set(card,'sync','endpoint not proxied');set(card,'peers','–');set(card,'versions','unreported');return}try{const [s,net]=await Promise.all([json(`${n.statusBase}/chain-rpc/status`),json(`${n.statusBase}/chain-rpc/net_info`)]);const h=Number(s.result.sync_info.latest_block_height),peers=Number(net.result.n_peers);best=Math.max(best,h);set(card,'height',h.toLocaleString());set(card,'sync',syncStatus(s.result.sync_info.catching_up));set(card,'peers',peers);if(peers===0){set(card,'status','online (no peers)');card.querySelector('[data-k="status"]').className='status bad'}else{set(card,'status','online');card.querySelector('[data-k="status"]').className='status ok'};healthy++;try{set(card,'versions',softwareVersions(await json(`${n.statusBase}/v1/versions`)))}catch{set(card,'versions','unreported')}}catch(e){set(card,'status',`offline (${e.message})`);card.querySelector('[data-k="status"]').className='status bad';set(card,'versions','unavailable')}}));
 $('best-height').textContent=best?best.toLocaleString():'–';setUtcTime('updated',new Date(),'Updated');
 try{if(!chainRpcHost)throw new Error('chain RPC host is missing');const v=await json(`https://${chainRpcHost}/chain-rpc/validators?per_page=100`);const vals=v.result.validators||[];const powers=vals.map(x=>BigInt(x.voting_power));const total=powers.reduce((a,b)=>a+b,0n);const max=powers.reduce((a,b)=>a>b?a:b,0n);const share=total?Number(max*10000n/total)/100:0;const unsafe=total>0n&&max*3n>=total;$('power-share').textContent=`${share.toFixed(2)}%`;$('power-share').style.color=unsafe?'var(--bad)':'var(--ok)'}catch{$('power-share').textContent='–'}
 let gatewayState,gatewayProbe;try{[gatewayState,gatewayProbe]=await Promise.all([json('/status/gateway/v1/status'),json('/status/gateway-health')])}catch{}
 try{if(!gatewayStatus.classify(gatewayState,healthy,gatewayProbe).available)throw new Error('gateway unavailable');const runtime=gatewayState.escrow_id?gatewayState:(gatewayState.devshards||[]).find(item=>item.active&&item.phase==='active'&&!item.requests_blocked);if(!runtime?.id&&!runtime?.escrow_id)throw new Error('no active unblocked escrow');const escrowId=runtime.id||runtime.escrow_id;$('gateway-access').hidden=false;$('gateway-detail').textContent=`Escrow #${escrowId} is ACTIVE – authenticated chain-accounted inference is accepting requests`}catch(error){$('gateway-access').hidden=true}
 try{const availability=gatewayStatus.classify(gatewayState,healthy,gatewayProbe);if(!availability.available)throw new Error(availability.message);const metricText=await text('/status/gateway/metrics'),metricValue=name=>[...metricText.matchAll(new RegExp(`^${name}(?:\\{[^}]*\\})?\\s+([0-9.e+-]+)$`,'gm'))].reduce((total,match)=>total+Number(match[1]),0),inflight=metricValue('devshard_gateway_inflight_requests'),tokens=metricValue('devshard_gateway_inflight_input_tokens'),accepted=metricValue('devshard_gateway_requests_total'),rejected=metricValue('devshard_gateway_limit_rejections_total'),capacity=metricValue('devshard_gateway_capacity_scale');const values=[String(inflight),tokens.toLocaleString(),accepted.toLocaleString(),rejected.toLocaleString(),`${Math.round(capacity*100)}%`];[...$('quality-metrics').children].forEach((card,index)=>card.querySelector('strong').textContent=values[index]);$('quality-active').textContent=inflight;$('quality-accepted').textContent=accepted;$('quality-rejected').textContent=rejected;const health=$('quality-health'),state=inflight>0?'active':'idle';health.dataset.state=state;$('quality-health-state').textContent=inflight>0?'READY – processing requests':'READY – no requests in flight';setUtcTime('quality-updated',new Date(),'Updated')}catch(error){const availability=gatewayStatus.classify(gatewayState,healthy,gatewayProbe);$('quality-health-state').textContent=availability.state;$('quality-health').dataset.state=availability.state==='PENDING'?'degraded':'down';$('quality-updated').textContent=availability.message}
}
refresh();setInterval(refresh,15000);
