#!/usr/bin/env bash
# Step 2: follow one request, payments-api -> fraud-check:8080, through the
# layers of Envoy configuration that decide it, reading each one with
# istioctl proxy-config, and check that the access logs of both sidecars name
# the same objects.
#   caller:   listener 15001 (virtualOutbound) -> listener 0.0.0.0_8080
#             -> route config "8080" -> virtual host -> route -> cluster
#             outbound|8080||fraud-check.payments.svc.cluster.local -> endpoints
#   receiver: listener 15006 (virtualInbound) -> filter chain for port 8080
#             -> HTTP filters -> cluster inbound|8080||
# Read-only: changes nothing in the cluster.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

FQDN="fraud-check.payments.svc.cluster.local"
OUT_CLUSTER="outbound|8080||${FQDN}"
CALLER="$(pod_of payments app=payments-api)"
fc_ips="$(k -n payments get pod -l app=fraud-check -o jsonpath='{range .items[*]}{.status.podIP}:8080{"\n"}{end}' | sort)"
note "caller pod ${CALLER}; fraud-check endpoints: $(paste -sd' ' - <<< "${fc_ips}")"

step "1. The outbound capture listener: 0.0.0.0:15001"
ictl proxy-config listener "${CALLER}.payments" --port 15001 | show
l15001="$(pc listener "${CALLER}" payments --port 15001)"
expect_eq "listener on 15001 is named virtualOutbound" "virtualOutbound" "$(jq -r '.[0].name' <<< "${l15001}")"
expect_eq "virtualOutbound hands connections to the listener of their original destination (useOriginalDst)" "true" \
  "$(jq -r '.[0].useOriginalDst' <<< "${l15001}")"
chains15001="$(jq -r '[.[0].filterChains[] | "\(.name)>\(.filters[] | select(.name == "envoy.filters.network.tcp_proxy") | .typedConfig.cluster)"] | join(" ")' <<< "${l15001}")"
expect_eq "its own two chains: traffic aimed at 15001 itself is dropped, everything else not matched elsewhere passes through" \
  "virtualOutbound-blackhole>BlackHoleCluster virtualOutbound-catchall-tcp>PassthroughCluster" "${chains15001}"

step "2. The listener for the destination port: 0.0.0.0_8080 (HTTP) loads route config \"8080\""
ictl proxy-config listener "${CALLER}.payments" --port 8080 | show
l8080="$(pc listener "${CALLER}" payments --address 0.0.0.0 --port 8080)"
expect_eq "listener name" "0.0.0.0_8080" "$(jq -r '.[0].name' <<< "${l8080}")"
expect_eq "its HTTP connection manager takes routes over RDS, route config \"8080\"" "8080" \
  "$(jq -r '[.[0].filterChains[].filters[] | select(.name == "envoy.filters.network.http_connection_manager") | .typedConfig.rds.routeConfigName] | unique | join(",")' <<< "${l8080}")"

step "3. Route config \"8080\": virtual host ${FQDN}:8080 -> route -> cluster"
ictl proxy-config route "${CALLER}.payments" --name 8080 | show
vh="$(route_vhost "${CALLER}" payments 8080 "${FQDN}:8080")"
expect_match "the virtual host answers to the short name and the FQDN" '"fraud-check"' "$(jq -c '.domains' <<< "${vh}")"
expect_match "and to the full name" "\"${FQDN}\"" "$(jq -c '.domains' <<< "${vh}")"
expect_eq "one route, named default, catch-all prefix /" "1 default /" \
  "$(jq -r '"\(.routes | length) \(.routes[0].name) \(.routes[0].match.prefix)"' <<< "${vh}")"
expect_eq "the route points at the cluster" "${OUT_CLUSTER}" "$(jq -r '.routes[0].route.cluster' <<< "${vh}")"

step "4. Cluster ${OUT_CLUSTER}: type EDS, endpoints pushed by istiod"
ictl proxy-config cluster "${CALLER}.payments" --fqdn "${FQDN}" | show
cl="$(pc cluster "${CALLER}" payments --fqdn "${FQDN}" --port 8080)"
expect_eq "one cluster for port 8080 (no subsets yet)" "${OUT_CLUSTER}" "$(jq -r '[.[].name] | join(",")' <<< "${cl}")"
expect_eq "cluster type EDS" "EDS" "$(jq -r '.[0].type' <<< "${cl}")"

