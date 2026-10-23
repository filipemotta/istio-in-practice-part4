#!/usr/bin/env bash
# Shared helpers sourced by the lab scripts. Not meant to be run directly.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export PATH="${REPO_ROOT}/bin:${PATH}"

CLUSTER_NAME="istio-p4"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
ISTIO_VERSION="1.31.2"
GATEWAY_API_VERSION="v1.6.3"
OUT="${REPO_ROOT}/out"
mkdir -p "${OUT}"
export CLUSTER_NAME KUBE_CONTEXT ISTIO_VERSION GATEWAY_API_VERSION OUT

# Safety: the lab only ever talks to its own kind cluster. Every kubectl and
# istioctl call passes --context explicitly, so the current context of your
# kubeconfig is never used; on top of that, refuse to run if the lab context
# does not point at a kind cluster with the expected name.
assert_lab_context() {
  local cluster server
  # Resolve context -> cluster -> server: the cluster the context really uses.
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}" 2>/dev/null || true)"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || true)"
  if [ -z "${cluster}" ] || [[ ! "${server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "refusing to run: context ${KUBE_CONTEXT} is missing or does not point at a local kind API server (server='${server}')" >&2
    exit 3
  fi
}

k()    { kubectl --context "${KUBE_CONTEXT}" "$@"; }
ictl() { istioctl --context "${KUBE_CONTEXT}" "$@"; }

ensure_clis() { bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null; }

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
show() { sed 's/^/      /'; }

# --- assertions: failures are counted, the script exits non-zero at the end ---
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi
}
# expect_match <description> <extended regex> <actual>
expect_match() {
  if grep -Eq -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (no match for /$2/ in: $(head -c 600 <<< "$3"))"; fi
}
# expect_no_match <description> <extended regex> <actual>
expect_no_match() {
  if grep -Eq -- "$2" <<< "$3"; then fail "$1 (unexpected /$2/ in: $(head -c 600 <<< "$3"))"; else pass "$1"; fi
}
# expect_between <description> <min> <max> <actual integer>
expect_between() {
  if [[ "$4" =~ ^-?[0-9]+$ ]] && [ "$4" -ge "$2" ] && [ "$4" -le "$3" ]; then
    pass "$1 (got $4, accepted range $2..$3)"
  else
    fail "$1 (got $4, accepted range $2..$3)"
  fi
}

finish() {
  printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
  [ "${FAILED}" -eq 0 ]
}

# --- pods ---
# pod_of <ns> <label selector> -> the name of the first running pod
pod_of() {
  k -n "$1" get pod -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
# pods_of <ns> <label selector> -> the names of all running pods, one per line
pods_of() {
  k -n "$1" get pod -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}
# ip_of <ns> <pod> -> the pod IP
ip_of() { k -n "$1" get pod "$2" -o jsonpath='{.status.podIP}'; }

# --- requests from a pod of the lab ---
# req <ns> <deployment> <url> [extra curl args...] -> "<http code> <curl exit>"
# One request with curl from the "app" container of that deployment. A
# connection refused or reset by a proxy has no HTTP code at all ("000").
req() {
  local ns="$1" dep="$2" url="$3"; shift 3
  # shellcheck disable=SC2016 # runs in the pod shell
  k -n "${ns}" exec "deploy/${dep}" -c app -- sh -c '
    url="$1"; shift
    c="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$@" "${url}")"; rc=$?
    echo "${c:-000} ${rc}"' sh "${url}" "$@" 2>/dev/null || echo "000 99"
}
# req_full <ns> <deployment> <url> [extra curl args...] -> curl's own output
req_full() {
  local ns="$1" dep="$2" url="$3"; shift 3
  k -n "${ns}" exec "deploy/${dep}" -c app -- curl -sS --max-time 10 "$@" "${url}" 2>&1 || true
}
# codes <ns> <deployment> <requests> <url> [extra curl args...] -> histogram,
# e.g. "200=10" or "200=5 429=3"; "000" counts requests without an HTTP answer.
codes() {
  local ns="$1" dep="$2" n="$3" url="$4"; shift 4
  # shellcheck disable=SC2016 # the loop runs in the pod shell
  k -n "${ns}" exec "deploy/${dep}" -c app -- sh -c '
    n="$1"; url="$2"; shift 2; i=0
    while [ "$i" -lt "$n" ]; do
      curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "$@" "${url}"
      i=$((i + 1))
    done' sh "${n}" "${url}" "$@" | sort | uniq -c | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }'
}
# field <name> <"200=.. 429=.."> -> the number for that name (0 if absent)
field() {
  local v
  v="$(tr ' ' '\n' <<< "$2" | sed -n "s/^$1=//p")"
  printf '%s' "${v:-0}"
}
# run_id -> a unique token, used in request paths so that the requests of one
# test can be found in access logs.
run_id() { printf 'r%s%04d' "$(date +%s)" "$((RANDOM % 10000))"; }

# --- access logs (provider diag-log, istio/install.yaml) ---
# proxy_log <ns> <pod selector> <run id> [container] -> the access log lines of
# the proxies of those pods that carry the run id (waits 2s for the flush)
proxy_log() {
  local ns="$1" sel="$2" id="$3" ctr="${4:-istio-proxy}" p
  sleep 2
  for p in $(pods_of "${ns}" "${sel}"); do
    k -n "${ns}" logs "${p}" -c "${ctr}" --since=10m 2>/dev/null | grep -F -- "${id}" || true
  done
}
# kv <key> <log line(s)> -> the value of key=value in the first line
kv() { grep -o -- "$1=[^ ]*" <<< "$2" | head -1 | cut -d= -f2-; }

