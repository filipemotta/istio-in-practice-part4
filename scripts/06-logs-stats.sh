#!/usr/bin/env bash
# Step 6: what Envoy says about itself.
#   - component log levels changed at runtime (istioctl proxy-config log),
#     and back, without restarting the pod
#   - the access log format comes from the Telemetry API provider, and its
#     fields name the decision (flags, details, cluster, route)
#   - per-cluster stats: only what the stats matcher includes exists
#   - the admin interface (15000) listens on localhost only
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

FQDN="fraud-check.payments.svc.cluster.local"
CALLER="$(pod_of payments app=payments-api)"
RECV="$(pod_of payments app=fraud-check,version=v2)"
RECV_IP="$(ip_of payments "${RECV}")"
level_of() { ictl proxy-config log "${RECV}.payments" 2>/dev/null | awk -v c="$1" '$1 == c":" { print $2 }'; }

step "Log levels at runtime: rbac to debug on one fraud-check proxy"
lv="$(ictl proxy-config log "${RECV}.payments")"; head -8 <<< "${lv}" | show
expect_eq "rbac logger, default level" "warning" "$(level_of rbac)"
ictl proxy-config log "${RECV}.payments" --level rbac:debug >/dev/null
expect_eq "after --level rbac:debug" "debug" "$(level_of rbac)"
expect_eq "other loggers untouched (http)" "warning" "$(level_of http)"
apply_file "${REPO_ROOT}/proxy-status/fraud-check-deny-blocked.yaml"
blocked() { req payments payments-api "http://${RECV_IP}:8080/blocked"; }
wait_for 60 "403 0" blocked || true
# one 403 is not enough: connections opened before the push keep the old
# filter chain (no RBAC) until Envoy drains them
wait_drained payments app=fraud-check
id="$(run_id)"
# paths in AuthorizationPolicy match the path without the query string
expect_eq "GET /blocked?run=${id} denied" "403 0" "$(req payments payments-api "http://${RECV_IP}:8080/blocked?run=${id}")"
sleep 2
dbg="$(k -n payments logs "${RECV}" -c istio-proxy --since=30s | grep -F 'enforced denied' | tail -1 || true)"
note "${dbg:0:300}"
expect_match "the debug log names the policy that matched" 'enforced denied, matched policy ns\[payments\]-policy\[fraud-check-deny-blocked\]-rule\[0\]' "${dbg}"
ictl proxy-config log "${RECV}.payments" -r >/dev/null
expect_eq "after -r (reset): rbac back to warning" "warning" "$(level_of rbac)"
expect_eq "the pod did not restart" "0" "$(k -n payments get pod "${RECV}" -o json | jq '[.status.initContainerStatuses[]?, .status.containerStatuses[]? | select(.name == "istio-proxy") | .restartCount] | add')"

step "Access log: the format of the Telemetry provider diag-log, in the listener config"
fmt="$(pc listener "${RECV}" payments --port 15006 | jq -r '[.. | objects | select(has("accessLog")) | .accessLog[]
  | .. | objects | select(has("textFormatSource")) | .textFormatSource.inlineString] | unique | .[]')"
note "${fmt:0:300}"
expect_match "the inbound listener logs with the provider's format (flags, details, cluster)" 'flags=%RESPONSE_FLAGS% details=%RESPONSE_CODE_DETAILS% cluster=%UPSTREAM_CLUSTER_RAW% statname=%UPSTREAM_CLUSTER%' "${fmt}"
log="$(proxy_log payments app=fraud-check,version=v2 "${id}")"
note "${log:0:400}"
expect_eq "the 403 in fraud-check's access log: flags, details" \
  "- rbac_access_denied_matched_policy[ns[payments]-policy[fraud-check-deny-blocked]-rule[0]]" \
  "$(kv flags "${log}") $(kv details "${log}")"
note "cluster on the denied request: $(kv cluster "${log}") (route $(kv route "${log}"))"
k -n payments delete authorizationpolicy fraud-check-deny-blocked >/dev/null