step "5. Endpoints of the cluster: the three fraud-check pods (v1 x2, v2 x1)"
ictl proxy-config endpoint "${CALLER}.payments" --cluster "${OUT_CLUSTER}" | show
eps="$(pc endpoint "${CALLER}" payments --cluster "${OUT_CLUSTER}" | jq -r '.[].hostStatuses[] | "\(.address.socketAddress.address):\(.address.socketAddress.portValue)"' | sort)"
expect_eq "endpoints = fraud-check pod IPs:8080" "$(paste -sd' ' - <<< "${fc_ips}")" "$(paste -sd' ' - <<< "${eps}")"
expect_eq "all HEALTHY" "3" "$(healthy_count "${CALLER}" payments "${OUT_CLUSTER}")"

step "6. The receiving side: fraud-check's inbound listener 0.0.0.0:15006"
RECV="$(pod_of payments app=fraud-check,version=v1)"
ictl proxy-config listener "${RECV}.payments" --port 15006 | show
l15006="$(pc listener "${RECV}" payments --port 15006)"
expect_eq "listener on 15006 is named virtualInbound" "virtualInbound" "$(jq -r '.[0].name' <<< "${l15006}")"
chains="$(jq -r '[.[0].filterChains[] | select(.filterChainMatch.destinationPort == 8080) | .name] | unique | join(",")' <<< "${l15006}")"
note "filter chains for destination port 8080: ${chains}"
expect_eq "filter chains for destination port 8080 all lead to inbound|8080||" "inbound|8080||" \
  "$(jq -r '[.[0].filterChains[] | select(.filterChainMatch.destinationPort == 8080) | .filters[]
     | (.typedConfig.routeConfig.virtualHosts[]?.routes[]?.route.cluster // .typedConfig.cluster // empty)] | unique | join(",")' <<< "${l15006}")"
httpf="$(inbound_http_filters "${RECV}" payments 8080 | sort -u)"
note "HTTP filters of those chains: $(head -1 <<< "${httpf}")"
expect_eq "the router is the last HTTP filter of every inbound HTTP chain" "envoy.filters.http.router" \
  "$(awk -F, '{ print $NF }' <<< "${httpf}" | sort -u)"
expect_no_match "no RBAC filter yet (no AuthorizationPolicy)" 'envoy\.filters\.http\.rbac' "${httpf}"
expect_match "cluster inbound|8080|| exists in fraud-check's proxy" '^inbound\|8080\|\|$' "$(cluster_names "${RECV}" payments)"

step "7. One request, and what both access logs say about it"
id="$(run_id)"
expect_eq "payments-api -> fraud-check:8080/${id}" "200 0" "$(req payments payments-api "http://fraud-check:8080/${id}")"
out_line="$(proxy_log payments app=payments-api "${id}")"
in_line="$(proxy_log payments app=fraud-check "${id}")"
printf '%s\n' "${out_line}" "${in_line}" | cut -c1-400 | show
expect_eq "caller side: cluster" "${OUT_CLUSTER}" "$(kv cluster "${out_line}")"
expect_eq "caller side: route" "default" "$(kv route "${out_line}")"
expect_eq "caller side: %UPSTREAM_CLUSTER% is the alt_stat_name, the name plus ';'" "${OUT_CLUSTER};" "$(kv statname "${out_line}")"
expect_match "caller side: upstream is one of the fraud-check endpoints" "^($(paste -sd'|' - <<< "${fc_ips}" | sed 's/\./\\./g'))$" "$(kv upstream "${out_line}")"
expect_eq "caller side: flags and details" "- via_upstream" "$(kv flags "${out_line}") $(kv details "${out_line}")"
expect_eq "exactly one fraud-check sidecar logged it" "1" "$(grep -c . <<< "${in_line}")"
expect_eq "receiver side: cluster" "inbound|8080||" "$(kv cluster "${in_line}")"
expect_eq "receiver side: the SNI istiod set for the mTLS connection" "outbound_.8080_._.${FQDN}" "$(kv sni "${in_line}")"
expect_eq "receiver side: original destination = the endpoint the caller picked" "$(kv upstream "${out_line}")" "$(kv dst "${in_line}")"
finish
