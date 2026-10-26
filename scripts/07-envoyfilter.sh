#!/usr/bin/env bash
# Step 7: EnvoyFilter, the last resort. A local rate limit on fraud-check
# (no native Istio API covers it in 1.31), proved twice: it entered the
# config (right before the router, only on port 8080) and it limits (429).
# Then the ways the same patch goes wrong while the API server says
# "created": a wrong context, a wrong port, a deprecated filter name, a
# filter that is never enabled, and an EnvoyFilter in the root namespace
# with no selector, which lands on every proxy of the mesh.
# (The filter after the router, which Envoy rejects, is step 05.)
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

SE="${REPO_ROOT}/envoyfilter/silent-errors"
V2="$(pod_of payments app=fraud-check,version=v2)"
V2_IP="$(ip_of payments "${V2}")"
ratelimit_pods() { # how many fraud-check proxies have local_ratelimit in their inbound 8080 chains
  local p n=0
  for p in $(pods_of payments app=fraud-check); do
    inbound_http_filters "${p}" payments 8080 | grep -q 'envoy.filters.http.local_ratelimit' && n=$((n + 1))
  done
  echo "${n}"
}
inbound_hash() { pc listener "${V2}" payments --port 15006 | jq -S . | shasum | cut -c1-12; }
rl_stat() { envoy_stat payments "${V2}" "http_local_rate_limiter.http_local_rate_limit.$1"; }
# burst <port> -> histogram of 8 requests from payments-api to fraud-check v2
# (pod IP). It first waits until no replaced filter chain is draining in the
# fraud-check proxies: a connection opened before the last listener update
# keeps the old chain (with or without the limiter) until it drains.
burst() { wait_drained payments app=fraud-check; codes payments payments-api 8 "http://${V2_IP}:$1/burst"; }

step "No native API: Istio 1.31 has no rate limit resource"
expect_eq "CRDs whose name mentions rate limit" "0" "$(k get crd -o name | grep -ci 'ratelimit' || true)"

step "The filter (envoyfilter/fraud-check-local-ratelimit.yaml)"
out="$(k apply -f "${REPO_ROOT}/envoyfilter/fraud-check-local-ratelimit.yaml" 2>&1)"
note "kubectl: $(tr '\n' ' ' <<< "${out}")"
expect_match "the API server warns about every EnvoyFilter" 'EnvoyFilter exposes internal implementation details' "${out}"
wait_for 60 "3" ratelimit_pods || true
expect_eq "it reached all 3 fraud-check proxies" "3" "$(ratelimit_pods)"
chains="$(inbound_http_filters "${V2}" payments 8080 | sort -u)"
note "inbound HTTP filters, port 8080: $(head -1 <<< "${chains}")"
expect_eq "local_ratelimit is right before the router, in every 8080 chain" "envoy.filters.http.local_ratelimit,envoy.filters.http.router" \
  "$(awk -F, '{ print $(NF-1) "," $NF }' <<< "${chains}" | sort -u)"
expect_no_match "not in the 8090 chains (portNumber 8080)" 'local_ratelimit' "$(inbound_http_filters "${V2}" payments 8090)"
expect_no_match "not in the outbound listeners" 'local_ratelimit' "$(pc listener "${V2}" payments --address 0.0.0.0 --port 8080 | jq -c '[.. | objects | select(has("httpFilters")) | .httpFilters[].name]')"
# stats are counters that survive listener updates: compare with a snapshot
rl_all() { printf '%s %s %s %s' "$(rl_stat enabled)" "$(rl_stat ok)" "$(rl_stat rate_limited)" "$(rl_stat enforced)"; }
wait_drained payments app=fraud-check
read -r s_en s_ok s_rl s_enf <<< "$(rl_all)"
h="$(burst 8080)"
expect_eq "8 requests to fraud-check v2:8080 -> 5 allowed, 3 limited" "200=5 429=3" "${h}"
hdr="$(req_full payments payments-api "http://${V2_IP}:8080/one-more" -i)"
expect_match "the 429 carries x-local-rate-limit: true" '^x-local-rate-limit: true' "$(tr -d '\r' <<< "${hdr}")"
expect_match "and Envoy's local reply body" 'local_rate_limited' "${hdr}"
id="$(run_id)"
req payments payments-api "http://${V2_IP}:8080/${id}" >/dev/null
log="$(proxy_log payments app=fraud-check,version=v2 "${id}")"
note "${log:0:300}"
expect_eq "fraud-check access log: 429 flags RL, details local_rate_limited" "RL local_rate_limited" "$(kv flags "${log}") $(kv details "${log}")"
read -r e_en e_ok e_rl e_enf <<< "$(rl_all)"
expect_eq "stats for these 10 requests: enabled / ok / rate_limited / enforced" "10 5 5 5" \
  "$((e_en - s_en)) $((e_ok - s_ok)) $((e_rl - s_rl)) $((e_enf - s_enf))"
