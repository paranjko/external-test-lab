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
    def textpanel($id;$title;$markdown;$y):
      {id:$id,type:"text",title:$title,gridPos:{h:5,w:24,x:0,y:$y},options:{content:$markdown,mode:"markdown"}};
    # $extra shallow-replaces top-level board keys; it does not deep-merge.
    def base($uid;$title;$from;$panels;$extra):
      {annotations:{list:[]},editable:false,fiscalYearStartMonth:0,graphTooltip:1,id:null,
       links:[{asDropdown:true,icon:"dashboard",includeVars:false,keepTime:true,tags:["gdc"],targetBlank:false,title:"Community DevNet dashboards",type:"dashboards"}],
       liveNow:true,panels:$panels,refresh:"15s",schemaVersion:41,tags:["gonka","gdc"],templating:{list:[]},time:{from:$from,to:"now"},timepicker:{refresh_intervals:["5s","10s","15s","30s","1m","5m"]},timezone:"utc",title:$title,uid:$uid,version:1} + $extra;
    def base($uid;$title;$from;$panels): base($uid;$title;$from;$panels;{});

    if $kind == "network" then
      base("gdc-network";"Gonka DevNet Network";"now-24h";[
        row(100;"Network now";0),
        stat(1;"Chain height";"max(cometbft_consensus_height)";"none";0;1;4),
        stat(2;"Nodes online";"sum(up{job=\"gonka-node\"} == 1)";"none";4;1;4),
        stat(3;"Nodes down";"count(up{job=\"gonka-node\"} == 0) or vector(0)";"none";8;1;4),
        stat(4;"Validators";"max(cometbft_consensus_validators)";"none";12;1;4),
        stat(5;"P2P peers";"sum(cometbft_p2p_peers) or vector(0)";"none";16;1;4),
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
        ts(34;"GPU utilization";"gdc_nvidia_utilization_percent";"{{host}} · {{gpu_name}}";"percent";0;37;8;7;"Empty when no accelerator host reports to the collector. A validator with no attached GPU, or a GPU host that is not a scrape target, contributes no series here rather than a zero.";{noValue:"no accelerator host is reporting"};["lastNotNull"]),
        ts(35;"GPU memory used";"gdc_nvidia_memory_used_bytes";"{{host}} · {{gpu_name}}";"bytes";8;37;8;7;"Empty when no accelerator host reports to the collector. A validator with no attached GPU, or a GPU host that is not a scrape target, contributes no series here rather than a zero.";{noValue:"no accelerator host is reporting"};["lastNotNull"]),
        ts(36;"GPU temperature";"gdc_nvidia_temperature_celsius";"{{host}} · {{gpu_name}}";"celsius";16;37;8;7;"Empty when no accelerator host reports to the collector. A validator with no attached GPU, or a GPU host that is not a scrape target, contributes no series here rather than a zero.";{noValue:"no accelerator host is reporting"};["lastNotNull"]),

        row(140;"Host inventory";44),
        table(41;"Locations and scrape state";"up{job=\"host\",city!=\"\"}";0;45;12;8;"Rows appear only for scrape targets whose location was resolved. A Host that is absent from the monitoring inventory, or whose location lookup failed, is missing from this table rather than listed without a location.";{noValue:"no target has a resolved location"}),
        (table(42;"Software inventory";"gdc_component_info";12;45;12;8;"Rows appear once the version collector has written its first inventory on a Host. An empty table means the collector has not reported yet, not that the Hosts run no software.";{noValue:"no Host has reported its software inventory"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true,Value:true,__name__:true,job:true,instance:true},renameByName:{host:"Host",component:"Component",component_instance:"Instance",version:"Version",commit:"Commit",image:"Image",source:"Source"}}}]),
        textpanel(49;"Data contract";"This board adapts the structure of **Gonka Network Pulse v4** to the Community DevNet metrics that are actually collected. It uses live CometBFT, host, GPU and blackbox-exporter series. Archive-only epoch economics, rewards and historical transaction decoding are intentionally not fabricated.";53)
      ])
    else
      base("gdc-inference";"Gonka DevNet Inference";"now-7d";[
        row(200;"Inference now";0),
        stat(51;"Gateway scrape";"max(up{job=\"gateway\"})";"none";0;1;4),
        stat(52;"Requests served";"sum(devshard_gateway_requests_total) or vector(0)";"none";4;1;4),
        stat(53;"Requests in flight";"sum(devshard_gateway_inflight_requests) or vector(0)";"none";8;1;4),
        stat(54;"Traffic ready";"max(gdc_gateway_readiness_state{state=\"TRAFFIC_READY\"}) or vector(0)";"none";12;1;4),
        stat(55;"Capacity available";"max(devshard_gateway_capacity_scale) * 100 or vector(0)";"percent";16;1;4),
        stat(56;"Rate-limited requests since restart";"sum(devshard_gateway_limit_rejections_total) or vector(0)";"none";20;1;4),

        row(210;"Live flow";5),
        ts(61;"Request rate by outcome";"sum by (outcome) (rate(devshard_gateway_requests_total[5m])) or vector(0)";"{{outcome}}";"reqps";0;6;12;8),
        ts(62;"Attempts started by role";"sum by (role) (rate(devshard_gateway_attempts_started_total[5m])) or vector(0)";"{{role}}";"reqps";12;6;12;8),
        table(63;"Requests by outcome";"sum by (outcome,reason) (devshard_gateway_requests_total)";0;14;12;8;"Empty until the gateway records a routed request. This build exports no devshard_gateway_requests_total series at all, so the table stays empty rather than showing a zero that would claim requests were counted and classified.";{noValue:"this gateway build exports no request counter"}),
        (table(64;"Current model executors";"max by (participant_key,model) (devshard_gateway_participant_quarantine_state)";12;14;12;8;"Rows appear once a participant is registered with the gateway for a model. An empty table means no executor is tracked at all, not that every executor is idle.";{noValue:"the gateway tracks no executor"})
          | .transformations=[{id:"organize",options:{excludeByName:{Time:true,Value:true},renameByName:{participant_key:"Executor",model:"Model"}}}]),

        row(220;"Executor latency and quality";22),
        ts(71;"First content latency p50";"histogram_quantile(0.50, sum by (le) (rate(devshard_gateway_participant_first_content_seconds_bucket[15m]))) or vector(0)";"p50";"s";0;23;8;7),
        ts(72;"First content latency p95";"histogram_quantile(0.95, sum by (le) (rate(devshard_gateway_participant_first_content_seconds_bucket[15m]))) or vector(0)";"p95";"s";8;23;8;7),
        ts(73;"Attempt latency by executor";"sum by (participant_key) (devshard_gateway_participant_total_attempt_seconds_sum) / sum by (participant_key) (devshard_gateway_participant_total_attempt_seconds_count) or vector(0)";"{{participant_key}}";"s";16;23;8;7),
        table(74;"Executor wins";"sum by (participant_key,model) (devshard_gateway_user_visible_wins_total)";0;30;8;8;"Empty until an executor wins a routed request. This build exports no devshard_gateway_user_visible_wins_total series at all, so the table stays empty rather than implying that every executor has zero wins.";{noValue:"this gateway build exports no executor win counter"}),
        table(75;"Executor failures";"sum by (participant_key,model,reason) (devshard_gateway_attempt_failures_total) or vector(0)";8;30;8;8),
        table(76;"Quarantine state";"devshard_gateway_participant_quarantine_state";16;30;8;8;"Quarantine state exists per participant and model. An empty table means the gateway is tracking no participant, which is not the same as every participant being healthy.";{noValue:"the gateway tracks no participant"}),

        row(230;"Capacity and escrow routing";38),
        ts(81;"Effective and baseline weight";"devshard_gateway_capacity_total_weight or devshard_gateway_capacity_baseline_weight";"weight";"none";0;39;8;7;"Empty until the gateway publishes a capacity weight. Before the first capacity computation neither weight exists, so the panel stays blank rather than drawing a zero that would read as no capacity.";{noValue:"the gateway has published no capacity weight"};["lastNotNull"]),
        ts(82;"Escrow effective weight";"devshard_gateway_escrow_weight";"escrow {{devshard_id}}";"none";8;39;8;7;"An escrow weight exists only while the gateway routes through an escrow. Empty means no escrow is active, not that an active escrow carries no weight.";{noValue:"no escrow is active"};["lastNotNull"]),
        ts(83;"Blocked participants (active escrow)";"devshard_gateway_escrow_blocked_participants or vector(0)";"escrow {{devshard_id}}";"none";16;39;8;7),
        ts(84;"Gateway and participant rejections";"sum by (reason) (rate(devshard_gateway_limit_rejections_total[5m])) or sum by (scope) (rate(devshard_gateway_participant_limit_rejections_total[5m])) or vector(0)";"{{reason}}{{scope}}";"reqps";0;46;12;8),
        ts(85;"Hidden participant failures";"sum by (model) (devshard_gateway_user_requests_with_hidden_failure_total) or vector(0)";"{{model}}";"none";12;46;12;8),

        row(240;"Data passport";54),
        stat(91;"Gateway request sample age (0 when none)";"time() - max(timestamp(devshard_gateway_requests_total)) or vector(0)";"s";0;55;6),
        stat(92;"Current executors";"count(count by (participant_key) (devshard_gateway_participant_quarantine_state)) or vector(0)";"none";6;55;6),
        stat(93;"Models observed";"count(count by (model) (devshard_gateway_requests_total)) or vector(0)";"none";12;55;6),
        stat(94;"Transport errors";"sum(devshard_gateway_participant_transport_errors_total) or vector(0)";"none";18;55;6),

        row(250;"Telegram inference consumer";59),
        stat(101;"Unique users";"sum(gdc_telegram_bot_unique_users) or vector(0)";"none";0;60;4),
        stat(102;"Premium users";"sum(gdc_telegram_bot_unique_users{premium=\"true\"}) or vector(0)";"none";4;60;4),
        stat(103;"Conversations";"sum(gdc_telegram_bot_conversations) or vector(0)";"none";8;60;4),
        stat(104;"Interactions";"sum(gdc_telegram_bot_interactions_total) or vector(0)";"none";12;60;4),
        stat(105;"Input tokens";"sum(gdc_telegram_bot_tokens_total{direction=\"input\"}) or vector(0)";"none";16;60;4),
        stat(106;"Output tokens";"sum(gdc_telegram_bot_tokens_total{direction=\"output\"}) or vector(0)";"none";20;60;4),
        ts(111;"Interaction rate by outcome and Premium state";"sum by (outcome,premium) (rate(gdc_telegram_bot_interactions_total[15m])) or vector(0)";"{{outcome}} · premium={{premium}}";"reqps";0;64;12;8),
        ts(112;"Inference request rate by outcome";"sum by (outcome) (rate(gdc_telegram_bot_inference_requests_total[15m])) or vector(0)";"{{outcome}}";"reqps";12;64;12;8),
        stat(113;"Last successful bot inference (0 when unavailable)";"(time() - max(gdc_telegram_bot_last_success_timestamp_seconds)) or vector(0)";"s";0;72;8),
        stat(114;"Responses without token usage";"sum(gdc_telegram_bot_usage_missing_total) or vector(0)";"none";8;72;8),
        stat(115;"Consumer process";"max(gdc_telegram_bot_up) or vector(0)";"none";16;72;8),
        textpanel(99;"Data contract";"This board adapts **Gonka: Inference & Devshards Observatory** to live Community DevNet gateway metrics. **Traffic ready** is the authoritative readiness signal: zero means no verified routed completion is currently available, even if the gateway metrics scrape succeeds. Request and active-escrow panels can be zero before the first routed request or while no escrow is active; they never claim traffic occurred. Counters start when the gateway process starts and are retained by Prometheus for 30 days. Telegram panels contain aggregate consumer activity and exact API-reported tokens without user identifiers or message content; a zero last-success age means the consumer has not reported a successful inference yet. GNK notional value and archive-node SQL are not available, so the board does not invent those panels.";76)
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
