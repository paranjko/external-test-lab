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
    def stat($id;$title;$expr;$unit;$x;$y;$w):
      {id:$id,datasource:ds,type:"stat",title:$title,gridPos:{h:4,w:$w,x:$x,y:$y},
       fieldConfig:{defaults:({color:{mode:"thresholds"},thresholds:{mode:"absolute",steps:[{color:"green",value:null}]}} +
         (if $unit == "" then {} else {unit:$unit} end)),overrides:[]},
       options:{colorMode:"none",graphMode:"none",justifyMode:"auto",orientation:"auto",reduceOptions:{calcs:["lastNotNull"],fields:"",values:false},textMode:"auto",wideLayout:true},
       targets:[target($expr;"") + {instant:true}]};
    def ts($id;$title;$expr;$legend;$unit;$x;$y;$w;$h):
      {id:$id,datasource:ds,type:"timeseries",title:$title,gridPos:{h:$h,w:$w,x:$x,y:$y},
       fieldConfig:{defaults:({color:{mode:"palette-classic"},custom:{axisCenteredZero:false,axisColorMode:"text",axisLabel:"",axisPlacement:"auto",drawStyle:"line",fillOpacity:12,gradientMode:"opacity",hideFrom:{legend:false,tooltip:false,viz:false},lineInterpolation:"smooth",lineWidth:2,pointSize:4,scaleDistribution:{type:"linear"},showPoints:"never",spanNulls:true,stacking:{group:"A",mode:"none"},thresholdsStyle:{mode:"off"}},thresholds:{mode:"absolute",steps:[{color:"green",value:null}]}} +
         (if $unit == "" then {} else {unit:$unit} end)),overrides:[]},
       options:{legend:{calcs:["lastNotNull"],displayMode:"table",placement:"bottom",showLegend:true},tooltip:{mode:"multi",sort:"desc"}},
       targets:[target($expr;$legend)]};
    def table($id;$title;$expr;$x;$y;$w;$h):
      {id:$id,datasource:ds,type:"table",title:$title,gridPos:{h:$h,w:$w,x:$x,y:$y},
       fieldConfig:{defaults:{custom:{align:"auto",cellOptions:{type:"auto"},inspect:false}},overrides:[]},
       options:{cellHeight:"sm",footer:{countRows:false,fields:"",reducer:["sum"],show:false},showHeader:true},
       targets:[target($expr;"") + {format:"table",instant:true}]};
    def row($id;$title;$y): {id:$id,type:"row",title:$title,collapsed:false,gridPos:{h:1,w:24,x:0,y:$y},panels:[]};
    def textpanel($id;$title;$markdown;$y):
      {id:$id,type:"text",title:$title,gridPos:{h:5,w:24,x:0,y:$y},options:{content:$markdown,mode:"markdown"}};
    def base($uid;$title;$from;$panels):
      {annotations:{list:[]},editable:false,fiscalYearStartMonth:0,graphTooltip:1,id:null,
       links:[{asDropdown:true,icon:"dashboard",includeVars:false,keepTime:true,tags:["gdc"],targetBlank:false,title:"Community DevNet dashboards",type:"dashboards"}],
       liveNow:true,panels:$panels,refresh:"15s",schemaVersion:41,tags:["gonka","gdc"],templating:{list:[]},time:{from:$from,to:"now"},timepicker:{refresh_intervals:["5s","10s","15s","30s","1m","5m"]},timezone:"utc",title:$title,uid:$uid,version:1};

    if $kind == "network" then
      base("gdc-network";"Gonka DevNet Network";"now-24h";[
        row(100;"Network now";0),
        stat(1;"Chain height";"max(cometbft_consensus_height)";"none";0;1;4),
        stat(2;"Nodes online";"sum(up{job=\"gonka-node\"} == 1)";"none";4;1;4),
        stat(3;"Nodes down";"count(up{job=\"gonka-node\"} == 0) or vector(0)";"none";8;1;4),
        stat(4;"Validators";"max(cometbft_consensus_validators)";"none";12;1;4),
        stat(5;"P2P peers";"sum(cometbft_p2p_peers)";"none";16;1;4),
        stat(6;"Sample age";"time() - max(timestamp(cometbft_consensus_height))";"s";20;1;4),

        row(110;"Chain vitals and consensus";5),
        ts(11;"Height by node";"cometbft_consensus_height";"{{host}}";"none";0;6;12;8),
        ts(12;"Block interval p50";"histogram_quantile(0.50, sum by (le) (rate(cometbft_consensus_block_interval_seconds_bucket[10m]))) or vector(0)";"p50";"s";12;6;12;8),
        ts(13;"Transactions per second";"sum(rate(cometbft_consensus_total_txs[5m])) or vector(0)";"transactions";"ops";0;14;8;7),
        ts(14;"Consensus rounds";"max by (host) (cometbft_consensus_rounds)";"{{host}}";"none";8;14;8;7),
        ts(15;"Mempool transactions";"max by (host) (cometbft_mempool_size)";"{{host}}";"none";16;14;8;7),

        row(120;"Validators and signing";21),
        ts(21;"Voting power signed";"min by (host) (cometbft_consensus_round_voting_power_percent)";"{{host}}";"percent";0;22;8;7),
        ts(22;"Missing validators";"max by (host) (cometbft_consensus_missing_validators)";"{{host}}";"none";8;22;8;7),
        ts(23;"Missed blocks by validator";"max by (host) (cometbft_consensus_validator_missed_blocks) or vector(0)";"{{host}}";"none";16;22;8;7),

        row(130;"Hosts and accelerators";29),
        ts(31;"CPU busy";"100 - avg by(host)(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100";"{{host}}";"percent";0;30;8;7),
        ts(32;"Memory used";"(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100";"{{host}}";"percent";8;30;8;7),
        ts(33;"Operational disk free";"max by (host) (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\",mountpoint=~\"/|/srv/dai|/sdb-disk\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\",mountpoint=~\"/|/srv/dai|/sdb-disk\"} * 100)";"{{host}}";"percent";16;30;8;7),
        ts(34;"GPU utilization";"gdc_nvidia_utilization_percent";"{{host}} · {{gpu_name}}";"percent";0;37;8;7),
        ts(35;"GPU memory used";"gdc_nvidia_memory_used_bytes";"{{host}} · {{gpu_name}}";"bytes";8;37;8;7),
        ts(36;"GPU temperature";"gdc_nvidia_temperature_celsius";"{{host}} · {{gpu_name}}";"celsius";16;37;8;7),

        row(140;"Host inventory";44),
        table(41;"Locations and scrape state";"up{job=\"host\",city!=\"\"}";0;45;12;8),
        table(42;"Software inventory";"node_uname_info";12;45;12;8),
        textpanel(49;"Data contract";"This board adapts the structure of **Gonka Network Pulse v4** to the Community DevNet metrics that are actually collected. It uses live CometBFT, host, GPU and blackbox-exporter series. Archive-only epoch economics, rewards and historical transaction decoding are intentionally not fabricated.";53)
      ])
    else
      base("gdc-inference";"Gonka DevNet Inference";"now-7d";[
        row(200;"Inference now";0),
        stat(51;"Gateway scrape";"max(up{job=\"gateway\"})";"none";0;1;4),
        stat(52;"Requests served";"sum(devshard_gateway_requests_total) or vector(0)";"none";4;1;4),
        stat(53;"Requests in flight";"sum(devshard_gateway_inflight_requests) or vector(0)";"none";8;1;4),
        stat(54;"Input tokens in flight";"sum(devshard_gateway_inflight_input_tokens) or vector(0)";"none";12;1;4),
        stat(55;"Capacity available";"max(devshard_gateway_capacity_scale) * 100 or vector(0)";"percent";16;1;4),
        stat(56;"Limit rejections";"sum(devshard_gateway_limit_rejections_total) or vector(0)";"none";20;1;4),

        row(210;"Live flow";5),
        ts(61;"Request rate by outcome";"sum by (outcome) (rate(devshard_gateway_requests_total[5m])) or vector(0)";"{{outcome}}";"reqps";0;6;12;8),
        ts(62;"Attempts started by role";"sum by (role) (rate(devshard_gateway_attempts_started_total[5m])) or vector(0)";"{{role}}";"reqps";12;6;12;8),
        table(63;"Requests by outcome";"sum by (outcome,reason) (devshard_gateway_requests_total)";0;14;12;8),
        table(64;"Visible wins by executor";"sum by (participant_key,model) (devshard_gateway_user_visible_wins_total)";12;14;12;8),

        row(220;"Executor latency and quality";22),
        ts(71;"First content latency p50";"histogram_quantile(0.50, sum by (le) (rate(devshard_gateway_participant_first_content_seconds_bucket[15m]))) or vector(0)";"p50";"s";0;23;8;7),
        ts(72;"First content latency p95";"histogram_quantile(0.95, sum by (le) (rate(devshard_gateway_participant_first_content_seconds_bucket[15m]))) or vector(0)";"p95";"s";8;23;8;7),
        ts(73;"Attempt latency by executor";"sum by (participant_key) (devshard_gateway_participant_total_attempt_seconds_sum) / sum by (participant_key) (devshard_gateway_participant_total_attempt_seconds_count)";"{{participant_key}}";"s";16;23;8;7),
        table(74;"Executor wins";"sum by (participant_key,model) (devshard_gateway_user_visible_wins_total)";0;30;8;8),
        table(75;"Executor failures";"sum by (participant_key,model,reason) (devshard_gateway_attempt_failures_total)";8;30;8;8),
        table(76;"Quarantine state";"devshard_gateway_participant_quarantine_state";16;30;8;8),

        row(230;"Capacity and escrow routing";38),
        ts(81;"Effective and baseline weight";"devshard_gateway_capacity_total_weight or devshard_gateway_capacity_baseline_weight";"weight";"none";0;39;8;7),
        ts(82;"Escrow effective weight";"devshard_gateway_escrow_weight";"escrow {{devshard_id}}";"none";8;39;8;7),
        ts(83;"Blocked participants";"devshard_gateway_escrow_blocked_participants";"escrow {{devshard_id}}";"none";16;39;8;7),
        ts(84;"Gateway and participant rejections";"sum by (reason) (rate(devshard_gateway_limit_rejections_total[5m])) or sum by (scope) (rate(devshard_gateway_participant_limit_rejections_total[5m])) or vector(0)";"{{reason}}{{scope}}";"reqps";0;46;12;8),
        ts(85;"Hidden participant failures";"sum by (model) (devshard_gateway_user_requests_with_hidden_failure_total) or vector(0)";"{{model}}";"none";12;46;12;8),

        row(240;"Data passport";54),
        stat(91;"Gateway sample age";"time() - max(timestamp(devshard_gateway_requests_total))";"s";0;55;6),
        stat(92;"Tracked executors";"count(count by (participant_key) (devshard_gateway_attempts_started_total)) or vector(0)";"none";6;55;6),
        stat(93;"Models observed";"count(count by (model) (devshard_gateway_requests_total)) or vector(0)";"none";12;55;6),
        stat(94;"Transport errors";"sum(devshard_gateway_participant_transport_errors_total) or vector(0)";"none";18;55;6),
        textpanel(99;"Data contract";"This board adapts **Gonka: Inference & Devshards Observatory** to live Community DevNet gateway metrics. Counters start when the gateway process starts and are retained by Prometheus for 30 days. Per-request token archives, GNK notional value and archive-node SQL are not available, so the board does not invent those panels.";59)
      ])
    end
  ' >"$output"
}

mkdir -p "$HERE/dashboards" "$PUBLIC"
render network "$HERE/dashboards/gdc-network.json"
render inference "$HERE/dashboards/gdc-inference.json"
install -m 0644 "$HERE/dashboards/gdc-network.json" "$PUBLIC/gdc-network.json"
install -m 0644 "$HERE/dashboards/gdc-inference.json" "$PUBLIC/gdc-inference.json"
jq -e '.uid == "gdc-network" and (.panels | length >= 20)' "$HERE/dashboards/gdc-network.json" >/dev/null
jq -e '.uid == "gdc-inference" and (.panels | length >= 20)' "$HERE/dashboards/gdc-inference.json" >/dev/null
printf 'READY generated gdc-network and gdc-inference dashboards\n'