expect_eq "port 8090 (not matched): 8 requests -> 200=8" "200=8" "$(burst 8090)"
delete_file "${REPO_ROOT}/envoyfilter/fraud-check-local-ratelimit.yaml"
wait_for 60 "0" ratelimit_pods || true
base="$(inbound_hash)"

# silent <file> <description>: apply, wait for istiod to push, prove the
# inbound listener of fraud-check v2 did not change and nothing is limited
LAST_OUT=""
silent() {
  local f="$1"
  LAST_OUT="$(k apply -f "${f}" 2>&1)"
  note "kubectl apply -f ${f#"${REPO_ROOT}"/}: $(tr '\n' ' ' <<< "${LAST_OUT}" | cut -c1-260)"
  expect_match "$2: accepted by the API server" 'created|configured' "${LAST_OUT}"
  sleep 15
  expect_eq "$2: fraud-check's inbound listener unchanged" "${base}" "$(inbound_hash)"
  expect_eq "$2: 8 requests -> 200=8, nothing limited" "200=8" "$(burst 8080)"
}

step "Silent error 1: context SIDECAR_OUTBOUND ($(basename "${SE}/01-wrong-context.yaml"))"
silent "${SE}/01-wrong-context.yaml" "wrong context"
out_f="$(pc listener "${V2}" payments --address 0.0.0.0 --port 8080 | jq -r '[.. | objects | select(has("httpFilters")) | .httpFilters[].name] | join(",")')"
note "fraud-check OUTBOUND 0.0.0.0_8080 HTTP filters: ${out_f}"
expect_match "the patch landed on fraud-check's outbound listener for port 8080 instead" 'local_ratelimit,envoy\.filters\.http\.router' "${out_f}"
expect_eq "so fraud-check's own calls to risk-score:8080 (via its 8090 proxy) get limited" "200=5 429=3" "$(burst 8090)"
delete_file "${SE}/01-wrong-context.yaml"

step "Silent error 2: portNumber 15006 ($(basename "${SE}/02-wrong-port-15006.yaml"))"
silent "${SE}/02-wrong-port-15006.yaml" "portNumber 15006"
delete_file "${SE}/02-wrong-port-15006.yaml"

step "Silent error 3: deprecated filter name ($(basename "${SE}/03-deprecated-filter-name.yaml"))"
silent "${SE}/03-deprecated-filter-name.yaml" "deprecated name"
expect_match "the API server only warns" 'using deprecated filter name "envoy.http_connection_manager"' "${LAST_OUT}"
delete_file "${SE}/03-deprecated-filter-name.yaml"

step "Silent error 4: never enabled ($(basename "${SE}/06-not-enabled.yaml"))"
apply_file "${SE}/06-not-enabled.yaml"
wait_for 60 "3" ratelimit_pods || true
expect_eq "the filter IS in all 3 proxies, before the router" "3" "$(ratelimit_pods)"
expect_eq "8 requests -> 200=8: filter_enabled defaults to 0%" "200=8" "$(burst 8080)"
delete_file "${SE}/06-not-enabled.yaml"
wait_for 60 "0" ratelimit_pods || true

step "Scope: root namespace, no selector, no context ($(basename "${SE}/05-root-namespace-no-selector.yaml"))"
# Every Envoy of the mesh: sidecars, the ingress gateway and the waypoint.
# (The ztunnel container is also named istio-proxy; it is not Envoy.)
envoys="$(k get pods -A -o json | jq -r '.items[] | select(.status.phase == "Running")
  | select([.spec.initContainers[]?.name, .spec.containers[].name] | index("istio-proxy"))
  | select(.metadata.labels.app != "ztunnel")
  | "\(.metadata.name).\(.metadata.namespace)"' | sort)"
total="$(grep -c . <<< "${envoys}")"
hit() { # proxies with the mesh_wide_probe filter anywhere in their listeners
  local e n=0
  for e in ${envoys}; do
    if ictl proxy-config listener "${e}" -o json 2>/dev/null | grep -c 'mesh_wide_probe' >/dev/null; then n=$((n + 1)); fi
  done
  echo "${n}"
}
expect_eq "before: no proxy has it" "0" "$(hit)"
apply_file "${SE}/05-root-namespace-no-selector.yaml"
sleep 20
n="$(hit)"
for e in ${envoys}; do
  c="$(ictl proxy-config listener "${e}" -o json 2>/dev/null | jq '[.. | objects | select(has("httpFilters")) | select(any(.httpFilters[]; .name == "envoy.filters.http.local_ratelimit"))] | length')"
  note "${e}: patched HTTP connection managers = ${c}"