step "Per-cluster stats in payments-api (proxyStatsMatcher includes .*fraud-check.*)"
# Istio names cluster stats after the cluster's alt_stat_name: the cluster
# name plus ";", so the stat is cluster.<name>;.<counter>
stat_c() { envoy_stat payments "${CALLER}" "cluster.outbound|8080||$1;.$2"; }
b200="$(stat_c "${FQDN}" upstream_rq_200)"
codes payments payments-api 10 "http://fraud-check:8080/stats-probe" >/dev/null
sleep 2
expect_eq "cluster.outbound|8080||${FQDN};.upstream_rq_200 grew by 10" "10" "$(( $(stat_c "${FQDN}" upstream_rq_200) - b200 ))"
expect_eq "membership_healthy / membership_total" "3/3" "$(stat_c "${FQDN}" membership_healthy)/$(stat_c "${FQDN}" membership_total)"
k -n payments exec "${CALLER}" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null \
  | grep -F "cluster.outbound|8080||${FQDN};." | grep -E 'upstream_rq_(200|total|completed)|membership_(healthy|total)' | show
rs="$(k -n payments exec "${CALLER}" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null | grep -cF 'cluster.outbound|8080||risk-score.payments.svc.cluster.local.' || true)"
expect_eq "the risk-score cluster, left out of the matcher, has no stats at all" "0" "${rs}"
hosts="$(k -n payments exec "${CALLER}" -c istio-proxy -- pilot-agent request GET clusters 2>/dev/null | grep -F 'outbound|8080||risk-score.payments.svc.cluster.local::' | grep -c '::health_flags::' || true)"
expect_eq "the admin /clusters view still lists risk-score's endpoints with health flags" "1" "${hosts}"
eject="$(k -n payments exec "${CALLER}" -c istio-proxy -- pilot-agent request GET clusters 2>/dev/null | grep -F "outbound|8080||${FQDN}::" | grep '::health_flags::' | awk -F'::' '{ print $NF }' | sort | uniq -c | awk '{ print $2 "=" $1 }' | paste -sd' ' -)"
expect_eq "per-host health flags of the fraud-check cluster" "healthy=3" "${eject}"

step "Admin interface 15000: localhost only"
adm="$(pc bootstrap "${RECV}" payments | jq -r '.bootstrap.admin.address.socketAddress | "\(.address):\(.portValue)"')"
expect_eq "bootstrap admin address" "127.0.0.1:15000" "${adm}"
expect_eq "inside the pod, through pilot-agent: the admin API answers" "LIVE" \
  "$(k -n payments exec "${RECV}" -c istio-proxy -- pilot-agent request GET ready 2>/dev/null | tr -d '[:space:]')"
r="$(req payments payments-api "http://${RECV_IP}:15000/stats")"
note "payments-api -> ${RECV_IP}:15000/stats -> ${r}"
expect_eq "from another pod (payments-api) to <fraud-check pod IP>:15000: 503, no admin answer" "503 0" "${r}"
body="$(req_full payments payments-api "http://${RECV_IP}:15000/config_dump")"
expect_no_match "no config dump leaves the pod" 'configs' "${body}"
note "curl: ${body:0:200}"
admin_log() { k -n payments logs "${RECV}" -c istio-proxy --since=60s 2>/dev/null | grep -F "dst=${RECV_IP}:15000" | tail -1 || true; }
deadline=$((SECONDS + 30)); log=""
until [ -n "${log}" ] || [ "${SECONDS}" -ge "${deadline}" ]; do sleep 2; log="$(admin_log)"; done
note "fraud-check inbound log: ${log:0:300}"
expect_eq "fraud-check's sidecar took it inbound (15006) and found nothing listening on the pod IP: flags, cluster" \
  "URX,UF InboundPassthroughCluster" "$(kv flags "${log}") $(kv cluster "${log}")"
expect_match "details: connection refused" 'remote_connection_failure.*Connection_refused' "$(kv details "${log}")"
reset_payments
finish
