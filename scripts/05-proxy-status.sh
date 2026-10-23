#!/usr/bin/env bash
# Step 5: is the proxy up to date? istioctl proxy-status reports, per proxy
# and per xDS type, what istiod knows about the last push:
#   SYNCED    Envoy acknowledged the last version istiod sent
#   STALE     istiod sent a version and has no answer yet
#   ERROR     Envoy answered with a NACK: it rejected the version
#   NOT SENT  istiod has sent nothing of that type
# Two reproductions:
#   STALE  pause the Envoy process of one sidecar (SIGSTOP), push a change,
#          read the status, resume it (SIGCONT)
#   ERROR  an EnvoyFilter that puts a filter after the router: the API server
#          and istiod accept it, Envoy rejects the listener. While the
#          rejection lasts, a policy applied afterwards never reaches the proxy.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

CALLER="$(pod_of payments app=payments-api)"
FQDN="fraud-check.payments.svc.cluster.local"

# pause_envoy <ns> <pod> <seconds>: freeze the envoy process of the pod's
# sidecar for that long. The istio-proxy image is distroless (no shell), so
# an ephemeral debug container (busybox) joins the process namespace of the
# istio-proxy container (--target), sends SIGSTOP, waits, sends SIGCONT.
# Ephemeral containers cannot be removed: the pod keeps it, exited.
pause_envoy() {
  k -n "$1" debug "pod/$2" --target=istio-proxy --image=busybox:1.37.0 --container="pause-envoy-$(date +%s)" \
    -- sh -c "p=\$(pidof envoy); kill -STOP \$p && echo stopped \$p; sleep $3; kill -CONT \$p && echo resumed \$p" >/dev/null 2>&1
}
step "Baseline: every xDS type of payments-api SYNCED"
ictl proxy-status | show
for t in LDS RDS CDS EDS; do
  expect_eq "payments-api ${t}" "SYNCED" "$(xds_status "${CALLER}" payments "${t}")"
done
ictl proxy-status -v 1 2>/dev/null | grep -E "^NAME|${CALLER}" | show

step "STALE: pause the Envoy of payments-api, then push a change it must receive"
pause_envoy payments "${CALLER}" 60
paused() { k -n payments get pod "${CALLER}" -o json | jq -r '[.status.ephemeralContainerStatuses[]? | select(.state.running)] | length > 0'; }
wait_for 60 "true" paused || true
sleep 3
note "envoy of ${CALLER} paused for 60s (SIGSTOP from an ephemeral container)"
apply_file "${REPO_ROOT}/translation/10-destinationrule-subsets.yaml"
cds_not_synced() { [ "$(xds_status "${CALLER}" payments CDS)" != "SYNCED" ] && echo yes || echo no; }
wait_for 60 "yes" cds_not_synced || true
st="$(xds_status "${CALLER}" payments CDS)"
ictl proxy-status 2>/dev/null | grep -E "^NAME|${CALLER}" | show
ictl proxy-status -v 1 2>/dev/null | grep -E "^NAME|${CALLER}" | show
expect_eq "CDS of the paused proxy: sent, not acknowledged" "STALE" "${st}"
others="$(ictl proxy-status -o json | jq -r --arg me "${CALLER}.payments" '[.resources[] | select(.node.id | endswith($me) | not)
  | .genericXdsConfigs[]? | select(.typeUrl | endswith("Cluster")) | .configStatus // "UNKNOWN"] | unique | join(",")')"
expect_eq "every other proxy acknowledged its clusters" "SYNCED" "${others}"
wait_for 90 "SYNCED" xds_status "${CALLER}" payments CDS || true
note "SIGCONT sent at the end of the pause"
expect_eq "resumed: CDS SYNCED again" "SYNCED" "$(xds_status "${CALLER}" payments CDS)"
expect_eq "and the subset clusters are there" "2 1" \
  "$(endpoint_count "${CALLER}" payments "outbound|8080|v1|${FQDN}") $(endpoint_count "${CALLER}" payments "outbound|8080|v2|${FQDN}")"
k -n payments rollout status deploy/payments-api --timeout=120s >/dev/null
k -n payments delete destinationrule fraud-check >/dev/null