done
note "proxies hit: ${n} of ${total} Envoys"
expect_eq "every sidecar and the ingress gateway got it (waypoints take EnvoyFilters by targetRefs only)" "$((total - 1))" "${n}"
WP="$(pod_of payments-ambient gateway.networking.k8s.io/gateway-name=waypoint)"
expect_eq "the waypoint did not" "0" "$(ictl proxy-config listener "${WP}.payments-ambient" -o json | grep -c mesh_wide_probe || true)"
delete_file "${SE}/05-root-namespace-no-selector.yaml"

step "A typo in a field (max_tokenz): proto type vs TypedStruct (ci/testdata/ef-typo-*.yaml)"
# Admission: istiod's validation decodes a typed_config written as the proto
# type and warns about the unknown field; inside a TypedStruct it says
# nothing. Neither is rejected.
for form in direct typedstruct; do
  out="$(k apply --dry-run=server -f "${REPO_ROOT}/ci/testdata/ef-typo-${form}.yaml" 2>&1)" && rc=0 || rc=$?
  note "kubectl apply --dry-run=server -f ci/testdata/ef-typo-${form}.yaml (exit ${rc}):"
  printf '%s\n' "${out}" | show
  expect_eq "${form}: server dry run accepted" "0 1" "${rc} $(grep -c 'created (server dry run)' <<< "${out}" || true)"
  if [ "${form}" = direct ]; then
    expect_match "direct: the API server warns, naming the field" 'Warning: Envoy filter: can.t unmarshal Any nested proto .*unknown field "max_tokenz" in envoy.type.v3.TokenBucket' "${out}"
  else
    expect_no_match "typedstruct: no warning about the field" 'max_tokenz' "${out}"
  fi
done
# Delivery: both reach the proxy and Envoy acknowledges both (LDS SYNCED);
# max_tokens is lost either way (istiod drops it from the proto form; Envoy
# ignores it inside the TypedStruct, logging it and counting it in
# server.dynamic_unknown_fields), and a bucket of 0 tokens limits everything.
for form in direct typedstruct; do
  unk0="$(envoy_stat payments "${V2}" server.dynamic_unknown_fields)"
  apply_file "${REPO_ROOT}/ci/testdata/ef-typo-${form}.yaml"
  wait_for 60 "3" ratelimit_pods || true
  expect_eq "${form}: the filter reached all 3 fraud-check proxies, LDS acknowledged" "3 SYNCED" "$(ratelimit_pods) $(xds_status "${V2}" payments LDS)"
  tb="$(pc listener "${V2}" payments --port 15006 | jq -c '[.. | objects | select(.name? == "envoy.filters.http.local_ratelimit") | .typedConfig | (.tokenBucket // .value.token_bucket)] | first')"
  note "${form}: token bucket as the proxy holds it: ${tb}"
  expect_eq "${form}: no max_tokens in the token bucket" "false" "$(jq '(has("maxTokens") or has("max_tokens") or has("max_tokenz"))' <<< "${tb}")"
  expect_eq "${form}: 8 requests -> all limited" "429=8" "$(burst 8080)"
  unk="$(( $(envoy_stat payments "${V2}" server.dynamic_unknown_fields) - unk0 ))"
  if [ "${form}" = direct ]; then
    expect_eq "direct: Envoy never saw the field (server.dynamic_unknown_fields +0)" "0" "${unk}"
  else
    expect_eq "typedstruct: Envoy counted it, once per filter chain (server.dynamic_unknown_fields +2)" "2" "${unk}"
    plog="$(k -n payments logs "${V2}" -c istio-proxy --since=2m || true)"
    wl="$(grep -F "no such field: 'max_tokenz'" <<< "${plog}" | tail -1 || true)"
    note "${wl:0:300}"
    expect_match "typedstruct: Envoy logs a warning with the field" "Unknown field: type envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit.*no such field: 'max_tokenz'" "${wl}"
    # On a miss, show what the proxy did log, so the next run says why.
    [ -n "${wl}" ] || grep -E "max_tokenz|Unknown field|unknown field" <<< "${plog}" | tail -5 | cut -c1-600 | show || true
    [ -n "${wl}" ] || note "istio-proxy log, last 2m: $(wc -l <<< "${plog}") lines"
  fi
  delete_file "${REPO_ROOT}/ci/testdata/ef-typo-${form}.yaml"
  wait_for 60 "0" ratelimit_pods || true
done
reset_payments
finish
