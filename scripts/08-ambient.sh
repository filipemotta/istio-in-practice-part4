#!/usr/bin/env bash
# Step 8: ambient mode has two kinds of proxy, read with two tools.
#   ztunnel   per-node, written in Rust, not Envoy: istioctl ztunnel-config
#             (workloads, services, policies, certificates, connections)
#   waypoint  Envoy: istioctl proxy-config, as for a sidecar; the L7 route
#             (HTTPRoute) and the RBAC filter (AuthorizationPolicy) live here
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

NS="payments-ambient"
k -n "${NS}" delete authorizationpolicy,httproute --all --ignore-not-found >/dev/null
FC="$(pod_of "${NS}" app=fraud-check)"
FC_NODE="$(k -n "${NS}" get pod "${FC}" -o jsonpath='{.spec.nodeName}')"
ZT="$(k -n istio-system get pod -l app=ztunnel --field-selector "spec.nodeName=${FC_NODE}" -o jsonpath='{.items[0].metadata.name}')"
WP="$(pod_of "${NS}" gateway.networking.k8s.io/gateway-name=waypoint)"
FQDN="fraud-check.${NS}.svc.cluster.local"
note "fraud-check ${FC} on ${FC_NODE}, its ztunnel ${ZT}, waypoint ${WP}"
zc() { local t="$1"; shift; ictl ztunnel-config "${t}" "${ZT}.istio-system" "$@"; }

step "ztunnel is not Envoy: proxy-config does not apply"
out="$(ictl proxy-config listener "${ZT}.istio-system" 2>&1 || true)"
note "$(tail -1 <<< "${out}" | cut -c1-200)"
expect_no_match "istioctl proxy-config listener on a ztunnel pod returns no Envoy listeners" '"name": "virtualOutbound"|^ADDRESS' "${out}"

step "ztunnel-config workloads"
zc workloads --workload-namespace "${NS}" | show
w="$(zc workloads -o json)"
expect_eq "ambient workloads: protocol HBONE" "HBONE HBONE" \
  "$(jq -r --arg ns "${NS}" '[.[] | select(.namespace == $ns and (.name | test("^(payments-api|fraud-check)-"))) | .protocol] | sort | join(" ")' <<< "${w}")"
# Sidecar pods are in ztunnel's table too, also HBONE: the injected label
# networking.istio.io/tunnel=http says their sidecar accepts HBONE (port 15008),
# so ambient clients can reach them with mTLS over HBONE.
expect_eq "sidecar workloads (payments) are listed too, protocol HBONE" "HBONE" \
  "$(jq -r '[.[] | select(.namespace == "payments") | .protocol] | unique | join(",")' <<< "${w}")"
expect_eq "because their pods carry networking.istio.io/tunnel=http" "http" \
  "$(k -n payments get pod -l app=fraud-check -o jsonpath='{.items[0].metadata.labels.networking\.istio\.io/tunnel}')"
expect_eq "the waypoint itself is a workload with protocol TCP" "TCP" \
  "$(jq -r --arg ns "${NS}" '[.[] | select(.namespace == $ns and (.name | startswith("waypoint-"))) | .protocol] | join(",")' <<< "${w}")"
expect_eq "fraud-check's workload carries its identity" "spiffe://cluster.local/ns/${NS}/sa/fraud-check" \
  "$(jq -r --arg ns "${NS}" '[.[] | select(.namespace == $ns and (.name | startswith("fraud-check-")))][0] | "spiffe://\(.trustDomain)/ns/\(.namespace)/sa/\(.serviceAccount)"' <<< "${w}")"

step "ztunnel-config services: fraud-check is served by the waypoint"
zc services --service-namespace "${NS}" | show
s="$(zc services -o json)"
expect_eq "the fraud-check service points at the waypoint" "waypoint.${NS}.svc.cluster.local" \
  "$(jq -r --arg n "${NS}/${FQDN}" '[.[] | select("\(.namespace)/\(.hostname)" == $n)][0].waypoint.destination | split("/") | last' <<< "${s}")"

step "ztunnel-config certificates: ztunnel holds the certificates of the ambient pods of its node"
zc certificates | show
expect_match "a certificate for fraud-check's identity" "spiffe://cluster.local/ns/${NS}/sa/fraud-check" "$(zc certificates 2>/dev/null)"

step "L7 for fraud-check: HTTPRoute + AuthorizationPolicy with targetRefs (the waypoint applies them)"
apply_file "${REPO_ROOT}/ambient/fraud-check-httproute.yaml"
apply_file "${REPO_ROOT}/ambient/fraud-check-l7-policy.yaml"
wp_has_policy() { ictl proxy-config listener "${WP}.${NS}" -o json 2>/dev/null | grep -c "ns\[${NS}\]-policy\[fraud-check-l7\]-rule\[0\]" || true; }
wait_json 90 '. > 0' wp_has_policy || true
wait_drained "${NS}" gateway.networking.k8s.io/gateway-name=waypoint
expect_eq "GET /v1/check/1 -> 200" "200 0" "$(req "${NS}" payments-api http://fraud-check:8080/v1/check/1)"
expect_eq "POST /v1/check -> 403" "403 0" "$(req "${NS}" payments-api http://fraud-check:8080/v1/check -X POST)"
expect_eq "GET /admin -> 403" "403 0" "$(req "${NS}" payments-api http://fraud-check:8080/admin)"

