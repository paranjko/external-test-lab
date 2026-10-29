#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC="$HERE/../edge-node/public-grafana/dashboards"

render() {
  local kind="$1" output="$2"
  jq -n --arg kind "$kind" '
    def ds: {type:"prometheus",uid:"prometheus"};
    def target($expr; $legend):
      {expr:$expr,refId:"A"} + (if $legend == "" then {} else {legendFormat:$legend} end);
    def tscustom:
      {axisCenteredZero:false,axisColorMode:"text",axisLabel:"",axisPlacement:"auto",drawStyle:"line",fillOpacity:12,gradientMode:"opacity",hideFrom:{legend:false,tooltip:false,viz:false},lineInterpolation:"smooth",lineWidth:2,pointSize:4,scaleDistribution:{type:"linear"},showPoints:"auto",spanNulls:false,stacking:{group:"A",mode:"none"},thresholdsStyle:{mode:"off"}};
    def tablecustom: {align:"auto",cellOptions:{type:"auto"},inspect:false};
    # $desc documents what a value means and what its absence means; $fc overrides
    # fieldConfig.defaults (noValue, mappings, thresholds, unit); $opts overrides the
    # panel options. A $fc.custom object is merged into the shared custom block, never
    # replaces it, so an override cannot silently drop the axis and line settings.
    def stat($id;$title;$expr;$unit;$x;$y;$w;$desc;$fc;$opts):
      ({id:$id,datasource:ds,type:"stat",title:$title,gridPos:{h:4,w:$w,x:$x,y:$y},
       fieldConfig:{defaults:({color:{mode:"thresholds"},thresholds:{mode:"absolute",steps:[{color:"green",value:null}]}} +
         (if $unit == "" then {} else {unit:$unit} end) + $fc),overrides:[]},
       options:({colorMode:"none",graphMode:"none",justifyMode:"auto",orientation:"auto",reduceOptions:{calcs:["lastNotNull"],fields:"",values:false},textMode:"auto",wideLayout:true} + $opts),
       targets:[target($expr;"") + {instant:true}]}
       + (if $desc == "" then {} else {description:$desc} end));
    def stat($id;$title;$expr;$unit;$x;$y;$w): stat($id;$title;$expr;$unit;$x;$y;$w;"";{};{});
    def ts($id;$title;$expr;$legend;$unit;$x;$y;$w;$h;$desc;$fc;$legendcalcs):
      ({id:$id,datasource:ds,type:"timeseries",title:$title,gridPos:{h:$h,w:$w,x:$x,y:$y},
       fieldConfig:{defaults:({color:{mode:"palette-classic"},custom:tscustom,thresholds:{mode:"absolute",steps:[{color:"green",value:null}]}} +
         (if $unit == "" then {} else {unit:$unit} end) + ($fc|del(.custom)) + {custom:(tscustom + ($fc.custom // {}))}),overrides:[]},
       options:{legend:{calcs:$legendcalcs,displayMode:"table",placement:"bottom",showLegend:true},tooltip:{mode:"multi",sort:"desc"}},
       targets:[target($expr;$legend)]}
       + (if $desc == "" then {} else {description:$desc} end));
    def ts($id;$title;$expr;$legend;$unit;$x;$y;$w;$h): ts($id;$title;$expr;$legend;$unit;$x;$y;$w;$h;"";{};["lastNotNull"]);
    def table($id;$title;$expr;$x;$y;$w;$h;$desc;$fc):
      ({id:$id,datasource:ds,type:"table",title:$title,gridPos:{h:$h,w:$w,x:$x,y:$y},
       fieldConfig:{defaults:({custom:tablecustom} + ($fc|del(.custom)) + {custom:(tablecustom + ($fc.custom // {}))}),overrides:[]},
       options:{cellHeight:"sm",footer:{countRows:false,fields:"",reducer:["sum"],show:false},showHeader:true},
       targets:[target($expr;"") + {format:"table",instant:true}]}
       + (if $desc == "" then {} else {description:$desc} end));
    def table($id;$title;$expr;$x;$y;$w;$h): table($id;$title;$expr;$x;$y;$w;$h;"";{});
    def row($id;$title;$y): {id:$id,type:"row",title:$title,collapsed:false,gridPos:{h:1,w:24,x:0,y:$y},panels:[]};
    # $extra shallow-replaces top-level board keys; it does not deep-merge.
    def base($uid;$title;$from;$panels;$extra):
      {annotations:{list:[]},editable:false,fiscalYearStartMonth:0,graphTooltip:1,id:null,
       links:[{asDropdown:true,icon:"dashboard",includeVars:false,keepTime:true,tags:["gdc"],targetBlank:false,title:"Community DevNet dashboards",type:"dashboards"}],
       liveNow:true,panels:$panels,refresh:"15s",schemaVersion:41,tags:["gonka","gdc"],templating:{list:[]},time:{from:$from,to:"now"},timepicker:{refresh_intervals:["5s","10s","15s","30s","1m","5m"]},timezone:"utc",title:$title,uid:$uid,version:1} + $extra;
    def base($uid;$title;$from;$panels): base($uid;$title;$from;$panels;{});
    # Filters default to All, whose value is the regex .* in every matcher.
    def filtervar($name;$label;$query):
      {name:$name,label:$label,type:"query",datasource:ds,definition:$query,query:{query:$query,refId:$name},
       multi:true,includeAll:true,allValue:".*",current:{selected:true,text:["All"],value:["$__all"]},
       options:[],refresh:2,regex:"",sort:1,hide:0};
    def phases: [{type:"value",options:{"0":{text:"PoC generation",color:"purple",index:0},"1":{text:"batch exchange and wait",color:"blue",index:1},"2":{text:"PoC validation",color:"orange",index:2},"3":{text:"validator set switch",color:"yellow",index:3},"4":{text:"inference",color:"green",index:4}}}];
    def phasedesc: "Cycle counted from the PoC start P read from epoch_info: PoC generation, batch exchange and wait, PoC validation, validator set switch (group written at P+19, the new set signs from P+23), then inference until the next PoC.";

    if $kind == "network" then
      def hosts: "host=~\"$host\"";
      def override($name;$props): {matcher:{id:"byName",options:$name},properties:$props};
      def tabletarget($expr;$ref): target($expr;"") + {refId:$ref,format:"table",instant:true};
      def updown: [{id:"mappings",value:[{type:"value",options:{"0":{text:"down",color:"red",index:0},"1":{text:"up",color:"green",index:1}}}]},{id:"custom.cellOptions",value:{type:"color-text"}}];
      def red1: {mode:"absolute",steps:[{color:"green",value:null},{color:"red",value:1}]};
      base("gdc-network";"Gonka DevNet Network";"now-24h";[
        row(100;"Network now";0),
        stat(1;"Chain height";"max(cometbft_consensus_height)";"none";0;1;3;"Highest block any scraped chain node reports.";{noValue:"no chain node is scraped"};{}),
        stat(2;"Block time";"histogram_quantile(0.50, sum by (le) (rate(cometbft_consensus_block_interval_seconds_bucket[10m])))";"s";3;1;3;"Median interval between blocks over ten minutes.";{noValue:"no block-interval histogram in the window",decimals:1};{}),
        stat(3;"Transactions per second";"max(rate(cometbft_consensus_total_txs[5m]))";"ops";6;1;3;"Committed transactions per second. Every node counts the same transactions, so this is the highest node rate, not a sum.";{noValue:"no transaction counter scraped",decimals:2};{}),
        (stat(4;"Validators";"max(cometbft_consensus_validators)";"none";9;1;3;"Size of the active validator set as the chain reports it. It changes with the epoch, so read the sparkline too.";{noValue:"no chain node is scraped"};{graphMode:"area",colorMode:"value"}) | .targets[0].instant=false),
        stat(5;"Nodes online";"sum(up{job=\"gonka-node\"})";"none";12;1;3;"Chain nodes of the monitoring inventory that answered their last scrape. A validator outside the inventory is not counted.";{noValue:"no chain target is configured"};{}),
        stat(6;"Nodes behind";"count((scalar(max(cometbft_consensus_height)) - max by (host) (cometbft_consensus_height)) > 3) or vector(0)";"none";15;1;3;"Chain nodes more than three blocks behind the highest scraped node.";{thresholds:red1};{colorMode:"value"}),
        stat(7;"P2P peers";"sum(cometbft_p2p_peers)";"none";18;1;3;"Peer connections summed over scraped chain nodes.";{noValue:"no node reported a peer count"};{}),
        stat(8;"Stalest chain sample";"max(time() - timestamp(cometbft_consensus_height))";"s";21;1;3;"Age of the oldest chain sample across scraped nodes. One node falling silent raises it.";{noValue:"no chain sample in the lookback window",thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:45},{color:"red",value:120}]}};{colorMode:"value"}),

        row(110;"Chain nodes";5),
        (table(11;"Chain nodes";"max by (host) (up{job=\"gonka-node\",\(hosts)})";0;6;24;10;"One row per chain node: scrape state, lag behind the highest node, peers, current consensus round, mempool, validator power and missed blocks as the node itself reports them, P2P traffic and the running chain version.";{noValue:"no chain node matches the filter"})
          | .targets=[tabletarget("max by (host) (up{job=\"gonka-node\",\(hosts)})";"A"),
              tabletarget("scalar(max(cometbft_consensus_height)) - max by (host) (cometbft_consensus_height{\(hosts)})";"B"),
              tabletarget("max by (host) (cometbft_p2p_peers{\(hosts)})";"C"),
              tabletarget("max by (host) (cometbft_consensus_rounds{\(hosts)})";"D"),
              tabletarget("max by (host) (cometbft_mempool_size{\(hosts)})";"E"),
              tabletarget("max by (host) (cometbft_consensus_validator_power{\(hosts)})";"F"),
              tabletarget("max by (host) (cometbft_consensus_validator_missed_blocks{\(hosts)})";"G"),
              tabletarget("sum by (host) (rate(cometbft_p2p_peer_receive_bytes_total{\(hosts)}[5m]))";"H"),
              tabletarget("sum by (host) (rate(cometbft_p2p_peer_send_bytes_total{\(hosts)}[5m]))";"I"),
              tabletarget("max by (host, version) (gdc_component_info{component=\"inference-chain\",source=\"runtime\",\(hosts)})";"J")]
          | .fieldConfig.defaults.noValue="–"
          | .transformations=[{id:"merge",options:{}},{id:"organize",options:{
              excludeByName:{Time:true,"Value #J":true},
              indexByName:{host:0,"Value #A":1,"Value #B":2,"Value #C":3,"Value #D":4,"Value #E":5,"Value #F":6,"Value #G":7,"Value #H":8,"Value #I":9,version:10},
              renameByName:{host:"Node","Value #A":"Chain","Value #B":"Blocks behind","Value #C":"Peers","Value #D":"Round","Value #E":"Mempool","Value #F":"Validator power","Value #G":"Missed blocks","Value #H":"P2P in","Value #I":"P2P out",version:"Version"}}}]
          | .fieldConfig.overrides=[override("Chain";updown),
              override("Blocks behind";[{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:3},{color:"red",value:20}]}}]),
              override("Round";[{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:red1}]),
              override("Missed blocks";[{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:5},{color:"red",value:50}]}}]),
              override("P2P in";[{id:"unit",value:"Bps"}]),override("P2P out";[{id:"unit",value:"Bps"}])]),

        row(120;"Consensus";16),
        ts(21;"Blocks behind";"scalar(max(cometbft_consensus_height)) - max by (host) (cometbft_consensus_height{\(hosts)})";"{{host}}";"none";0;17;8;8;"How far each chain node is behind the highest scraped node.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        (ts(22;"Block interval";"histogram_quantile(0.50, sum by (le) (rate(cometbft_consensus_block_interval_seconds_bucket[10m])))";"p50";"s";8;17;8;8;"Median and 95th percentile interval between blocks over ten minutes.";{noValue:"no block-interval histogram in the window"};["lastNotNull","max"])
          | .targets += [{expr:"histogram_quantile(0.95, sum by (le) (rate(cometbft_consensus_block_interval_seconds_bucket[10m])))",refId:"B",legendFormat:"p95"}]),
        ts(23;"Round duration p95";"histogram_quantile(0.95, sum by (le) (rate(cometbft_consensus_round_duration_seconds_bucket[10m])))";"p95";"s";16;17;8;8;"95th percentile of consensus round duration. A long round means slow proposals or votes.";{noValue:"no round-duration histogram in the window"};["lastNotNull","max"]),
        ts(24;"Consensus rounds";"max by (host) (cometbft_consensus_rounds{\(hosts)})";"{{host}}";"none";0;25;8;8;"Round of the current height. Above zero, the first proposal did not commit.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(25;"Voting power signed";"max by (host) (max_over_time(cometbft_consensus_round_voting_power_percent{vote_type=\"precommit\",\(hosts)}[1m]))";"{{host}}";"percentunit";8;25;8;8;"Share of voting power seen in precommit, peak of each minute. The dashed line at two thirds is the floor below which a round cannot commit.";{noValue:"no consensus round sampled in the window",min:0,thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:0.6667},{color:"green",value:0.7}]},custom:{thresholdsStyle:{mode:"dashed"}}};["lastNotNull"]),
        ts(26;"Missing validators";"max by (host) (cometbft_consensus_missing_validators{\(hosts)})";"{{host}}";"none";16;25;8;8;"Validators absent from the last commit, as each node saw it.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(27;"Missed blocks by validator";"max by (host) (cometbft_consensus_validator_missed_blocks{\(hosts)})";"{{host}}";"none";0;33;8;8;"Blocks the validator of the node missed. A host without its own validator exports nothing.";{noValue:"no validator exports a missed-block counter"};["lastNotNull","max"]),
        ts(28;"Late votes";"sum by (host) (rate(cometbft_consensus_late_votes{\(hosts)}[5m]))";"{{host}}";"none";8;33;8;8;"Votes per second that arrived after their step ended. A rise on one node points at its network or clock.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(29;"Block processing p95";"histogram_quantile(0.95, sum by (le, host) (rate(cometbft_state_block_processing_time_bucket{\(hosts)}[10m])))";"{{host}}";"ms";16;33;8;8;"95th percentile time to apply a block per node.";{noValue:"no block-processing histogram in the window"};["lastNotNull","max"]),

        row(130;"Transactions and P2P";41),
        ts(31;"Transactions per second";"max(rate(cometbft_consensus_total_txs[5m]))";"transactions";"ops";0;42;8;8;"Committed transactions per second, the highest node rate.";{noValue:"no transaction counter scraped"};["lastNotNull","max"]),
        ts(32;"Mempool";"max by (host) (cometbft_mempool_size{\(hosts)})";"{{host}}";"none";8;42;8;8;"Transactions waiting in the mempool of each node.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(33;"Failed mempool transactions";"sum by (host) (rate(cometbft_mempool_failed_txs{\(hosts)}[5m]))";"{{host}}";"ops";16;42;8;8;"Transactions per second each node rejected at mempool check.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(34;"P2P peers";"max by (host) (cometbft_p2p_peers{\(hosts)})";"{{host}}";"none";0;50;8;8;"Peer connections per chain node.";{noValue:"no chain node matches the filter"};["lastNotNull","min"]),
        ts(35;"P2P received";"sum by (host) (rate(cometbft_p2p_peer_receive_bytes_total{\(hosts)}[5m]))";"{{host}}";"Bps";8;50;8;8;"Bytes per second each node receives from its peers.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(36;"P2P sent";"sum by (host) (rate(cometbft_p2p_peer_send_bytes_total{\(hosts)}[5m]))";"{{host}}";"Bps";16;50;8;8;"Bytes per second each node sends to its peers.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),

        row(140;"Hosts";58),
        ts(41;"CPU busy";"100 - avg by (host) (rate(node_cpu_seconds_total{mode=\"idle\",\(hosts)}[5m])) * 100";"{{host}}";"percent";0;59;8;8;"Share of CPU time not idle, averaged over cores.";{noValue:"no host matches the filter",min:0,max:100};["lastNotNull","max"]),
        ts(42;"Memory used";"max by (host) ((1 - node_memory_MemAvailable_bytes{\(hosts)} / node_memory_MemTotal_bytes{\(hosts)}) * 100)";"{{host}}";"percent";8;59;8;8;"Memory in use, excluding reclaimable cache.";{noValue:"no host matches the filter",min:0,max:100};["lastNotNull","max"]),
        ts(43;"Operational disk free";"min by (host) (node_filesystem_avail_bytes{fstype=~\"ext4|xfs|btrfs|zfs\",mountpoint!~\"/boot.*\",\(hosts)} / node_filesystem_size_bytes{fstype=~\"ext4|xfs|btrfs|zfs\",mountpoint!~\"/boot.*\",\(hosts)} * 100)";"{{host}}";"percent";16;59;8;8;"Free space on the fullest real volume of each host. The dashed lines are the 15% and 8% disk alert levels.";{noValue:"no host matches the filter",min:0,max:100,thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:8},{color:"green",value:15}]},custom:{thresholdsStyle:{mode:"dashed"}}};["lastNotNull","min"]),
        (table(44;"Software inventory";"gdc_component_info{\(hosts)}";0;67;24;8;"Component versions each host reports.";{noValue:"no host matching the filter has reported its software inventory"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true,Value:true,__name__:true,job:true,instance:true,exported_host:true,city:true,country:true,latitude:true,longitude:true},renameByName:{host:"Host",component:"Component",component_instance:"Instance",version:"Version",commit:"Commit",image:"Image",source:"Source"}}}]),

        row(150;"Collection";75),
        stat(51;"Hosts reporting";"count(max by (host) (up{job=\"host\"}) == 1)";"none";0;76;6;"Hosts whose node-exporter answered its last scrape.";{noValue:"no host target is configured"};{}),
        stat(52;"Targets down";"sum(up == bool 0)";"none";6;76;6;"Scrape targets that failed their last attempt, across every job.";{noValue:"no target is configured",thresholds:red1};{colorMode:"value"}),
        stat(53;"Validators beyond the monitored set";"clamp_min(max(cometbft_consensus_validators) - count(up{job=\"gonka-node\"}), 0)";"none";12;76;6;"Validators in the set minus the chain targets this deployment scrapes: how many validators the lab cannot see.";{noValue:"no validator count sampled"};{colorMode:"value"}),
        stat(54;"Stalest collector file";"max(time() - node_textfile_mtime_seconds)";"s";18;76;6;"Age of the oldest textfile a collector wrote. A frozen file keeps looking fresh unless this is watched.";{noValue:"no collector file is exported",thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:300},{color:"red",value:900}]}};{colorMode:"value"}),
        (table(55;"Targets down by job";"sum by (job) (up == bool 0)";0;80;12;7;"Failing targets per scrape job. A job at zero is answering.";{noValue:"no target is configured"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true},renameByName:{job:"Job",Value:"Down"}}}]),
        (table(56;"Collector freshness";"max by (file) (time() - node_textfile_mtime_seconds)";12;80;12;7;"Seconds since each textfile was last written.";{noValue:"no collector file is exported",unit:"s"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true},renameByName:{file:"File",Value:"Age"}}}])
      ];{templating:{list:[{name:"host",label:"Node",type:"query",datasource:ds,definition:"label_values(up{job=~\"host|gonka-node\"},host)",query:{query:"label_values(up{job=~\"host|gonka-node\"},host)",refId:"host"},multi:true,includeAll:true,allValue:".*",current:{selected:true,text:["All"],value:["$__all"]},options:[],refresh:2,regex:"",sort:1,hide:0}]}})
    elif $kind == "chain" then
      def bar($id;$title;$expr;$legend;$unit;$x;$y;$w;$h;$desc;$fc):
        {id:$id,datasource:ds,type:"bargauge",title:$title,description:$desc,gridPos:{h:$h,w:$w,x:$x,y:$y},
         fieldConfig:{defaults:({color:{mode:"thresholds"},thresholds:{mode:"absolute",steps:[{color:"green",value:null}]}} + (if $unit == "" then {} else {unit:$unit} end) + $fc),overrides:[]},
         options:{displayMode:"gradient",orientation:"horizontal",showUnfilled:true,valueMode:"color",namePlacement:"left",reduceOptions:{calcs:["lastNotNull"],fields:"",values:false}},
         targets:[target($expr;$legend) + {instant:true}]};
      def timeline($id;$title;$expr;$legend;$y;$h;$desc;$fc):
        {id:$id,datasource:ds,type:"state-timeline",title:$title,description:$desc,gridPos:{h:$h,w:24,x:0,y:$y},
         fieldConfig:{defaults:({color:{mode:"thresholds"},thresholds:{mode:"absolute",steps:[{color:"green",value:null}]}} + $fc),overrides:[]},
         options:{showValue:"never",mergeValues:true,rowHeight:0.85,legend:{showLegend:false}},targets:[target($expr;$legend)]};
      base("gdc-chain";"Gonka DevNet Chain";"now-6h";[
        row(100;"Epoch and consensus";0),
        stat(1;"Epoch";"max(gdc_chain_epoch_index)";"none";0;1;3;"Latest epoch index from epoch_info, read from public LCD.";{noValue:"the chain poller is not scraped"};{}),
        stat(2;"Current phase";"max(gdc_chain_epoch_phase_code)";"none";3;1;6;phasedesc;{noValue:"the chain poller is not scraped",mappings:phases};{colorMode:"background"}),
        stat(3;"Until next PoC";"max(gdc_chain_epoch_blocks_to_next_poc)";"none";9;1;3;"Blocks from the current height to the next PoC start.";{noValue:"the chain poller is not scraped",unit:"suffix: blocks"};{}),
        stat(4;"Confirmation PoC";"max(gdc_chain_cpoc_active)";"none";12;1;3;"is_confirmation_poc_active from epoch_info.";{noValue:"the chain poller is not scraped",mappings:[{type:"value",options:{"0":{text:"not running",color:"green",index:0},"1":{text:"running",color:"orange",index:1}}}]};{colorMode:"value"}),
        stat(5;"Guardian enhancement";"max(gdc_chain_guardian_enhancement_active)";"none";15;1;3;"On when a guardian has staking tokens different from its epoch group weight.";{noValue:"the chain poller is not scraped",mappings:[{type:"value",options:{"0":{text:"off",color:"green",index:0},"1":{text:"on",color:"orange",index:1}}}]};{colorMode:"value"}),
        stat(6;"Signed previous block";"max(gdc_chain_block_signed_power_ratio)";"percentunit";18;1;3;"Share of voting power in last_commit of the latest block. A block commits with strictly more than 2/3.";{noValue:"the chain poller is not scraped",thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:0.6667},{color:"green",value:0.8}]}};{colorMode:"value"}),
        stat(7;"Validators";"max(gdc_chain_validators_count)";"none";21;1;3;"Validators in the CometBFT set at the latest block.";{noValue:"the chain poller is not scraped"};{}),
        timeline(8;"Cycle phases over time";"max(gdc_chain_epoch_phase_code)";"phase";5;4;phasedesc;{noValue:"the chain poller is not scraped",mappings:phases,thresholds:{mode:"absolute",steps:[{color:"purple",value:null},{color:"blue",value:1},{color:"orange",value:2},{color:"yellow",value:3},{color:"green",value:4}]}}),
        timeline(9;"Confirmation PoC over time";"max(gdc_chain_cpoc_active)";"confirmation PoC";9;3;"When a confirmation PoC event was running.";{noValue:"the chain poller is not scraped",mappings:[{type:"value",options:{"0":{text:"not running",color:"transparent",index:0},"1":{text:"running",color:"orange",index:1}}}],thresholds:{mode:"absolute",steps:[{color:"transparent",value:null},{color:"orange",value:1}]}}),

        row(110;"Voting power";12),
        bar(11;"Consensus voting power";"gdc_chain_validator_power";"{{host}}";"none";0;13;8;9;"Voting power per validator in CometBFT, labelled with the inventory alias.";{noValue:"the chain poller is not scraped"}),
        bar(12;"Voting power share";"gdc_chain_validator_power / scalar(sum(gdc_chain_validator_power))";"{{host}}";"percentunit";8;13;8;9;"Red: more than one third. If this host goes offline, blocks stop.";{noValue:"the chain poller is not scraped",thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:0.3},{color:"red",value:0.3334}]}}),
        bar(13;"Epoch group weight";"gdc_chain_participant_weight";"{{host}} {{participant}}";"none";16;13;8;9;"validation_weights of the current epoch group.";{noValue:"the chain poller is not scraped"}),
        ts(14;"Voting power by host";"sum by (host) (gdc_chain_validator_power)";"{{host}}";"none";0;22;24;8;"The set changes at P+23 and when slashing jails a silent validator.";{noValue:"the chain poller is not scraped",custom:{stacking:{group:"A",mode:"normal"},fillOpacity:40}};["lastNotNull"]),

        row(120;"Validator reliability";30),
        bar(21;"Missed blocks in slashing window";"gdc_chain_validator_missed_in_window";"{{host}} {{validator}}";"none";0;31;8;9;"missed_blocks_counter from slashing signing_infos for bonded or jailed validators. More than 50 in the 100-block window means jail.";{noValue:"the chain poller is not scraped",min:0,max:100,thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:20},{color:"red",value:50}]}}),
        ts(22;"Missed signatures (15m)";"sum by (host) (increase(gdc_chain_validator_missed_blocks_total[15m]))";"{{host}}";"none";8;31;8;9;"Blocks a validator did not sign, counted by the poller from last_commit.";{noValue:"the chain poller is not scraped"};["lastNotNull"]),
        (table(23;"Staking validators";"gdc_chain_validator_staking";16;31;8;9;"Only bonded or jailed validators; old identities that left the set are hidden.";{noValue:"the chain poller is not scraped"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true,__name__:true,job:true,instance:true},renameByName:{host:"Host",operator:"Operator",status:"Status",jailed:"Jail",guardian:"Guardian",Value:"Tokens"}}}]),

        row(130;"Gateways";40),
        (table(31;"Gateways";"label_replace(max by (gateway) (gdc_chain_gateway_devshards{phase=\"active\"}), \"version\", \"$1\", \"gateway\", \".*_V([0-9]+)\") and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";0;41;24;7;"One row per gateway with an active DevShard; gateways without one are hidden. DevShards, hosts and capacity come from the gateway status, traffic, errors and limits from its own metrics over five minutes.";{noValue:"no gateway has an active DevShard"})
          | .targets=[target("label_replace(max by (gateway) (gdc_chain_gateway_devshards{phase=\"active\"}), \"version\", \"$1\", \"gateway\", \".*_V([0-9]+)\") and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"A",format:"table",instant:true}, target("max by (gateway) (gdc_chain_gateway_hosts{state=\"available\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"B",format:"table",instant:true}, target("sum by (gateway) (gdc_chain_gateway_hosts) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"C",format:"table",instant:true}, target("max by (gateway) (gdc_chain_gateway_available_percent) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"D",format:"table",instant:true}, target("sum by (gateway) (rate(devshard_gateway_requests_total[5m])) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"E",format:"table",instant:true}, target("100 * sum by (gateway) (rate(devshard_gateway_requests_total{outcome!=\"success\"}[5m])) / (sum by (gateway) (rate(devshard_gateway_requests_total[5m])) > 0) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"F",format:"table",instant:true}, target("sum by (gateway) (devshard_gateway_inflight_requests) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"G",format:"table",instant:true}, target("max by (gateway) (devshard_gateway_effective_max_concurrent_requests) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"") + {refId:"H",format:"table",instant:true}]
          | .fieldConfig.defaults.noValue="–"
          | .transformations=[{id:"merge",options:{}},{id:"organize",options:{
              excludeByName:{Time:true},
              indexByName:{gateway:0,version:1,"Value #A":2,"Value #B":3,"Value #C":4,"Value #D":5,"Value #E":6,"Value #F":7,"Value #G":8,"Value #H":9},
              renameByName:{gateway:"Gateway",version:"Version","Value #A":"Active DevShards","Value #B":"Hosts available","Value #C":"Hosts","Value #D":"Capacity","Value #E":"Requests/s","Value #F":"Errors","Value #G":"In flight","Value #H":"Limit"}}}]
          | .fieldConfig.overrides=[
              {matcher:{id:"byName",options:"Version"},properties:[{id:"mappings",value:[{type:"value",options:{"6":{text:"v6",index:0},"42":{text:"v4.2",index:1},"41":{text:"v4.1",index:2}}}]}]},
              {matcher:{id:"byName",options:"Capacity"},properties:[{id:"unit",value:"percent"},{id:"decimals",value:0},{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:50},{color:"green",value:90}]}}]},
              {matcher:{id:"byName",options:"Requests/s"},properties:[{id:"decimals",value:2}]},
              {matcher:{id:"byName",options:"Errors"},properties:[{id:"unit",value:"percent"},{id:"decimals",value:1},{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:1},{color:"red",value:5}]}}]}]),
        ts(32;"Gateway capacity";"max by (gateway) (gdc_chain_gateway_available_percent) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"percent";0;48;24;6;"available_percent from the gateway status for gateways with an active DevShard. v4 gateways report their escrow instead and have no capacity line.";{noValue:"no gateway with an active DevShard reports capacity",min:0,max:100};["lastNotNull","min"]),

        row(140;"Public node endpoints";54),
        timeline(41;"External probes";"probe_success{job=\"public-node-endpoints\"}";"{{host}} {{kind}}";55;9;"blackbox HTTPS probes of every node public RPC and LCD, the way a client reaches them.";{noValue:"no public node endpoint is probed",mappings:[{type:"value",options:{"0":{text:"down",color:"red",index:0},"1":{text:"ok",color:"green",index:1}}}],thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"green",value:1}]}})
      ])
    elif $kind == "components" then
      def sel: "job=\"devshard-host\",host=~\"$host\"";
      def nodata: {noValue:"no DevShard host metrics are scraped"};
      def override($name;$props): {matcher:{id:"byName",options:$name},properties:$props};
      def color($name;$c): override($name;[{id:"color",value:{mode:"fixed",fixedColor:$c}}]);
      def tabletarget($expr;$ref): target($expr;"") + {refId:$ref,format:"table",instant:true};
      def spark: .targets[0].instant=false;
      def steps($s): {thresholds:{mode:"absolute",steps:$s}};
      def share: steps([{color:"red",value:null},{color:"orange",value:0.9},{color:"green",value:0.98}]);
      def bad: steps([{color:"green",value:null},{color:"red",value:1}]);
      def stacked: {custom:{stacking:{group:"A",mode:"normal"},fillOpacity:35}};
      def finished: "devshard_request_terminal_total{\(sel),terminal=\"finish_published\"}";
      def executed: "devshard_request_terminal_total{\(sel),terminal=~\"finish_published|execution_no_finish\"}";
      def vfinished($status): "devshard_validation_total{\(sel),stage=\"validation_finished\",status=~\"\($status)\"}";
      base("gdc-components";"Gonka DevNet Components";"now-6h";[
        row(100;"DevShard hosts now";0),
        stat(1;"Hosts up";"sum(up{\(sel)})";"none";0;1;4;"DevShard hosts that answered their last scrape of /devshard/metrics.";{noValue:"no DevShard host is a scrape target"};{colorMode:"value"}),
        (stat(2;"Inferences finished";"sum(rate(\(finished)[5m])) * 60";"opm";4;1;4;"Inferences that published their finish, per minute, summed over the selected hosts.";nodata + {decimals:0};{graphMode:"area"}) | spark),
        (stat(3;"Execution success";"sum(rate(\(finished)[15m])) / sum(rate(\(executed)[15m]))";"percentunit";8;1;4;"Executions that published a finish among all executions over fifteen minutes. Requests where no receipt was expected are not counted.";nodata + share + {decimals:1,min:0,max:1};{colorMode:"value",graphMode:"area"}) | spark),
        (stat(4;"Acquire errors";"sum(rate(devshard_mlnode_attempts_total{\(sel),outcome=\"acquire_err\"}[5m])) * 60";"opm";12;1;4;"Times per minute a host could not acquire an ML node for a call. Such calls never reach a model.";nodata + steps([{color:"green",value:null},{color:"orange",value:1},{color:"red",value:60}]) + {decimals:0};{colorMode:"value",graphMode:"area"}) | spark),
        (stat(5;"Validation success";"sum(rate(\(vfinished("ok"))[15m])) / sum(rate(\(vfinished("ok|error"))[15m]))";"percentunit";16;1;4;"Validations that finished ok among those that finished ok or with an error over fifteen minutes. Deferred validations are not counted.";nodata + share + {decimals:1,min:0,max:1};{colorMode:"value",graphMode:"area"}) | spark),
        stat(6;"Peers not ready";"count(devshard_peer_session_state{\(sel),state!=\"ready\"} == 1) or vector(0)";"none";20;1;4;"Peer sessions that are attaching or unauthenticated. Zero when every peer session is ready.";bad;{colorMode:"value"}),

        row(110;"Hosts";5),
        (table(10;"DevShard hosts";"max by (host) (up{\(sel)})";0;6;24;9;"One row per host: scrape state, finished inferences and execution success, ML node acquire errors and call p95, work in flight, live inferences, owed validations, ready peer sessions, process memory and the Postgres pool.";{noValue:"no DevShard host metrics are scraped"})
          | .targets=[tabletarget("max by (host) (up{\(sel)})";"A"),
              tabletarget("sum by (host) (rate(\(finished)[5m])) * 60";"B"),
              tabletarget("sum by (host) (rate(\(finished)[15m])) / sum by (host) (rate(\(executed)[15m]))";"C"),
              tabletarget("sum by (host) (rate(devshard_mlnode_attempts_total{\(sel),outcome=\"acquire_err\"}[5m])) * 60";"D"),
              tabletarget("histogram_quantile(0.95, sum by (le, host) (rate(devshard_mlnode_call_seconds_bucket{\(sel)}[5m])))";"E"),
              tabletarget("max by (host) (devshardd_lifecycle_inflight_requests{\(sel)})";"F"),
              tabletarget("max by (host) (devshard_memory_live_inferences{\(sel)})";"G"),
              tabletarget("sum by (host) (devshard_validation_owed{\(sel)})";"I"),
              tabletarget("sum by (host) (devshard_peer_session_state{\(sel),state=\"ready\"})";"J"),
              tabletarget("max by (host) (process_resident_memory_bytes{\(sel)})";"K"),
              tabletarget("max by (host) (devshard_postgres_pool_saturated{\(sel)})";"L")]
          | .fieldConfig.defaults.noValue="–"
          | .fieldConfig.defaults.custom.minWidth=80
          | .transformations=[{id:"merge",options:{}},{id:"organize",options:{
              excludeByName:{Time:true},
              indexByName:{host:0,"Value #A":1,"Value #B":2,"Value #C":3,"Value #D":4,"Value #E":5,"Value #F":6,"Value #G":7,"Value #I":8,"Value #J":9,"Value #K":10,"Value #L":11},
              renameByName:{host:"Host","Value #A":"Scrape","Value #B":"Finished /min","Value #C":"Success","Value #D":"Acquire err /min","Value #E":"ML node p95","Value #F":"In flight","Value #G":"Live inferences","Value #I":"Owed validations","Value #J":"Ready peers","Value #K":"Memory","Value #L":"Postgres pool"}}}]
          | .fieldConfig.overrides=[
              override("Scrape";[{id:"mappings",value:[{type:"value",options:{"0":{text:"down",color:"red",index:0},"1":{text:"up",color:"green",index:1}}}]},{id:"custom.cellOptions",value:{type:"color-text"}}]),
              override("Finished /min";[{id:"decimals",value:0}]),
              override("Success";[{id:"unit",value:"percentunit"},{id:"decimals",value:1},{id:"min",value:0},{id:"max",value:1},{id:"custom.cellOptions",value:{type:"gauge",mode:"basic",valueDisplayMode:"text"}},{id:"thresholds",value:share.thresholds}]),
              override("Acquire err /min";[{id:"decimals",value:0},{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:1},{color:"red",value:60}]}}]),
              override("ML node p95";[{id:"unit",value:"s"},{id:"decimals",value:1}]),
              override("Memory";[{id:"unit",value:"bytes"}]),
              override("Postgres pool";[{id:"mappings",value:[{type:"value",options:{"0":{text:"free",color:"green",index:0},"1":{text:"saturated",color:"red",index:1}}}]},{id:"custom.cellOptions",value:{type:"color-text"}}])]),

        row(120;"Inference execution";15),
        ts(11;"Inferences finished per minute";"sum by (host) (rate(\(finished)[5m])) * 60";"{{host}}";"opm";0;16;12;11;"Inferences each host finished and published, per minute.";nodata;["lastNotNull","max"]),
        ts(12;"Execution success";"sum by (host) (rate(\(finished)[15m])) / sum by (host) (rate(\(executed)[15m]))";"{{host}}";"percentunit";8;27;8;8;"Share of executions that published a finish on each host over fifteen minutes. The dashed line is 98 percent.";nodata + {min:0,max:1,thresholds:{mode:"absolute",steps:[{color:"transparent",value:null},{color:"orange",value:0.98}]},custom:{thresholdsStyle:{mode:"dashed"},fillOpacity:0}};["lastNotNull","min"]),
        ts(13;"Requests without a finish";"sum by (reason) (rate(devshard_request_terminal_total{\(sel),terminal!=\"finish_published\"}[5m])) * 60";"{{reason}}";"opm";12;16;12;11;"Requests that ended without a published finish, per minute and reason, over the selected hosts. payload_absent and target_diff_absent expect no receipt; acquire_err, process_response_err, http_5xx and transport_err are executions that failed.";nodata + stacked;["lastNotNull","max"]),
        ts(14;"ML node call failures";"sum by (host, outcome) (rate(devshard_mlnode_attempts_total{\(sel),outcome!=\"ok\"}[5m])) * 60";"{{host}} · {{outcome}}";"opm";0;27;8;8;"Calls from a host to its ML nodes that did not succeed, per minute. acquire_err means the host could not acquire an ML node for the call.";nodata;["lastNotNull","max"]),
        ts(15;"ML node call p95";"histogram_quantile(0.95, sum by (le, host) (rate(devshard_mlnode_call_seconds_bucket{\(sel)}[5m])))";"{{host}}";"s";0;35;24;10;"95th percentile duration of a call from a host to its ML node over five minutes.";nodata;["lastNotNull","max"]),
        ts(16;"Completion tokens per second";"sum by (host) (rate(devshard_mlnode_tokens_sum{\(sel),kind=\"completion\"}[5m]))";"{{host}}";"short";16;27;8;8;"Tokens the ML nodes of each host generated per second.";nodata;["lastNotNull","max"]),

        row(130;"Validation";45),
        (ts(17;"Validation outcomes per minute";"sum by (status) (rate(\(vfinished(".*"))[5m])) * 60";"{{status}}";"opm";0;46;8;9;"Finished validations per minute by status over the selected hosts. deferred is a validation postponed to a later attempt.";nodata + stacked;["lastNotNull","max"])
          | .fieldConfig.overrides=[color("ok";"green"),color("error";"red"),color("deferred";"orange")]),
        (ts(18;"Validation queue";"sum by (host) (devshard_validation_queue_depth{\(sel)})";"{{host}} queued";"short";8;46;8;9;"Validations queued and owed by each host across its escrows. Owed validations that keep growing are work the host falls behind on.";nodata;["lastNotNull","max"])
          | .targets += [{expr:"sum by (host) (devshard_validation_owed{\(sel)})",refId:"B",legendFormat:"{{host}} owed"}]),
        ts(19;"Validation executor faults";"sum by (host, reason) (rate(devshard_validation_executor_fault_total{\(sel)}[5m])) * 60";"{{host}} · {{reason}}";"opm";16;46;8;9;"Validations the executor could not run, per minute and reason.";nodata;["lastNotNull","max"]),

        row(140;"Memory and process";55),
        ts(20;"Live inferences";"max by (host) (devshard_memory_live_inferences{\(sel)})";"{{host}}";"short";0;56;11;9;"Inferences each host keeps in memory across its DevShard sessions. A count that keeps rising under steady load is retained state.";nodata;["lastNotNull","max"]),
        (ts(21;"Executing and validating";"sum by (host) (devshard_memory_executing{\(sel)})";"{{host}} executing";"short";0;86;8;8;"Inferences each host is executing and validating right now.";nodata;["lastNotNull","max"])
          | .targets += [{expr:"sum by (host) (devshard_memory_validating{\(sel)})",refId:"B",legendFormat:"{{host}} validating"}]),
        ts(22;"Mempool entries";"max by (host) (devshard_memory_mempool_entries{\(sel)})";"{{host}}";"short";11;56;13;9;"Entries waiting in the DevShard mempool of each host.";nodata;["lastNotNull","max"]),
        ts(23;"Process memory";"max by (host) (process_resident_memory_bytes{\(sel)})";"{{host}}";"bytes";0;76;24;10;"Resident memory of the DevShard process on each host.";nodata;["lastNotNull","max"]),
        ts(24;"Sessions";"max by (host) (devshard_memory_sessions{\(sel)})";"{{host}}";"short";8;86;8;8;"DevShard sessions open on each host, one per escrow it serves.";nodata;["lastNotNull","max"]),
        ts(25;"Request errors";"sum by (host, operation) (rate(devshardd_request_errors_total{\(sel)}[5m])) * 60";"{{host}} · {{operation}}";"opm";0;65;24;11;"Errors per minute of each DevShard operation on a host.";nodata;["lastNotNull","max"]),

        row(150;"Peers and storage";94),
        (ts(26;"Peer sessions by state";"sum by (state) (devshard_peer_session_state{\(sel)})";"{{state}}";"short";0;95;8;8;"Peer sessions of the selected hosts by state. Every session should be ready.";nodata + stacked;["lastNotNull","max"])
          | .fieldConfig.overrides=[color("ready";"green"),color("attaching";"orange"),color("unauthenticated";"red")]),
        ts(27;"Peer RPC refused";"sum by (host, endpoint, result) (rate(devshard_peer_rpc_requests_total{\(sel),result!=\"ok\"}[5m])) * 60";"{{host}} · {{endpoint}} · {{result}}";"opm";8;95;8;8;"Peer RPC calls a host refused, per minute, by endpoint and result.";nodata;["lastNotNull","max"]),
        ts(28;"Postgres pool saturated";"max by (host) (devshard_postgres_pool_saturated{\(sel)})";"{{host}}";"short";16;95;8;8;"One while the payload Postgres pool of a host has no free connection.";nodata + {min:0,max:1};["lastNotNull","max"])
      ];{templating:{list:[filtervar("host";"Node";"label_values(up{job=\"devshard-host\"},host)"),{name:"filters",label:"Filters",type:"adhoc",datasource:ds,filters:[],baseFilters:[],hide:0}]}})
    elif $kind == "overview" then
      def override($name;$props): {matcher:{id:"byName",options:$name},properties:$props};
      def updown: [{id:"mappings",value:[{type:"value",options:{"0":{text:"down",color:"red",index:0},"1":{text:"up",color:"green",index:1}}}]},{id:"custom.cellOptions",value:{type:"color-text"}}];
      def pctgauge: [{id:"unit",value:"percent"},{id:"decimals",value:0},{id:"min",value:0},{id:"max",value:100},{id:"custom.cellOptions",value:{type:"gauge",mode:"basic",valueDisplayMode:"text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:70},{color:"red",value:90}]}}];
      def tabletarget($expr;$ref): target($expr;"") + {refId:$ref,format:"table",instant:true};
      def hosts: "host=~\"$host\"";
      def gpus: "host=~\"$host\",gpu_name=~\"$gpu\"";
      base("gdc-overview";"Gonka DevNet Community Overview";"now-24h";[
        row(100;"Network now";0),
        stat(1;"Chain nodes online";"sum(max by (host) (up{job=\"gonka-node\"}))";"none";0;1;5;"Chain nodes of the monitoring inventory that answered their last scrape, counted once per host. A validator outside the inventory is not counted.";{noValue:"no chain node is configured"};{}),
        stat(2;"Validators";"max(gdc_chain_validators_count)";"none";0;4;5;"Validators in the CometBFT set at the latest block, read by the chain poller from public RPC.";{noValue:"the chain poller is not scraped"};{}),
        stat(3;"Epoch";"max(gdc_chain_epoch_index)";"none";5;4;3;"Latest epoch index from epoch_info.";{noValue:"the chain poller is not scraped"};{}),
        stat(4;"Current phase";"max(gdc_chain_epoch_phase_code)";"none";5;1;4;phasedesc;{noValue:"the chain poller is not scraped",mappings:phases};{colorMode:"background"}),
        stat(5;"Until next PoC";"max(gdc_chain_epoch_blocks_to_next_poc)";"none";8;4;4;"Blocks from the current height to the next PoC start.";{noValue:"the chain poller is not scraped",unit:"suffix: blocks"};{}),
        stat(6;"Block time";"histogram_quantile(0.50, sum by (le) (rate(cometbft_consensus_block_interval_seconds_bucket[10m])))";"s";9;1;3;"Median block interval over the last ten minutes.";{noValue:"no block-interval histogram in the window",decimals:1};{}),
        stat(7;"Gateways working";"sum(gdc_chain_gateway_working)";"none";12;1;5;"Gateways whose public status reports an active DevShard.";{noValue:"no gateway status URL answers"};{}),
        stat(8;"Endpoints failing";"sum(1 - probe_success{job=~\"public-https|public-node-endpoints\"})";"none";12;4;5;"Public site, API, Grafana, node RPC and LCD probes that failed their last attempt. Zero is measured; empty means nothing is probed.";{noValue:"no public endpoint is probed",thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"red",value:1}]}};{colorMode:"value"}),

        row(110;"Nodes";7),
        (table(11;"Nodes";"max by (host) (up{job=\"host\",\(hosts)})";0;8;24;12;"One row per monitored host. GPU columns follow the GPU model filter; a host without a matching GPU keeps its row with those cells empty. A separate ML host of a validator is its own row.";{noValue:"no host matches the filter"})
          | .targets=[tabletarget("max by (host) (up{job=\"host\",\(hosts)})";"A"),
              tabletarget("max by (host) (up{job=\"gonka-node\",\(hosts)})";"B"),
              tabletarget("scalar(max(cometbft_consensus_height)) - max by (host) (cometbft_consensus_height{\(hosts)})";"C"),
              tabletarget("max by (host) (cometbft_p2p_peers{\(hosts)})";"D"),
              tabletarget("100 - avg by (host) (rate(node_cpu_seconds_total{mode=\"idle\",\(hosts)}[5m])) * 100";"E"),
              tabletarget("max by (host) ((1 - node_memory_MemAvailable_bytes{\(hosts)} / node_memory_MemTotal_bytes{\(hosts)}) * 100)";"F"),
              tabletarget("min by (host) (node_filesystem_avail_bytes{fstype=~\"ext4|xfs|btrfs|zfs\",mountpoint!~\"/boot.*\",\(hosts)} / node_filesystem_size_bytes{fstype=~\"ext4|xfs|btrfs|zfs\",mountpoint!~\"/boot.*\",\(hosts)} * 100)";"G"),
              tabletarget("max by (host, gpu_name) (gdc_nvidia_utilization_percent{\(gpus)})";"H"),
              tabletarget("max by (host, version) (gdc_component_info{component=\"inference-chain\",source=\"runtime\",\(hosts)})";"I"),
              tabletarget("topk by (host) (1, max by (host, city, country) (up{job=\"host\",city!=\"\",\(hosts)}))";"J")]
          | .fieldConfig.defaults.noValue="–"
          | .transformations=[{id:"merge",options:{}},{id:"organize",options:{
              excludeByName:{Time:true,"Value #I":true,"Value #J":true},
              indexByName:{host:0,city:1,country:2,"Value #A":4,"Value #B":5,"Value #C":6,"Value #D":7,"Value #E":8,"Value #F":9,"Value #G":10,gpu_name:11,"Value #H":12,version:13},
              renameByName:{host:"Node",city:"City",country:"Country","Value #A":"Host","Value #B":"Chain","Value #C":"Blocks behind","Value #D":"Peers","Value #E":"CPU","Value #F":"Memory","Value #G":"Disk free",gpu_name:"GPU","Value #H":"GPU busy",version:"Chain version"}}}]
          | .fieldConfig.overrides=[override("Host";updown),override("Chain";updown),
              override("Blocks behind";[{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:3},{color:"red",value:20}]}}]),
              override("CPU";pctgauge),override("Memory";pctgauge),override("GPU busy";pctgauge),
              override("Disk free";[{id:"unit",value:"percent"},{id:"decimals",value:0},{id:"custom.cellOptions",value:{type:"color-text"}},{id:"thresholds",value:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:8},{color:"green",value:15}]}}])]),

        row(120;"Resources";20),
        ts(21;"CPU busy";"100 - avg by (host) (rate(node_cpu_seconds_total{mode=\"idle\",\(hosts)}[5m])) * 100";"{{host}}";"percent";0;21;24;8;"Share of CPU time not idle, averaged over cores.";{noValue:"no host matches the filter",min:0,max:100};["lastNotNull","max"]),
        ts(22;"Memory used";"max by (host) ((1 - node_memory_MemAvailable_bytes{\(hosts)} / node_memory_MemTotal_bytes{\(hosts)}) * 100)";"{{host}}";"percent";0;45;12;8;"Memory in use, excluding reclaimable cache.";{noValue:"no host matches the filter",min:0,max:100};["lastNotNull","max"]),
        ts(23;"Operational disk free";"min by (host) (node_filesystem_avail_bytes{fstype=~\"ext4|xfs|btrfs|zfs\",mountpoint!~\"/boot.*\",\(hosts)} / node_filesystem_size_bytes{fstype=~\"ext4|xfs|btrfs|zfs\",mountpoint!~\"/boot.*\",\(hosts)} * 100)";"{{host}}";"percent";12;37;12;8;"Free space on the fullest real volume of each host. The dashed lines are the 15% and 8% disk alert levels.";{noValue:"no host matches the filter",min:0,max:100,thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:8},{color:"green",value:15}]},custom:{thresholdsStyle:{mode:"dashed"}}};["lastNotNull","min"]),
        ts(24;"GPU utilization";"max by (host, gpu, gpu_name) (gdc_nvidia_utilization_percent{\(gpus)})";"{{host}}/{{gpu}} · {{gpu_name}}";"percent";0;37;12;8;"Per card. Empty when no card matches the node and GPU model filters.";{noValue:"no GPU matches the filters",min:0,max:100};["lastNotNull","max"]),
        ts(25;"GPU memory used";"100 * max by (host, gpu, gpu_name) (gdc_nvidia_memory_used_bytes{\(gpus)}) / max by (host, gpu, gpu_name) (gdc_nvidia_memory_total_bytes{\(gpus)})";"{{host}}/{{gpu}} · {{gpu_name}}";"percent";12;45;12;8;"Share of card memory in use. A loaded model holds its memory while idle.";{noValue:"no GPU matches the filters",min:0,max:100};["lastNotNull","max"]),
        ts(26;"GPU temperature";"max by (host, gpu, gpu_name) (gdc_nvidia_temperature_celsius{\(gpus)})";"{{host}}/{{gpu}} · {{gpu_name}}";"celsius";0;29;24;8;"Card temperature.";{noValue:"no GPU matches the filters"};["lastNotNull","max"]),

        row(130;"GPUs";53),
        (table(31;"GPU cards";"max by (host, gpu, gpu_name) (gdc_nvidia_utilization_percent{\(gpus)})";0;54;24;12;"One row per card on the hosts that report NVIDIA telemetry.";{noValue:"no GPU matches the filters"})
          | .targets=[tabletarget("max by (host, gpu, gpu_name) (gdc_nvidia_utilization_percent{\(gpus)})";"A"),
              tabletarget("max by (host, gpu, gpu_name) (gdc_nvidia_memory_used_bytes{\(gpus)})";"B"),
              tabletarget("max by (host, gpu, gpu_name) (gdc_nvidia_memory_total_bytes{\(gpus)})";"C"),
              tabletarget("max by (host, gpu, gpu_name) (gdc_nvidia_temperature_celsius{\(gpus)})";"D"),
              tabletarget("max by (host, gpu, gpu_name) (gdc_nvidia_power_watts{\(gpus)})";"E")]
          | .fieldConfig.defaults.noValue="–"
          | .transformations=[{id:"merge",options:{}},{id:"organize",options:{
              excludeByName:{Time:true},
              indexByName:{host:0,gpu:1,gpu_name:2,"Value #A":3,"Value #B":4,"Value #C":5,"Value #D":6,"Value #E":7},
              renameByName:{host:"Node",gpu:"Card",gpu_name:"Model","Value #A":"Busy","Value #B":"Memory used","Value #C":"Memory total","Value #D":"Temperature","Value #E":"Power"}}}]
          | .fieldConfig.overrides=[override("Busy";pctgauge),
              override("Memory used";[{id:"unit",value:"bytes"}]),override("Memory total";[{id:"unit",value:"bytes"}]),
              override("Temperature";[{id:"unit",value:"celsius"}]),override("Power";[{id:"unit",value:"watt"}])]),

        row(140;"Consensus";66),
        ts(41;"Height spread";"max(cometbft_consensus_height) - min(cometbft_consensus_height)";"spread";"none";0;67;8;8;"Blocks between the highest and the lowest scraped chain node. It ignores the node filter: it compares the whole monitored set.";{noValue:"no chain sample in the window"};["lastNotNull","max"]),
        ts(42;"Blocks behind";"scalar(max(cometbft_consensus_height)) - max by (host) (cometbft_consensus_height{\(hosts)})";"{{host}}";"none";8;67;8;8;"How far each chain node is behind the highest scraped node.";{noValue:"no chain node matches the filter"};["lastNotNull","max"]),
        ts(43;"P2P peers";"max by (host) (cometbft_p2p_peers{\(hosts)})";"{{host}}";"none";16;67;8;8;"Peer connections per chain node.";{noValue:"no chain node matches the filter"};["lastNotNull","min"])
      ];{templating:{list:[filtervar("host";"Node";"label_values(up{job=\"host\"},host)"),filtervar("gpu";"GPU model";"label_values(gdc_nvidia_utilization_percent{host=~\"$host\"},gpu_name)")]}})
      | .panels |= map(if .type == "stat" then .gridPos.h = 3 else . end)
    else
      base("gdc-inference";"Gonka DevNet Inference";"now-24h";[
        row(200;"Inference now";0),
        stat(51;"Gateway scrapes healthy";"min(up{job=\"gateway\"})";"none";0;1;4;"One only when every configured gateway target answered its latest scrape. The minimum exposes a failed A/B target instead of letting a healthy peer hide it.";{noValue:"no gateway target is configured",mappings:[{type:"value",options:{"0":{text:"Target down",color:"red",index:0},"1":{text:"All up",color:"green",index:1}}}]};{colorMode:"background"}),
        (stat(52;"Requests per minute";"sum by (gateway) (rate(devshard_gateway_requests_total[15m])) * 60";"none";4;1;8;"Chat requests per minute each gateway handled over the last fifteen minutes, every outcome counted.";{noValue:"the gateway was not scraped",decimals:1};{}) | .targets[0].legendFormat="{{gateway}}"),
        (stat(53;"Requests in flight";"sum by (gateway) (devshard_gateway_inflight_requests) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"none";0;5;12;"Requests each active gateway is serving right now. Gateways without an active DevShard are hidden.";{noValue:"no gateway has an active DevShard"};{}) | .targets[0].legendFormat="{{gateway}}"),
        (stat(54;"Success rate (15m)";"100 * sum by (gateway) (rate(devshard_gateway_requests_total{outcome=\"success\"}[15m])) / (sum by (gateway) (rate(devshard_gateway_requests_total[15m])) > 0)";"percent";12;1;8;"Share of requests each gateway answered successfully over fifteen minutes. Empty for a gateway with no requests.";{min:0,max:100,noValue:"no gateway received a request in fifteen minutes",decimals:1,thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:90},{color:"green",value:99}]}};{colorMode:"value"}) | .targets[0].legendFormat="{{gateway}}"),
        (stat(55;"Capacity available";"max by (gateway) (devshard_gateway_capacity_scale) * 100 and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"percent";12;5;12;"Share of baseline capacity each active gateway can route to. Gateways without an active DevShard are hidden.";{min:0,max:100,noValue:"no gateway has an active DevShard",thresholds:{mode:"absolute",steps:[{color:"red",value:null},{color:"orange",value:50},{color:"green",value:90}]}};{colorMode:"value"}) | .targets[0].legendFormat="{{gateway}}"),
        stat(56;"Participant-budget rejections (7d)";"round(sum(increase(devshard_gateway_participant_limit_rejections_total[7d])))";"none";20;1;4;"Attempts refused by a per-participant budget. The build exports no gateway-wide rejection counter, so this is the participant-scoped one.";{noValue:"no rejection counter was scraped"};{}),

        row(210;"Live flow";9),
        ts(61;"Request rate by gateway and outcome";"sum by (gateway,outcome) (rate(devshard_gateway_requests_total[15m]))";"{{gateway}} · {{outcome}}";"reqps";0;10;24;10;"Requests per second by gateway and user-visible outcome. Separate A/B series prevent an active gateway from hiding an idle or failed peer.";{noValue:"the gateway has counted no request yet"};["lastNotNull"]),
        ts(62;"Attempts by gateway and role";"sum by (gateway, role) (rate(devshard_gateway_attempts_started_total[5m]))";"{{gateway}} · {{role}}";"reqps";0;20;24;9;"Attempts each gateway started per second over five minutes. Primary attempts follow requests one to one; secondary ones are extra attempts the gateway starts on another executor.";{noValue:"the gateway has started no attempt yet"};["lastNotNull","max"]),
        ts(65;"Secondary attempts by reason";"sum by (gateway, reason) (rate(devshard_gateway_attempts_started_total{role=~\"secondary|extra\"}[5m])) > 0";"{{gateway}} · {{reason}}";"reqps";0;29;24;9;"Why each gateway started a second attempt: a speedup or A/B sample it planned, or a primary that looked slow, suspicious or failed. Gateways that start none are not drawn.";{noValue:"no gateway started a secondary attempt in five minutes"};["lastNotNull","max"]),
        (stat(57;"Failed requests (15m)";"sum by (reason) (increase(devshard_gateway_requests_total{outcome!=\"success\"}[15m]))";"none";16;38;8;"Requests the gateways failed in fifteen minutes, by reason.";{noValue:"no request failed in fifteen minutes",decimals:0};{}) | .targets[0].legendFormat="{{reason}}" | .gridPos.h = 8),
        (table(63;"Requests by gateway, model and outcome";"sum by (gateway,model,outcome,reason) (devshard_gateway_requests_total)";0;46;24;8;"Every request the gateway has counted, by A/B gateway, model, user-visible outcome and bounded reason.";{noValue:"the gateway has counted no request yet"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true},renameByName:{gateway:"Gateway",model:"Model",outcome:"Outcome",reason:"Reason",Value:"Count"}}}]),
        (table(64;"Current model executors";"max by (participant_key,model) (devshard_gateway_participant_quarantine_state)";0;38;16;8;"Rows appear once a participant is registered with the gateway for a model. An empty table means no executor is tracked at all, not that every executor is idle.";{noValue:"the gateway tracks no executor"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true,Value:true},renameByName:{participant_key:"Executor",model:"Model"}}}]),

        row(220;"Executor latency and quality";54),
        ts(71;"First content latency p50";"histogram_quantile(0.50, sum by (le) (rate(devshard_gateway_participant_first_content_seconds_bucket[6h])))";"p50";"s";0;55;8;7;"Time from gateway send to first content, over a six-hour window. The window is wide because the gateway observes only a few attempts an hour; a narrower one leaves the line undefined between bursts.";{noValue:"no first-content histogram was scraped"};["lastNotNull"]),
        ts(72;"First content latency p95";"histogram_quantile(0.95, sum by (le) (rate(devshard_gateway_participant_first_content_seconds_bucket[6h])))";"p95";"s";8;55;8;7;"Time from gateway send to first content, over a six-hour window. The window is wide because the gateway observes only a few attempts an hour; a narrower one leaves the line undefined between bursts.";{noValue:"no first-content histogram was scraped"};["lastNotNull"]),
        ts(73;"Attempt latency by executor";"sum by (participant_key) (rate(devshard_gateway_participant_total_attempt_seconds_sum[6h])) / sum by (participant_key) (rate(devshard_gateway_participant_total_attempt_seconds_count[6h]))";"{{participant_key}}";"s";16;55;8;7;"Mean attempt duration per executor over a six-hour window. Dividing the totals instead would average every attempt since the gateway started.";{noValue:"no attempt duration histogram was scraped"};["lastNotNull"]),
        (table(74;"Executor wins";"sum by (participant_key,model) (devshard_gateway_user_visible_wins_total)";0;62;8;8;"Requests each executor won for a model. A win is a routed completion the user received.";{noValue:"no executor has won a request yet"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true},renameByName:{participant_key:"Executor",model:"Model",Value:"Wins"}}}]),
        (table(75;"Executor failures";"sum by (participant_key,model,reason) (devshard_gateway_attempt_failures_total)";8;62;8;8;"Attempts that failed per executor, model and reason.";{noValue:"no attempt has failed yet, or the gateway was not scraped"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true},renameByName:{participant_key:"Executor",model:"Model",reason:"Reason",Value:"Failures"}}}]),
        table(76;"Quarantine state";"devshard_gateway_participant_quarantine_state";16;62;8;8;"Quarantine state exists per participant and model. An empty table means the gateway is tracking no participant, which is not the same as every participant being healthy.";{noValue:"the gateway tracks no participant"}),

        row(230;"Capacity and escrow routing";70),
        (ts(81;"Effective and baseline weight";"devshard_gateway_capacity_total_weight";"{{gateway}} effective";"none";0;71;8;7;"Both weights carry the same labels, so joining them with or showed only the effective one.";{noValue:"the gateway published no capacity weight"};["lastNotNull"])
          | .targets += [{expr:"devshard_gateway_capacity_baseline_weight",refId:"B",legendFormat:"{{gateway}} baseline"}]),
        ts(82;"Escrow effective weight";"sum(devshard_gateway_escrow_weight)";"all escrows";"none";8;71;8;7;"Summed across escrows: the identifier churns with every escrow, so one line per escrow filled the legend with hundreds of rows.";{noValue:"no escrow is active"};["lastNotNull"]),
        ts(83;"Blocked participants";"max by (model) (devshard_gateway_escrow_blocked_participants)";"{{model}}";"none";16;71;8;7;"A zero is a measured escrow blocking nobody. Empty means no escrow is active.";{noValue:"no escrow is active"};["lastNotNull"]),
        ts(84;"Participant-budget rejection rate";"sum by (participant_key,scope) (rate(devshard_gateway_participant_limit_rejections_total[5m]))";"{{participant_key}} · {{scope}}";"reqps";0;78;12;8;"The build exports no gateway-wide rejection counter, so the three-way or chain only ever showed the participant-scoped one.";{noValue:"no rejection counter was scraped"};["lastNotNull"]),
        ts(85;"Hidden participant failures";"sum by (model) (devshard_gateway_user_requests_with_hidden_failure_total)";"{{model}}";"none";12;78;12;8;"Requests the user received although an executor failed behind them. A zero is a measured clean path.";{noValue:"no request has hidden a failure yet, or the gateway was not scraped"};["lastNotNull"]),

        row(240;"Data passport";86),
        stat(91;"Oldest gateway scrape age";"(time() - min(timestamp(up{job=\"gateway\"}) and up{job=\"gateway\"} == 1)) and on() (min(up{job=\"gateway\"}) == 1)";"s";0;87;4;"Seconds since the oldest successful A/B gateway scrape. It is empty when any target is down, rather than letting a newer peer hide a failed scrape.";{noValue:"a gateway target is down or has no successful scrape",thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:60},{color:"red",value:300}]}};{colorMode:"value"}),
        stat(92;"Executors tracked";"max(devshard_gateway_participants_tracked)";"none";4;87;4;"Executors the gateway is currently tracking, as the gateway itself reports.";{noValue:"the gateway is not scraped"};{}),
        stat(93;"Models observed";"count(count by (model) (devshard_gateway_requests_total))";"none";8;87;4;"Models the gateway has counted a request for.";{noValue:"the gateway has counted no request yet"};{}),
        stat(94;"Transport errors (7d)";"round(sum(increase(devshard_gateway_participant_transport_errors_total[7d])))";"none";12;87;4;"Executor transport failures in the window.";{noValue:"no transport error counter was scraped"};{}),
        stat(95;"Telegram exporter age";"time() - max(timestamp(gdc_telegram_bot_up{job=\"telegram-consumer\"}))";"s";16;87;4;"Seconds since Prometheus last scraped the bot exporter. The whole Telegram row below is gated on that scrape.";{noValue:"the bot exporter is not scraped",thresholds:{mode:"absolute",steps:[{color:"green",value:null},{color:"orange",value:60},{color:"red",value:300}]}};{colorMode:"value"}),
        stat(96;"Active gateways";"count(max by (gateway) (gdc_chain_gateway_working) == 1)";"none";20;87;4;"Gateways that report an active DevShard in their status.";{noValue:"no gateway reports an active DevShard"};{}),

        row(250;"Telegram inference consumer";91),
        stat(101;"Unique users";"sum(gdc_telegram_bot_unique_users{job=\"telegram-consumer\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";0;92;4;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        stat(102;"Premium users";"sum(gdc_telegram_bot_unique_users{job=\"telegram-consumer\",premium=\"true\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";4;92;4;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        stat(103;"Conversations";"sum(gdc_telegram_bot_conversations{job=\"telegram-consumer\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";8;92;4;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        stat(104;"Interactions";"sum(gdc_telegram_bot_interactions_total{job=\"telegram-consumer\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";12;92;4;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        stat(105;"Input tokens";"sum(gdc_telegram_bot_tokens_total{job=\"telegram-consumer\",direction=\"input\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";16;92;4;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        stat(106;"Output tokens";"sum(gdc_telegram_bot_tokens_total{job=\"telegram-consumer\",direction=\"output\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";20;92;4;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        ts(111;"Interaction rate by outcome and Premium state";"sum by (outcome,premium) (rate(gdc_telegram_bot_interactions_total{job=\"telegram-consumer\"}[15m])) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"{{outcome}} · premium={{premium}}";"reqps";0;96;12;8;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};["lastNotNull"]),
        ts(112;"Inference request rate by outcome";"sum by (outcome) (rate(gdc_telegram_bot_inference_requests_total{job=\"telegram-consumer\"}[15m])) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"{{outcome}}";"reqps";12;96;12;8;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};["lastNotNull"]),
        stat(113;"Time since last successful bot inference";"(time() - max(gdc_telegram_bot_last_success_timestamp_seconds{job=\"telegram-consumer\"})) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"s";0;104;8;"Zero would have read as a success just now, the most reassuring possible value for a consumer that never answered. Empty now means the bot exporter is not scraped.";{noValue:"the bot exporter is not scraped"};{colorMode:"value"}),
        stat(114;"Responses without token usage";"sum(gdc_telegram_bot_usage_missing_total{job=\"telegram-consumer\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";8;104;8;"Read from the bot exporter and shown only while Prometheus scrapes it. The metrics file the bot also writes changes only on activity, so its age is not a liveness signal.";{noValue:"the bot exporter is not scraped"};{}),
        stat(115;"Consumer process";"max(gdc_telegram_bot_up{job=\"telegram-consumer\"}) and on() (max(up{job=\"telegram-consumer\"}) == 1)";"none";16;104;8;"Running only while Prometheus scrapes the bot exporter. A stopped bot drops out of the scrape instead of keeping its last state.";{noValue:"the bot exporter is not scraped; the state of the bot is unknown",mappings:[{type:"value",options:{"0":{text:"Stopped",color:"red",index:0},"1":{text:"Running",color:"green",index:1}}}]};{colorMode:"background"}),
        row(260;"Escrow spend";108),
        (stat(121;"Nonces per inference";"sum by (gateway) (devshard_accounting_assigned_nonces) / sum by (gateway) (devshard_accounting_disposition{disposition=\"finished_used\"})";"none";0;109;8;"Nonces each gateway assigned in its current escrow per nonce that produced a used result. Both counts restart when the gateway rotates its escrow.";{noValue:"no gateway reports nonce accounting",decimals:2};{}) | .targets[0].legendFormat="{{gateway}}"),
        (stat(122;"Burned nonces";"sum by (gateway) (devshard_accounting_disposition{disposition=\"ghost\"}) or 0 * sum by (gateway) (devshard_accounting_assigned_nonces)";"none";0;113;8;"Nonces committed in the current escrow and never sent to a host: paid, with no inference behind them. The count restarts at rotation.";{noValue:"no gateway reports nonce accounting"};{}) | .targets[0].legendFormat="{{gateway}}"),
        stat(123;"Cost per nonce";"(sum(gdc_chain_escrow_payout_ngonka) + sum(gdc_chain_escrow_fees_ngonka)) / sum(gdc_chain_escrow_settled_nonces)";"none";8;109;8;"Host payout plus nonce fees divided by the nonces paid, over every settled escrow on the chain.";{noValue:"no escrow has been settled yet",unit:"suffix: ngonka",decimals:0};{}),
        (stat(124;"Cost per inference";"(sum by (gateway) (devshard_accounting_assigned_nonces) / sum by (gateway) (devshard_accounting_disposition{disposition=\"finished_used\"})) * on() group_left() ((sum(gdc_chain_escrow_payout_ngonka) + sum(gdc_chain_escrow_fees_ngonka)) / sum(gdc_chain_escrow_settled_nonces))";"none";8;113;8;"Cost per nonce times the nonces each gateway spends per used result. An estimate that follows the current escrow of each gateway.";{noValue:"no escrow has been settled yet, or no gateway reports nonce accounting",unit:"suffix: ngonka",decimals:0};{}) | .targets[0].legendFormat="{{gateway}}"),
        (stat(125;"Escrows created (24h)";"sum by (creator) (gdc_chain_escrows_created_recent{window=\"24h\"})";"none";16;109;8;"Escrows each creator wallet opened in the last day, by block time.";{noValue:"the chain poller reports no escrow creation"};{}) | .targets[0].legendFormat="{{creator}}"),
        (stat(126;"Unsettled escrows";"sum by (creator) (gdc_chain_escrows_open)";"none";16;113;8;"Escrows created and not settled. Their amount stays held until settlement.";{noValue:"the chain poller reports no escrow creation"};{}) | .targets[0].legendFormat="{{creator}}"),
        ts(127;"Escrows created per hour";"sum by (creator) (gdc_chain_escrows_created_recent{window=\"1h\"})";"{{creator}}";"none";0;117;8;8;"Escrows each creator wallet opened in the past hour, by block time. A gateway opens a new escrow when the current one nears max_nonce or its epoch ends.";{noValue:"the chain poller reports no escrow creation"};["lastNotNull","max"]),
        ts(128;"Held in unsettled escrows";"gdc_chain_escrow_locked_ngonka";"{{creator}}";"short";8;117;8;8;"Amount of the escrows not yet settled per creator wallet, in ngonka.";{noValue:"the chain poller reports no unsettled escrow"};["lastNotNull"]),
        ts(129;"Creator wallet balance";"gdc_chain_escrow_creator_balance_ngonka";"{{creator}}";"short";16;117;8;8;"ngonka left in each wallet allowed to create escrows. Each new escrow takes its amount from here.";{noValue:"the chain poller reports no creator wallet"};["lastNotNull","min"]),
        row(270;"Gateway memory and cache";125),
        ts(131;"Heap in use";"max by (gateway) (go_memstats_heap_inuse_bytes{job=\"gateway\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"bytes";0;126;8;8;"Go heap spans in use by each gateway. Under steady load it should level off; a line that keeps rising points at retained state.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(132;"Heap allocated";"max by (gateway) (go_memstats_heap_alloc_bytes{job=\"gateway\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"bytes";8;126;8;8;"Bytes of live heap objects; it drops after each garbage collection.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(133;"Resident memory";"max by (gateway) (process_resident_memory_bytes{job=\"gateway\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"bytes";16;126;8;8;"Memory the gateway process holds in RAM, as the operating system sees it.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(134;"Heap held, not returned";"max by (gateway) (go_memstats_heap_idle_bytes{job=\"gateway\"} - go_memstats_heap_released_bytes{job=\"gateway\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"bytes";0;134;8;8;"Idle heap the Go runtime keeps instead of returning it to the system: room for the next burst, not leaked memory.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(135;"Heap objects";"max by (gateway) (go_memstats_heap_objects{job=\"gateway\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"short";8;134;8;8;"Live objects on the heap. Growth with a flat request rate means objects are kept between requests.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(136;"Goroutines";"max by (gateway) (go_goroutines{job=\"gateway\"}) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"short";16;134;8;8;"Goroutines per gateway. A count that keeps rising with steady load is a leak candidate.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(137;"Garbage collections per minute";"max by (gateway) (rate(go_gc_duration_seconds_count{job=\"gateway\"}[5m])) * 60 and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"short";0;142;8;8;"How often each gateway runs garbage collection.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(138;"Requests in flight";"sum by (gateway) (devshard_gateway_inflight_requests) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"short";8;142;8;8;"Requests each gateway is serving, to compare with its memory.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(139;"Requests per second";"sum by (gateway) (rate(devshard_gateway_requests_total[5m])) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}}";"reqps";16;142;8;8;"Requests each gateway handled per second over five minutes.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"]),
        ts(140;"Response cache";"sum by (gateway, result) (rate(devshard_gateway_chat_cache_total[5m])) and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)";"{{gateway}} · {{result}}";"ops";0;150;24;8;"Cache outcomes per second: hit is served from cache, stored is a new entry, skipped_* is not cached. Only v6 gateways export these outcomes, and no gateway exports a cache size.";{noValue:"no gateway with an active DevShard exports this metric"};["lastNotNull","max"])
      ])
    end
  ' >"$output"
}

mkdir -p "$HERE/dashboards" "$PUBLIC"
render network "$HERE/dashboards/gdc-network.json"
render inference "$HERE/dashboards/gdc-inference.json"
render overview "$HERE/dashboards/gdc-overview.json"
render chain "$HERE/dashboards/gdc-chain.json"
render components "$HERE/dashboards/gdc-components.json"
for board in gdc-network gdc-inference gdc-overview gdc-chain gdc-components; do
  install -m 0644 "$HERE/dashboards/$board.json" "$PUBLIC/$board.json"
done
jq -e '.uid == "gdc-network" and (.panels | length >= 20)' "$HERE/dashboards/gdc-network.json" >/dev/null
jq -e '.uid == "gdc-inference" and (.panels | length >= 20)' "$HERE/dashboards/gdc-inference.json" >/dev/null
jq -e '.uid == "gdc-overview" and (.panels | length >= 20) and (.templating.list | map(.name) == ["host", "gpu"])' "$HERE/dashboards/gdc-overview.json" >/dev/null
jq -e '.uid == "gdc-chain" and (.panels | length >= 20)' "$HERE/dashboards/gdc-chain.json" >/dev/null
jq -e '.uid == "gdc-components" and (.panels | length >= 10) and (.templating.list | map(.name) == ["host", "filters"])' "$HERE/dashboards/gdc-components.json" >/dev/null
printf 'READY generated gdc-network, gdc-inference, gdc-overview, gdc-chain and gdc-components dashboards\n'