step "ERROR: an EnvoyFilter Envoy rejects (envoyfilter/silent-errors/04-after-router.yaml)"
RECV="$(pod_of payments app=fraud-check,version=v2)"
RECV_IP="$(ip_of payments "${RECV}")"
rej_before="$(istiod_metric pilot_total_xds_rejects 'type="lds"')"
env_before="$(envoy_stat payments "${RECV}" listener_manager.lds.update_rejected)"
listener_before="$(pc listener "${RECV}" payments --port 15006 | jq -S . | shasum | cut -c1-12)"
out="$(k apply -f "${REPO_ROOT}/envoyfilter/silent-errors/04-after-router.yaml" 2>&1)"
note "kubectl: $(tr '\n' ' ' <<< "${out}")"
expect_match "the API server accepts it" 'created|configured' "${out}"
fc_lds_errors() {
  local p n=0
  for p in $(pods_of payments app=fraud-check); do
    [ "$(xds_status "${p}" payments LDS)" = "ERROR" ] && n=$((n + 1))
  done
  echo "${n}"
}
wait_for 60 "3" fc_lds_errors || true
ictl proxy-status -v 1 2>/dev/null | grep -E "^NAME|fraud-check" | show
expect_eq "LDS status ERROR on the 3 fraud-check proxies" "3" "$(fc_lds_errors)"
expect_eq "the other proxies are not affected (payments-api LDS)" "SYNCED" "$(xds_status "${CALLER}" payments LDS)"
detail="$(ictl proxy-status -o json | jq -r --arg me "${RECV}.payments" '.resources[] | select(.node.id | endswith($me))
  | .genericXdsConfigs[] | select(.typeUrl | endswith("Listener")) | .errorState.details // ""')"
note "error details: ${detail:0:400}"
expect_match "the NACK says why: the router must be the last HTTP filter" 'terminal filter named envoy.filters.http.router.*must be the last filter' "${detail}"
sleep 5
rej_after="$(istiod_metric pilot_total_xds_rejects 'type="lds"')"
expect_between "istiod counted the rejections: pilot_total_xds_rejects{type=\"lds\"} grew" 3 1000 "$((rej_after - rej_before))"
expect_between "Envoy counted it too: listener_manager.lds.update_rejected grew" 1 1000 \
  "$(( $(envoy_stat payments "${RECV}" listener_manager.lds.update_rejected) - env_before ))"
log="$(k -n istio-system logs deploy/istiod --since=2m | grep -F 'ACK ERROR' | grep -F "${RECV}" | tail -1 || true)"
note "istiod: ${log:0:300}"
expect_match "istiod logs the NACK with the proxy name" 'ADS:LDS: ACK ERROR' "${log}"
expect_eq "the proxy kept its previous inbound listener (config unchanged)" "${listener_before}" \
  "$(pc listener "${RECV}" payments --port 15006 | jq -S . | shasum | cut -c1-12)"
expect_no_match "no local_ratelimit in what Envoy runs" 'local_ratelimit' "$(inbound_http_filters "${RECV}" payments 8080)"
expect_eq "fraud-check keeps serving with the old listener" "200 0" "$(req payments payments-api "http://${RECV_IP}:8080/still-up")"

step "While the rejection lasts, a new policy does not reach the proxy"
apply_file "${REPO_ROOT}/proxy-status/fraud-check-deny-blocked.yaml"
sleep 15
expect_eq "kubectl lists the DENY policy" "fraud-check-deny-blocked" \
  "$(k -n payments get authorizationpolicy fraud-check-deny-blocked -o jsonpath='{.metadata.name}')"
expect_eq "GET /blocked on fraud-check v2: still 200, the RBAC filter never arrived" "200 0" \
  "$(req payments payments-api "http://${RECV_IP}:8080/blocked")"
expect_eq "LDS still ERROR" "ERROR" "$(xds_status "${RECV}" payments LDS)"
diffout="$(ictl proxy-status "${RECV}.payments" 2>&1 || true)"
head -20 <<< "${diffout}" | show
expect_match "istioctl proxy-status <pod>: istiod's listeners and Envoy's differ" "Listeners Don't Match|Listeners.*[Dd]on.t" "${diffout}"

step "Remove the EnvoyFilter: the next push is accepted, the policy arrives"
delete_file "${REPO_ROOT}/envoyfilter/silent-errors/04-after-router.yaml"
wait_for 60 "0" fc_lds_errors || true
expect_eq "no fraud-check proxy in ERROR" "0" "$(fc_lds_errors)"
expect_eq "LDS SYNCED on fraud-check v2" "SYNCED" "$(xds_status "${RECV}" payments LDS)"
blocked() { req payments payments-api "http://${RECV_IP}:8080/blocked"; }
wait_for 60 "403 0" blocked || true
wait_drained payments app=fraud-check
expect_eq "GET /blocked: 403 now (twice, after the old chains drained)" "403 0 403 0" "$(blocked) $(blocked)"
reset_payments
finish