step "ztunnel-config policies: the L7 policy is not ztunnel's"
zc policies | show
expect_eq "no policy for fraud-check-l7 in ztunnel (targetRefs Service: the waypoint enforces it)" "0" \
  "$(zc policies -o json 2>/dev/null | jq --arg ns "${NS}" '[.[] | select(.namespace == $ns and .name == "fraud-check-l7")] | length')"

step "ztunnel-config connections: HBONE through the waypoint"
# Connections only show while open: keep one request in flight (fortio
# answers after 8s) and read the table meanwhile.
k -n "${NS}" exec deploy/payments-api -c app -- curl -s -o /dev/null --max-time 20 "http://fraud-check:8080/v1/check/slow?delay=8s" >/dev/null 2>&1 &
inflight=$!
sleep 3
CALLER_POD="$(pod_of "${NS}" app=payments-api)"
CALLER_NODE="$(k -n "${NS}" get pod "${CALLER_POD}" -o jsonpath='{.spec.nodeName}')"
ZT_CALLER="$(k -n istio-system get pod -l app=ztunnel --field-selector "spec.nodeName=${CALLER_NODE}" -o jsonpath='{.items[0].metadata.name}')"
cons="$(ictl ztunnel-config connections "${ZT_CALLER}.istio-system" 2>&1 || true)"
cj="$(ictl ztunnel-config connections "${ZT_CALLER}.istio-system" -o json 2>/dev/null || echo '[]')"
wait "${inflight}" || true
head -12 <<< "${cons}" | show
WP_IP="$(ip_of "${NS}" "${WP}")"
FC_IP="$(ip_of "${NS}" "${FC}")"
# Measured in Istio 1.31.2: the caller's side lists no outbound connection,
# even with the request in flight; the receiving side lists the HBONE
# connection the waypoint keeps open to it (pooled, reused across requests).
note "payments-api (caller) connections listed by its ztunnel: $(jq -c --arg n "${CALLER_POD}" '[.[] | select(.info.name == $n) | .connections] | first // {}' <<< "${cj}")"
expect_eq "fraud-check: inbound, HBONE, from the waypoint, to port 8080" "HBONE ${WP_IP} ${FC_IP}:8080" \
  "$(jq -r --arg n "${FC}" '[.[] | select(.info.name == $n) | .connections.inbound[]?] | first // {} | "\(.protocol) \(.src | split(":")[0]) \(.actualDst)"' <<< "${cj}")"

step "The waypoint is Envoy: proxy-config shows the route and the RBAC filter"
ictl proxy-config listener "${WP}.${NS}" | show
wl="$(pc listener "${WP}" "${NS}")"
note "waypoint listeners: $(jq -r '[.[].name] | join(" ")' <<< "${wl}")"
rbac="$(jq -r '[.. | objects | select(.name? == "envoy.filters.http.rbac") | .. | objects | select(has("policies")) | .policies | keys[]] | unique | join(",")' <<< "${wl}")"
expect_match "RBAC filter in the waypoint with the policy fraud-check-l7" "ns\[${NS}\]-policy\[fraud-check-l7\]-rule\[0\]" "${rbac}"
rts="$(pc route "${WP}" "${NS}")"
hdr="$(jq -r '[.. | objects | select(has("requestHeadersToAdd")) | .requestHeadersToAdd[] | "\(.header.key)=\(.header.value)"] | unique | join(",")' <<< "${rts}")"
expect_match "the HTTPRoute is in the waypoint's routes (x-served-by header)" 'x-served-by=waypoint-route' "${hdr}"
cl="$(cluster_names "${WP}" "${NS}" | grep -F "${FQDN}" | paste -sd' ' -)"
note "waypoint clusters for fraud-check: ${cl}"
expect_match "the waypoint has an inbound-vip cluster for fraud-check" "inbound-vip\|8080\|http\|${FQDN}" "${cl}"
id="$(run_id)"
req "${NS}" payments-api "http://fraud-check:8080/v1/check/${id}" >/dev/null
req "${NS}" payments-api "http://fraud-check:8080/v1/check/${id}" -X POST >/dev/null
log="$(proxy_log "${NS}" gateway.networking.k8s.io/gateway-name=waypoint "${id}")"
printf '%s\n' "${log}" | cut -c1-400 | show
expect_eq "waypoint access log, GET: 200 via_upstream" "200 via_upstream" \
  "$(grep -F '"GET' <<< "${log}" | awk '{ print $5 }') $(kv details "$(grep -F '"GET' <<< "${log}")")"
expect_eq "waypoint access log, POST: 403 rbac_access_denied_matched_policy[none]" "403 rbac_access_denied_matched_policy[none]" \
  "$(grep -F '"POST' <<< "${log}" | awk '{ print $5 }') $(kv details "$(grep -F '"POST' <<< "${log}")")"
k -n "${NS}" delete authorizationpolicy,httproute --all --ignore-not-found >/dev/null
finish
