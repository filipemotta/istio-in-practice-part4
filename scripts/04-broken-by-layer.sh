#!/usr/bin/env bash
# Step 4: break the routing on purpose and find each failure in the layer
# where it lives, with the access log flags as the first clue:
#   route layer     a VirtualService with no default route        -> 404 NR
#   cluster layer   a subset that matches no pod: cluster, 0 endpoints -> 503 UH
#   nowhere         a VirtualService for a host that does not exist,
#                   and one bound to a gateway (sidecars dropped)  -> accepted, never in the route config
#   egress          unknown external host: PassthroughCluster (ALLOW_ANY)
#                   vs BlackHoleCluster (REGISTRY_ONLY)
# Needs Internet egress from the kind nodes (example.com, api.github.com).
# Restores outboundTrafficPolicy ALLOW_ANY at the end.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

FQDN="fraud-check.payments.svc.cluster.local"
CALLER="$(pod_of payments app=payments-api)"
mesh_mode() { k -n istio-system get cm istio -o jsonpath='{.data.mesh}' | yq '.outboundTrafficPolicy.mode // "ALLOW_ANY"'; }
if [ "$(mesh_mode)" != "ALLOW_ANY" ]; then
  note "a previous run stopped half-way: restoring istio/install.yaml (ALLOW_ANY) first"
  ictl install -y -f "${REPO_ROOT}/istio/install.yaml" >/dev/null 2>&1
fi
vh_routes() { route_vhost "${CALLER}" payments 8080 "${FQDN}:8080" | jq -r '[.routes[].name] | join(",")'; }

step "Route layer: VirtualService with the canary route only (broken/01-vs-no-default-route.yaml)"
apply_file "${REPO_ROOT}/translation/10-destinationrule-subsets.yaml"
apply_file "${REPO_ROOT}/broken/01-vs-no-default-route.yaml"
wait_for 60 "canary" vh_routes || true
expect_eq "the virtual host has one route, canary" "canary" "$(vh_routes)"
id="$(run_id)"
r="$(req payments payments-api "http://fraud-check:8080/${id}")"
expect_eq "request without x-canary: 404 from the caller's own sidecar" "404 0" "${r}"
log="$(proxy_log payments app=payments-api "${id}")"
note "${log:0:300}"
expect_eq "access log: flags NR, details route_not_found, no cluster" "NR route_not_found -" \
  "$(kv flags "${log}") $(kv details "${log}") $(kv cluster "${log}")"
expect_eq "no fraud-check sidecar saw the request" "0" "$(proxy_log payments app=fraud-check "${id}" | grep -c . || true)"
expect_eq "with x-canary: true -> 200" "200 0" "$(req payments payments-api "http://fraud-check:8080/${id}-c" -H 'x-canary: true')"

step "Cluster layer: subset v3 that no pod has (broken/02-subset-without-pods.yaml)"
apply_file "${REPO_ROOT}/broken/02-subset-without-pods.yaml"
V3="outbound|8080|v3|${FQDN}"
wait_for 60 "v3-rollout" vh_routes || true
expect_match "the cluster exists in the caller" "^${V3//|/\\|}$" "$(cluster_names "${CALLER}" payments)"
ictl proxy-config endpoint "${CALLER}.payments" --cluster "${V3}" | show
expect_eq "with 0 endpoints" "0" "$(endpoint_count "${CALLER}" payments "${V3}")"
id="$(run_id)"
expect_eq "request -> 503" "503 0" "$(req payments payments-api "http://fraud-check:8080/${id}")"
expect_eq "response body" "no healthy upstream" "$(req_full payments payments-api "http://fraud-check:8080/${id}-b")"
log="$(proxy_log payments app=payments-api "${id}")"; log="${log%%$'\n'*}"
note "${log:0:300}"
expect_eq "access log: flags UH, details no_healthy_upstream, cluster v3" "UH no_healthy_upstream ${V3}" \
  "$(kv flags "${log}") $(kv details "${log}") $(kv cluster "${log}")"
RECV="$(pod_of payments app=fraud-check,version=v1)"
desc="$(ictl x describe pod "${RECV}" -n payments 2>&1 || true)"
printf '%s\n' "${desc}" | show
expect_match "istioctl x describe pod: the DestinationRule and the subsets that match this pod" 'DestinationRule: fraud-check' "${desc}"
expect_match "and the subset nobody matches" 'v3' "${desc}"
an="$(ictl analyze -n payments 2>&1 || true)"
printf '%s\n' "${an}" | show
expect_match "istioctl analyze: IST0173, the subset selects no pods" 'IST0173.*Subset v3 .*does not select any pods' "${an}"
k -n payments delete virtualservice fraud-check >/dev/null

step "Nowhere: a VirtualService for a host that does not exist (broken/03-vs-wrong-host.yaml)"
out="$(k apply -f "${REPO_ROOT}/broken/03-vs-wrong-host.yaml" 2>&1)"
note "kubectl: ${out}"
expect_match "the API server accepts it" 'created|configured' "${out}"
expect_eq "kubectl lists it" "fraud-check-typo" "$(k -n payments get virtualservice fraud-check-typo -o jsonpath='{.metadata.name}')"
sleep 5
routes="$(pc route "${CALLER}" payments)"
where="$(jq -r '[.[] | .name as $r | .virtualHosts[]? | select(.name | startswith("fraud-check.payment.svc"))
  | "\($r) \(.name) \(.domains | join(",")) \(.routes[0].name)->\(.routes[0].route.cluster)"] | join(";")' <<< "${routes}")"
note "pushed to: ${where}"
expect_eq "istiod pushed it, to route config 80, as its own virtual host" \
  "80 fraud-check.payment.svc.cluster.local:80 fraud-check.payment.svc.cluster.local all-to-v2->outbound|80|v2|fraud-check.payments.svc.cluster.local" "${where}"
