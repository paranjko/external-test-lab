# Adapt the pinned upstream single-Host topology to GDC data/identity mounts.
# Replace the proxy service completely: merging an nginx service into HAProxy
# would retain the wrong health check, command and network configuration.
# Compose parses an uninterpolated ${DATA_DIR}/... short mount as a named
# volume. All mounts in the base GDC recipe are binds; preserve that type
# explicitly so a later DATA_DIR promotion still changes their source.
.services |= with_entries(
  if .value.volumes then .value.volumes |= map(.type = "bind" | del(.volume)) else . end
) |
.services.proxy as $old |
{test:["CMD","/bin/busybox","wget","-q","-O","/dev/null","http://127.0.0.1:8404/readyz"],interval:"5s",timeout:"3s",retries:10,start_period:"15s"} as $health |
.services["proxy-policy"] = {
  image:"${PROXY_POLICY_IMAGE:?PROXY_POLICY_IMAGE is required}",restart:"unless-stopped",stop_grace_period:"30m",
  logging:$old.logging,depends_on:$old.depends_on,
  environment:($old.environment + {PROXY_PROTOCOL:"true",PROXY_PROTOCOL_PEER:"proxy-policy-ingress",
    PROXY_POLICY_READINESS_HOST:"proxy-policy-app-network",VERSIOND_SERVICE_NAME:"proxy-policy-ingress",
    VERSIOND_SERVICE_IS_ABSOLUTE:"true",VERSIOND_PORT:"18081"}),
  networks:{default:{aliases:["proxy-policy-app-network"]},"proxy-policy-front":{aliases:["proxy-policy-front"]}},
  healthcheck:{test:["CMD","curl","-f","http://127.0.0.1:8081/health"],interval:"5s",timeout:"3s",retries:5,start_period:"15s"}
} |
.services["proxy-policy2"] = .services["proxy-policy"] |
.services["versiond-router"] = {
  image:"${VERSIOND_ROUTER_IMAGE:?VERSIOND_ROUTER_IMAGE is required}",restart:"unless-stopped",
  environment:{GONKA_HA:"false",VERSIOND_POOL_HOST:"versiond",VERSIOND_ROUTER_POOL_SLOTS:"1",VERSIOND_LEGACY_HOST:"versiond",
    VERSIOND_VERSIONS:"",VERSIOND_NON_HA_VERSIONS:"",VERSIOND_ROUTING_CATALOG_URL:"http://api:9100/versions",
    VERSIOND_ROUTING_ACTIVATION_MIN_READY:"1",VERSIOND_ROUTER_FRONT_BIND_HOST:"versiond-router-ingress",
    VERSIOND_ROUTER_TRUST_FORWARDED_HEADERS:"true"},
  networks:{default:{},"versiond-router-front":{aliases:["versiond-router-ingress"]}},
  volumes:[{type:"volume",source:"versiond-router-state",target:"/var/lib/gonka-router"}],
  cap_drop:["ALL"],security_opt:["no-new-privileges:true"],healthcheck:$health,logging:$old.logging
} |
.services.proxy = {
  image:$old.image,restart:"unless-stopped",ports:$old.ports,logging:$old.logging,
  environment:{NGINX_MODE:"http",PROXY_POLICY_POOL_HOST:"proxy-policy-front",PROXY_POLICY_POOL_SLOTS:"4",
    PROXY_ROUTER_POLICY_BIND_HOST:"proxy-policy-ingress",PROXY_ROUTER_METRICS_BIND_HOST:"proxy-router-metrics",
    PROXY_ROUTER_PUBLIC_IDLE_SECONDS:"86400",PROXY_VERSIOND_PORT:"18081",
    VERSIOND_ROUTER_POOL_HOST:"versiond-router-ingress",VERSIOND_ROUTER_FLEET_CAPACITY:"4",
    VERSIOND_ROUTER_HEALTH_CONTRACT:"readyz",VERSIOND_VERSIONS:"",VERSIOND_NON_HA_VERSIONS:"",
    VERSIOND_ROUTING_CATALOG_URL:"http://api:9100/versions"},
  networks:{default:{aliases:["proxy-router-metrics"]},"versiond-router-front":{},"proxy-policy-front":{aliases:["proxy-policy-ingress"]}},
  volumes:[{type:"volume",source:"proxy-router-state",target:"/var/lib/gonka-router"}],
  cap_drop:["ALL"],cap_add:["NET_BIND_SERVICE"],security_opt:["no-new-privileges:true"],healthcheck:$health
} |
.networks["proxy-policy-front"] = {internal:true} |
.networks["versiond-router-front"] = {internal:true} |
.volumes["proxy-router-state"] = {} | .volumes["versiond-router-state"] = {} |
reduce ["node","api"][] as $role (.;
  .services[$role].environment.GDC_BOOTSTRAP_SOFTWARE = "true" |
  .services[$role].volumes += [
    {type:"bind",source:"./bootstrap-runtime",target:"/gdc-bootstrap-runtime",read_only:true,bind:{create_host_path:false}},
    {type:"bind",source:"./bootstrap-runtime.sh",target:"/usr/local/bin/gdc-bootstrap-runtime",read_only:true,bind:{create_host_path:false}}
  ])
