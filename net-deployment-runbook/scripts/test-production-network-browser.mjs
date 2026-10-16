import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startChromeDevTools, stopChromeDevTools } from "./chrome-devtools.mjs";

const site = new URL("../04-ops/site/", import.meta.url);
const profile = await mkdtemp(join(tmpdir(), "gdc-production-browser-"));
const requests = [];
const nodeId = "a".repeat(40), validator = "B".repeat(40);
let observation = "unavailable";
const snapshot = () => {
  const now = new Date().toISOString();
  const node = {node_id:nodeId, node_name:"node0", dapi_url:"https://node0.gonka-dev.net", active:true,
    components:{
      chain_rpc:{state:"observed",p2p_node_id:nodeId,chain_id:"fixture-chain",validator_address:validator,
        validator_voting_power:"72",latest_block_height:1050,latest_block_time:now,observed_at:now,catching_up:false},
      peers:{state:"observed",count:7},
      versions:{state:"observed",observed_at:now,api_version:{version:"v0.2.16",commit:"a".repeat(40)},
        node_version:{version:"v0.2.16",commit:"a".repeat(40)},mlnodes:[]},
      inferenced:{state:"observed",observed_at:now,version:"v0.2.16",commit:"a".repeat(40)},
      models:{state:"observed",models:[{id:"fixture-model"}]},
      devshard:{state:"observed",observed_at:now,runtimes:[{name:"v6",status:"running",sha256:"c".repeat(64)}],
        stats:{state:"observed",observed_at:now,protocol_version:"v6",current_epoch_id:7,
          cached_at:Date.now()/1000,cache_ttl_seconds:60,active_escrows:[],shards:[]}},
    }};
  const value = {schema_version:1,chain_id:"fixture-chain",observed_at:now,nodes:[node],
    ...(observation === "legacy" ? {} : {chain:{state:"observed",
      observed_at:observation === "stale" ? new Date(Date.now()-120000).toISOString() : now,
      reference:{node_id:nodeId,height:1050},validators:[{address:validator,voting_power:"72"}],
      participants:[{address:"gonka1fixtureaccount",inference_url:node.dapi_url,status:"ACTIVE"}],
      hardware_nodes:[{address:"gonka1fixtureaccount",nodes:[{local_id:"fixture",host:"inference",port:"8080",
        version:"3.0.16",hardware:[{type:"Fixture GPU | 24GB",count:1}]}]}],
      approved_devshards:[{name:"v6",sha256:"c".repeat(64)}],
      model_assignments:{state:"observed",epoch_index:"6",effective_block_height:"950",reference_height:1050,
        groups:[{model_id:"Qwen/Allocated",state:"observed",participants:[{address:"gonka1fixtureaccount",weight:"72"}]},
          {model_id:"Qwen/Empty",state:"observed",participants:[]},
          {model_id:"Qwen/Unavailable",state:"unavailable"}]},
      activity:{epoch:{latest_epoch:{index:"7",poc_start_block_height:"1000",end_height:"1100",blocks_remaining:"50"},
        estimated_remaining_seconds:100,block_interval_seconds:2},
        cpoc:{state:"observed",active:false,recent_events_state:"observed",recent_events:[]},
        finalized_epoch:{state:"unavailable"},commits:{commits:[]},votes:{poc_validation:[]}},
    }}),
  };
  return observation === "empty" ? {...value,nodes:[]} : value;
};
const server = createServer(async (request,response) => {
  const pathname = new URL(request.url,"http://fixture").pathname;
  requests.push(pathname);
  response.setHeader("Cache-Control","no-store");
  if (pathname === "/config.js") {
    response.setHeader("Content-Type","application/javascript");
    response.end(`window.GDC_CONFIG=${JSON.stringify({chainId:"fixture-chain",model:"old-model",nodes:[],nodeCatalog:[],gatewayNode:"node0"})}`);
  } else if (pathname === "/status/network") {
    response.setHeader("Content-Type","application/json");
    if (observation === "unavailable") {
      response.writeHead(503);
      response.end('{"state":"network_observation_unavailable"}');
    } else response.end(JSON.stringify(snapshot()));
  } else if (pathname.startsWith("/status/")) {
    response.writeHead(503,{"Content-Type":"application/json"});
    response.end('{"available":false}');
  } else {
    try {
      const file = pathname === "/" ? "index.html" : pathname.slice(1);
      if (!/^[A-Za-z0-9_./-]+$/.test(file) || file.includes("..")) throw new Error("path");
      response.setHeader("Content-Type",file.endsWith(".js")?"application/javascript":file.endsWith(".css")?"text/css":file.endsWith(".svg")?"image/svg+xml":"text/html");
      response.end(await readFile(new URL(file,site)));
    } catch {response.writeHead(404);response.end();}
  }
});
let chrome, socket;
try {
  await new Promise(resolve=>server.listen(0,"127.0.0.1",resolve));
  chrome = await startChromeDevTools({profile,context:"production network snapshot"});
  const endpoint = await chrome.waitForEndpoint();
  socket = new WebSocket(endpoint.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  let id=0;
  const pending = new Map();
  socket.onmessage = ({data}) => {
    const message=JSON.parse(data), job=pending.get(message.id);
    if (!job) return;
    pending.delete(message.id);
    message.error?job.reject(new Error(JSON.stringify(message.error))):job.resolve(message.result);
  };
  const call=(method,params={},sessionId)=>new Promise((resolve,reject)=>{
    const next=++id;pending.set(next,{resolve,reject});socket.send(JSON.stringify({id:next,method,params,sessionId}));
  });
  const {targetId}=await call("Target.createTarget",{url:"about:blank"});
  const {sessionId}=await call("Target.attachToTarget",{targetId,flatten:true});
  await call("Page.enable",{},sessionId);
  await call("Runtime.enable",{},sessionId);
  await call("Page.navigate",{url:`http://127.0.0.1:${server.address().port}/`},sessionId);
  const evaluate=async expression => {
    const result=await call("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true},sessionId);
    assert.equal(result.exceptionDetails,undefined,JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const state=()=>evaluate(`JSON.stringify({epoch:document.querySelector('#epoch-label').textContent,hidden:document.querySelector('#epoch-overview').hidden,cpoc:document.querySelector('#epoch-cpoc-state').textContent,shards:document.querySelector('#devshard-execution').hidden,node:document.querySelector('#nodes')?.innerText,nodeCount:document.querySelectorAll('#nodes .node').length,source:document.querySelector('#network-source').textContent,updated:document.querySelector('#updated').textContent,updatedAt:document.querySelector('#updated').getAttribute('datetime'),bestHeight:document.querySelector('#best-height').textContent,gateway:document.querySelector('#quality-health-state').textContent,recovery:document.querySelector('#quality-recovery').textContent,chain:publicChainState?.state})`);
  let unavailable;
  for(let attempt=0;attempt<100;attempt++) {
    unavailable=JSON.parse(await state().catch(()=>'{}'));
    if(unavailable.source==="NETWORK OBSERVATION UNAVAILABLE") break;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  assert.equal(unavailable.source,"NETWORK OBSERVATION UNAVAILABLE",JSON.stringify(unavailable));
  assert.equal(unavailable.updated,"Network observer unavailable");
  assert.equal(unavailable.updatedAt,null,"an unavailable snapshot must not have a successful-observation timestamp");
  assert.notEqual(unavailable.gateway,"OFFLINE","an unavailable observer is not proof of a reset network");
  assert.notEqual(unavailable.recovery,"Network reset – no nodes online");
  observation="current";
  await evaluate("networkSnapshot=null; refresh()");
  let current;
  for(let attempt=0;attempt<100;attempt++) {
    current=JSON.parse(await state().catch(()=>"{}"));
    if(current.epoch==="Epoch 7") break;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  assert.equal(current.epoch,"Epoch 7",JSON.stringify(current));
  assert.equal(current.hidden,false);
  assert.equal(current.cpoc,"No active event");
  assert.equal(current.shards,false);
  assert.match(current.node,/VALIDATING/);
  assert.match(current.node,/Fixture GPU/);
  assert.equal(current.chain,"observed");
  const qthGroups = await evaluate(`(() => {
    const nodes = [
      {ownerAddress:"node0",gpuCount:1,geo:{lat:39.0997282,lon:-94.5785689}},
      {ownerAddress:"node5",gpuCount:1,geo:{lat:39.0997282,lon:-94.5785689,locationId:"provider-a"}},
      {ownerAddress:"node11",gpuCount:2,geo:{lat:39.1141718,lon:-94.6274601,locationId:"provider-b"}},
      {ownerAddress:"neighbor",gpuCount:1,geo:{lat:39.1,lon:-96.01}},
    ];
    const groups = groupValidators(nodes);
    const em29 = groups.find(group => group.label === "EM29");
    const retained = groupValidators([nodes[2]]).find(group => group.label === "EM29");
    return {groups:groups.length,key:em29.key,members:em29.validators.map(node => node.ownerAddress).sort(),
      gpus:em29.validators.reduce((sum,node) => sum + node.gpuCount,0),
      stable:em29.lat === retained.lat && em29.lon === retained.lon};
  })()`);
  assert.deepEqual(qthGroups, {groups:2,key:"qth:EM29",members:["node0","node11","node5"],gpus:4,stable:true});
  const qthMarker = await evaluate(`(() => {
    const nodes = [["node0",39.0997282,-94.5785689,1],["node5",39.0997282,-94.5785689,1],["node11",39.1141718,-94.6274601,2]]
      .map(([name,latitude,longitude,count]) => {
        cardHardwareInventory.set(name,{state:"observed",nodes:[{host:"inference",hardware:[{type:"Fixture GPU | 24GB",count}]}]});
        return {name,address:name,isOnline:true,participantState:"ACTIVE",geo:{latitude,longitude}};
      });
    validatorMapController.update(nodes);
    const markers = [...document.querySelectorAll('.validator-marker')];
    const result = markers.map(marker => marker.getAttribute('aria-label'));
    validatorMapController.update(observedNodes);
    for (const node of nodes) cardHardwareInventory.delete(node.address);
    return result;
  })()`);
  assert.equal(qthMarker.length,1);
  assert.match(qthMarker[0],/^EM29; 3 nodes; 4 GPUs;/);
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#devshard-versions li'), item => item.textContent)"), ["v6 cccccc"]);
  const modelText = () => evaluate("document.querySelector('#nodes [data-k=\"models\"]').textContent");
  assert.equal(await evaluate("document.querySelector('#model-assignments')"), null);
  assert.equal(await evaluate("document.querySelector('#model-id').textContent"), "Qwen/Allocated");
  assert.equal(await modelText(), "Allocated");
  await evaluate(`applyPublicChainState({...publicChainState,model_assignments:{...publicChainState.model_assignments,
    groups:[...publicChainState.model_assignments.groups,{model_id:"Qwen/Second",state:"observed",participants:[{address:"gonka1fixtureaccount",weight:"1"}]}]}})`);
  assert.equal(await evaluate("document.querySelectorAll('#nodes [data-k=\"models\"] li').length"), 2, "one participant can have multiple models");
  assert.equal(await modelText(), "AllocatedSecond");
  assert.doesNotMatch(await modelText(), /old-model|fixture-model/, "configured and registered models must not replace effective allocations");
  await evaluate(`applyPublicChainState({...publicChainState,participants:[...publicChainState.participants,
    {address:"gonka1historical",inference_url:"https://node0.gonka-dev.net",status:"INACTIVE"}]})`);
  assert.equal(await modelText(), "Not reported", "unknown participant identity must not invent a model assignment");
  await evaluate(`applyPublicChainState({...publicChainState,
    validators:[{address:"${validator}",voting_power:"72",validator_key:"current-key"}],
    participants:[{address:"gonka1historical",inference_url:"https://node0.gonka-dev.net",status:"INACTIVE",validator_key:"old-key"},
      {address:"gonka1fixtureaccount",inference_url:"https://node0.gonka-dev.net",status:"ACTIVE",validator_key:"current-key"}]})`);
  assert.equal(await modelText(), "AllocatedSecond", "current consensus key must disambiguate historical Host URLs");
  await evaluate(`applyPublicChainState({...publicChainState,model_assignments:{state:"observed",epoch_index:"6",groups:[]}})`);
  assert.equal(await modelText(), "No allocated models");
  await evaluate(`applyPublicChainState({...publicChainState,model_assignments:{state:"partial",epoch_index:"6",groups:[]}})`);
  assert.equal(await modelText(), "Not reported");
  await evaluate("networkSnapshot=null; refresh()");
  assert.match(current.node,/Synced/,"chain snapshot supplies the sync reference without browser RPC routes");
  assert(requests.includes("/status/gateway/v1/status"),"production gateway must remain enabled");
  assert(!requests.some(url=>/\/chain-(rpc|api)\//.test(url)),"snapshot must not be overwritten by legacy per-Host requests");
  observation="empty";
  await evaluate("networkSnapshot=null; refresh()");
  current=JSON.parse(await state());
  assert.equal(current.nodeCount,0,"a fresh, verified empty snapshot must clear participant cards");
  assert.equal(current.source,"LIVE NETWORK");
  assert.match(current.updated,/^Updated .* UTC$/,"a verified empty snapshot is still a successful observation");
  assert.ok(current.updatedAt,"a verified empty snapshot keeps its successful-observation timestamp");
  assert.equal(current.bestHeight,"–");
  assert.equal(current.gateway,"OFFLINE");
  assert.equal(current.recovery,"Network reset – no nodes online","observed empty state retains its reset behavior");
  observation="current";
  await evaluate("networkSnapshot=null; refresh()");
  await evaluate(`networkSnapshot=${JSON.stringify({...snapshot(), observed_at:new Date(Date.now()-120000).toISOString(), nodes:[]})}`);
  const httpReads=requests.filter(path=>path==="/status/network").length;
  await evaluate("refresh()");
  assert(requests.filter(path=>path==="/status/network").length>httpReads,"stalled stream must fall back to HTTP");
  assert.match(JSON.parse(await state()).node,/Fixture GPU/);
  await evaluate("networkSnapshot=null");
  observation="stale";
  await evaluate("refresh()");
  current=JSON.parse(await state());
  assert.equal(current.chain,undefined,"stale chain observations must not retain effective membership");
  assert.equal(await modelText(), "Not reported", "stale allocations must disappear");
  assert.equal(current.hidden,true);
  observation="current";
  await evaluate("refresh()");
  assert.equal(JSON.parse(await state()).chain,"observed");
  observation="legacy";
  await evaluate("refresh()");
  current=JSON.parse(await state());
  assert.equal(current.source,"NETWORK OBSERVER UPDATE REQUIRED");
  assert.equal(current.chain,undefined,"legacy observations cannot retain prior chain evidence");
  assert.equal(await modelText(), "Not reported", "legacy snapshots cannot fall back to model catalogs");
  observation="current";
  await evaluate("cfg.publicBootstrap=true; configureNetwork(); refresh()");
  current=JSON.parse(await state());
  assert.equal(current.epoch,"Epoch 7");
  assert.match(current.node,/Synced/,"selected networks must use the observer reference even without status routes");
  assert.equal(await evaluate("document.querySelector('#quality-health-state').textContent"),"NOT REPORTED");
  console.log("PASS production consumes fresh peer, epoch, cPoC, MLNode and DevShard snapshots without disabling gateway evidence");
} finally {
  socket?.close();
  await stopChromeDevTools(chrome?.browser);
  server.closeAllConnections();
  await new Promise(resolve=>server.close(resolve));
  await rm(profile,{recursive:true,force:true});
}