# --- proxy-config: what each Envoy actually received ---
# pc <type> <pod> <ns> [flags...] -> istioctl proxy-config <type> -o json
pc() { local t="$1" p="$2" ns="$3"; shift 3; ictl proxy-config "${t}" "${p}.${ns}" -o json "$@" 2>/dev/null; }
# cluster_names <pod> <ns> -> sorted cluster names
cluster_names() { pc cluster "$1" "$2" | jq -r '.[].name' | sort; }
# endpoint_count <pod> <ns> <cluster> -> number of endpoints of that cluster
endpoint_count() {
  pc endpoint "$1" "$2" --cluster "$3" | jq '[.[].hostStatuses[]?] | length'
}
# healthy_count <pod> <ns> <cluster> -> number of HEALTHY endpoints of that cluster
healthy_count() {
  pc endpoint "$1" "$2" --cluster "$3" | jq '[.[].hostStatuses[]? | select(.healthStatus.edsHealthStatus == "HEALTHY")] | length'
}
# route_vhost <pod> <ns> <route config name> <vhost name> -> that virtual host as JSON
route_vhost() {
  pc route "$1" "$2" --name "$3" | jq --arg v "$4" '[.[].virtualHosts[] | select(.name == $v)] | first'
}
# inbound_http_filters <pod> <ns> <port> -> the HTTP filter names of the plain
# and mTLS inbound filter chains for that destination port, one line per chain
inbound_http_filters() {
  pc listener "$1" "$2" --port 15006 | jq -r --argjson p "$3" '
    .[].filterChains[] | select(.filterChainMatch.destinationPort == $p)
    | [.filters[] | select(.name == "envoy.filters.network.http_connection_manager")
       | .typedConfig.httpFilters[].name] | join(",")'
}
# envoy_stat <ns> <pod> <exact stat name> -> its value (0 if absent)
envoy_stat() {
  local v
  v="$(k -n "$1" exec "$2" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null \
    | awk -F': ' -v s="$3" '$1 == s { print $2 }')"
  printf '%s' "${v:-0}"
}

# draining <ns> <label selector> -> sum over those pods of the Envoy gauge
# listener_manager.total_filter_chains_draining. After a listener update, the
# filter chains it replaced keep serving the connections opened before it
# until Envoy drains them, so a request can still meet the old configuration.
draining() {
  local total=0 v p
  for p in $(pods_of "$1" "$2"); do
    v="$(envoy_stat "$1" "${p}" listener_manager.total_filter_chains_draining)"
    total=$((total + ${v:-0}))
  done
  printf '%s' "${total}"
}
# wait_drained <ns> <label selector>: wait (up to 120s) until no old filter
# chain is draining there
wait_drained() { wait_for 120 "0" draining "$1" "$2" || true; }

# --- istiod ---
# istiod_metric <metric name> [label regex] -> sum of the istiod samples of
# that metric (and label set), read from :15014/metrics through the API
# server service proxy; 0 when the series does not exist yet.
istiod_metric() {
  k get --raw "/api/v1/namespaces/istio-system/services/istiod:15014/proxy/metrics" 2>/dev/null \
    | awk -v m="$1" -v l="${2:-}" '
        $1 ~ "^" m "({|$)" && (l == "" || $1 ~ l) { s += $2 }
        END { printf "%d", s }'
}
# xds_status <pod> <ns> <type short name, e.g. LDS> -> the status istiod
# reports for that xDS type of the proxy (SYNCED, STALE, NOT_SENT, ERROR...)
xds_status() {
  local url
  case "$3" in
    CDS) url="type.googleapis.com/envoy.config.cluster.v3.Cluster" ;;
    LDS) url="type.googleapis.com/envoy.config.listener.v3.Listener" ;;
    RDS) url="type.googleapis.com/envoy.config.route.v3.RouteConfiguration" ;;
    EDS) url="type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment" ;;
    *) url="$3" ;;
  esac
  ictl proxy-status -o json 2>/dev/null | jq -r --arg id "$1.$2" --arg t "${url}" '
    [.resources[]? | select(.node.id | endswith($id))
     | .genericXdsConfigs[]? | select(.typeUrl == $t) | (.configStatus // "UNKNOWN")] | first // "ABSENT"'
}

# apply_file <file>: apply and print the file path, for the log.
apply_file() {
  note "kubectl apply -f ${1#"${REPO_ROOT}"/}"
  k apply -f "$1" >/dev/null
}
# delete_file <file>
delete_file() {
  note "kubectl delete -f ${1#"${REPO_ROOT}"/}"
  k delete -f "$1" --ignore-not-found >/dev/null
}

# wait_for <seconds> <expected> <command...>: re-runs the command every 2s until
# its output equals <expected>. Returns 1 on timeout (callers then assert).
wait_for() {
  local deadline=$((SECONDS + $1)) expected="$2"; shift 2
  until [ "$("$@" 2>/dev/null)" = "${expected}" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout (${expected}): $*"; return 1; }
    sleep 2
  done
}
# wait_json <seconds> <jq filter that must output true> <command...>
wait_json() {
  local deadline=$((SECONDS + $1)) filter="$2"; shift 2
  until [ "$("$@" 2>/dev/null | jq -r "${filter}" 2>/dev/null)" = "true" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout waiting for: ${filter}"; return 1; }
    sleep 2
  done
}

# reset_payments: remove every traffic, security and extension policy of the
# sidecar namespace, so each step starts from plain Kubernetes Services.
reset_payments() {
  k -n payments delete virtualservice,destinationrule,serviceentry,peerauthentication,authorizationpolicy,envoyfilter \
    --all --ignore-not-found >/dev/null
  k -n istio-system delete envoyfilter --all --ignore-not-found >/dev/null
}