expect_eq "that cluster does not exist (fraud-check has no port 80)" "0" \
  "$(cluster_names "${CALLER}" payments | grep -cF 'outbound|80|v2|fraud-check' || true)"
expect_eq "route config 8080, the one fraud-check:8080 uses, is untouched" "default" "$(vh_routes)"
id="$(run_id)"
codes payments payments-api 12 "http://fraud-check:8080/${id}" >/dev/null
log="$(proxy_log payments app=payments-api "${id}")"
expect_eq "12 requests: all through route default to the subset-less cluster" "12 default outbound|8080||${FQDN}" \
  "$(grep -c . <<< "${log}") $(grep -o 'route=[^ ]*' <<< "${log}" | sort -u | cut -d= -f2 | paste -sd, -) $(grep -o 'cluster=[^ ]*' <<< "${log}" | sort -u | cut -d= -f2 | paste -sd, -)"
an="$(ictl analyze -n payments 2>&1 || true)"
printf '%s\n' "${an}" | show
expect_no_match "istioctl analyze says nothing about the host typo" 'fraud-check\.payment\.svc' "${an}"
k -n payments delete virtualservice fraud-check-typo >/dev/null

step "Nowhere: gateways set, mesh dropped (broken/04-vs-gateway-drops-mesh.yaml)"
apply_file "${REPO_ROOT}/broken/04-vs-gateway-drops-mesh.yaml"
sleep 5
expect_eq "not in payments-api's route config (no 'mesh' in gateways)" "0" \
  "$(pc route "${CALLER}" payments | jq '[.[].virtualHosts[]?.routes[]? | select(.name == "all-to-v2")] | length')"
GW="$(pod_of payments-ingress gateway.networking.k8s.io/gateway-name=payments-gateway)"
expect_eq "not in the ingress gateway's either (a VirtualService binds to Istio Gateways, not Gateway API ones)" "0" \
  "$(pc route "${GW}" payments-ingress | jq '[.[].virtualHosts[]?.routes[]? | select(.name == "all-to-v2")] | length')"
an="$(ictl analyze -n payments 2>&1 || true)"
printf '%s\n' "${an}" | show
expect_match "istioctl analyze flags the gateway reference" 'IST0101.*payments-gateway' "${an}"
k -n payments delete virtualservice fraud-check-edge destinationrule fraud-check --ignore-not-found >/dev/null

step "Egress, ALLOW_ANY: an external host nobody declared"
expect_eq "mesh outboundTrafficPolicy" "ALLOW_ANY" "$(mesh_mode)"
apply_file "${REPO_ROOT}/translation/30-serviceentry-github.yaml"
id="$(run_id)"
r="$(req payments payments-api "http://example.com/${id}")"
note "http://example.com/${id} -> ${r}"
expect_match "http://example.com answers (any HTTP code, curl exit 0)" '^[1-5][0-9][0-9] 0$' "${r}"
log="$(proxy_log payments app=payments-api "${id}")"
note "${log:0:300}"
expect_eq "access log: route allow_any, cluster PassthroughCluster" "allow_any PassthroughCluster" "$(kv route "${log}") $(kv cluster "${log}")"
expect_eq "the virtual host that caught it" "allow_any" \
  "$(pc route "${CALLER}" payments --name 80 | jq -r '[.[].virtualHosts[] | select(.domains | index("*")) | .name] | join(",")')"

step "Egress, REGISTRY_ONLY (istio/install.yaml + istio/registry-only.yaml)"
ictl install -y -f "${REPO_ROOT}/istio/install.yaml" -f "${REPO_ROOT}/istio/registry-only.yaml" >/dev/null 2>&1
expect_eq "mesh outboundTrafficPolicy" "REGISTRY_ONLY" "$(mesh_mode)"
catchall() { pc route "${CALLER}" payments --name 80 | jq -r '[.[].virtualHosts[] | select(.domains | index("*")) | .name] | join(",")'; }
wait_for 90 "block_all" catchall || true
expect_eq "the catch-all virtual host is now block_all" "block_all" "$(catchall)"
id="$(run_id)"
r="$(req payments payments-api "http://example.com/${id}")"
expect_eq "http://example.com -> 502 from the sidecar" "502 0" "${r}"
log="$(proxy_log payments app=payments-api "${id}")"
note "${log:0:300}"
expect_eq "access log: route block_all answers itself (direct_response, no cluster)" "block_all direct_response -" \
  "$(kv route "${log}") $(kv details "${log}") $(kv cluster "${log}")"
r="$(req payments payments-api "https://www.example.com/")"
note "https://www.example.com/ -> ${r}"
expect_eq "https to an unknown host: no TLS handshake (curl exit 35)" "000 35" "${r}"
sleep 3
log="$(k -n payments logs "${CALLER}" -c istio-proxy --since=20s | grep -F 'cluster=BlackHoleCluster' | grep -v '"GET' | tail -1 || true)"
note "${log:0:300}"
expect_eq "access log (TCP): cluster BlackHoleCluster, flags UH" "BlackHoleCluster UH" "$(kv cluster "${log}") $(kv flags "${log}")"
expect_eq "the declared host (ServiceEntry) still works" "200 0" "$(req payments payments-api https://api.github.com/zen)"

step "Restore ALLOW_ANY"
ictl install -y -f "${REPO_ROOT}/istio/install.yaml" >/dev/null 2>&1
wait_for 90 "allow_any" catchall || true
expect_eq "mesh outboundTrafficPolicy back to ALLOW_ANY" "ALLOW_ANY allow_any" "$(mesh_mode) $(catchall)"
reset_payments
finish
