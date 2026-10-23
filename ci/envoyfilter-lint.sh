#!/usr/bin/env bash
# Offline checks for EnvoyFilter resources, for CI. No cluster needed.
#
#   bash ci/envoyfilter-lint.sh <file or directory>...
#
# The API server accepts EnvoyFilters that patch nothing, patch the wrong
# proxies, or produce a config Envoy rejects. This lint flags the patterns the
# lab proved to fail (see envoyfilter/silent-errors/), plus the warnings of
# `istioctl analyze --use-kube=false` on the same files.
#
# Errors (exit 1):
#   EF001  no workloadSelector and no targetRefs: applies to every workload of
#          the namespace, or of the whole mesh in the root namespace
#          (opt out with the annotation envoyfilter-lint/allow-wide-scope: "true")
#   EF002  a configPatch without match.context: context ANY patches inbound,
#          outbound and gateway configuration alike
#   EF003  a deprecated filter name (envoy.http_connection_manager, envoy.router,
#          ...): istiod generates canonical names and matches names exactly
#   EF004  INSERT_AFTER the router: the router is a terminal HTTP filter, Envoy
#          rejects (NACKs) any filter after it
#   EF005  portNumber 15001 or 15006 in a sidecar context: on the virtual
#          listeners portNumber is compared with each filter chain's
#          destination port, and no chain has those ports
#   EF006  envoy.filters.http.local_ratelimit without filter_enabled or
#          filter_enforced: both default to 0%, the filter never limits
#   EF007  envoy.filters.http.local_ratelimit in SIDECAR_OUTBOUND: it limits the
#          selected workload's own outbound calls, not the traffic it receives
#   EF008  a field the proto does not have (a typo): istiod's validation only
#          warns ("unknown field ..."), the API server accepts the resource
#          and istiod drops the field. Only visible when typed_config is the
#          proto type itself; inside a TypedStruct nothing reports it (EF102).
# Warnings (reported, exit 0):
#   EF101  a relative operation (INSERT_BEFORE/AFTER, MERGE, REPLACE, REMOVE)
#          without priority (same concern as istioctl analyze IST0151)
#   EF102  typed_config wrapped in a TypedStruct: admission does not decode the
#          value, so a field typo produces no warning at all (EF008 cannot see it)
#   EF103  HTTP_FILTER INSERT_BEFORE/INSERT_AFTER without a subFilter: the filter
#          goes first (or last) in the HTTP filter chain, ahead of the
#          authentication and authorization filters
#   istioctl analyze messages (IST0151..IST0155) are printed as they come.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${REPO_ROOT}/bin:${PATH}"

[ "$#" -gt 0 ] || { echo "usage: $0 <file or directory>..." >&2; exit 2; }
for t in yq jq istioctl; do
  command -v "${t}" >/dev/null || { echo "missing tool: ${t} (run tools/install-cli.sh)" >&2; exit 2; }
done

# Deprecated filter names Istio still maps to canonical ones
# (pkg/config/xds/deprecated.go in istio/istio 1.31.2).
DEPRECATED='["envoy.buffer","envoy.cors","envoy.csrf","envoy.http_dynamo_filter","envoy.ext_authz",
"envoy.fault","envoy.grpc_http1_bridge","envoy.grpc_json_transcoder","envoy.grpc_web","envoy.gzip",
"envoy.health_check","envoy.ip_tagging","envoy.lua","envoy.rate_limit","envoy.router","envoy.squash",
"envoy.listener.http_inspector","envoy.listener.original_dst","envoy.listener.original_src",
"envoy.listener.proxy_protocol","envoy.listener.tls_inspector","envoy.client_ssl_auth",
"envoy.http_connection_manager","envoy.mongo_proxy","envoy.ratelimit","envoy.redis_proxy","envoy.tcp_proxy"]'

files=()
for a in "$@"; do
  if [ -d "${a}" ]; then
    while IFS= read -r f; do files+=("${f}"); done < <(find "${a}" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  else
    files+=("${a}")
  fi
done

ERRORS=0
WARNINGS=0
CHECKED=0
report() { # <ERROR|WARN> <code> <file> <resource> <message>
  printf '%-5s %s %s %s: %s\n' "$1" "$2" "$3" "$4" "$5"
  if [ "$1" = "ERROR" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
}

# Every check is a jq program over one EnvoyFilter (as JSON) that prints
# "<code>\t<message>" lines.
# shellcheck disable=SC2016 # a jq program: $vars are jq variables
CHECKS='
def patches: (.spec.configPatches // []) | to_entries[];
def lr: .value.patch.value.name? == "envoy.filters.http.local_ratelimit";
def tc: .value.patch.value.typed_config? // {};
# the filter config itself: inside .value when wrapped in a TypedStruct
def cfg: tc | if ((.["@type"]? // "") | test("TypedStruct$")) then (.value // {}) else . end;
(if (.spec.workloadSelector == null and (.spec.targetRefs // []) == []
     and (.metadata.annotations["envoyfilter-lint/allow-wide-scope"] // "") != "true")
 then "EF001\tno workloadSelector or targetRefs: applies to every workload in namespace \(.metadata.namespace)"
      + (if .metadata.namespace == "istio-system" then " (the root namespace: every proxy of the mesh)" else "" end)
 else empty end),
(patches | select((.value.match.context // "ANY") == "ANY")
 | "EF002\tconfigPatches[\(.key)] has no match.context (ANY: inbound, outbound and gateways)"),
(patches | [.value.match.listener.filterChain.filter.name?, .value.match.listener.filterChain.filter.subFilter.name?,
            .value.patch.value.name?] | map(select(. != null))[]
 | select(. as $n | $deprecated | any(. == $n)) | "EF003\tdeprecated filter name \(.): never matches the canonical names istiod generates"),
(patches | select(.value.patch.operation? == "INSERT_AFTER"
                  and (.value.match.listener.filterChain.filter.subFilter.name? == "envoy.filters.http.router"))
 | "EF004\tconfigPatches[\(.key)] inserts after envoy.filters.http.router: Envoy rejects a filter after the terminal router"),
(patches | select((.value.match.context // "") | test("^SIDECAR_"))
 | select(.value.applyTo != "LISTENER") | select((.value.match.listener.portNumber? // 0) as $p | [15001, 15006] | any(. == $p))
 | "EF005\tconfigPatches[\(.key)] portNumber \(.value.match.listener.portNumber) never matches a filter chain of the virtual listeners; use the service port"),
(patches | select(lr) | select((cfg | has("filter_enabled") and has("filter_enforced")) | not)
 | "EF006\tconfigPatches[\(.key)] local_ratelimit without filter_enabled and filter_enforced: both default to 0%, nothing is limited"),
(patches | select(lr) | select(.value.match.context? == "SIDECAR_OUTBOUND")
 | "EF007\tconfigPatches[\(.key)] local_ratelimit in SIDECAR_OUTBOUND limits the own outbound calls of the workload, not its callers"),
(if ((.spec.priority // 0) == 0) then
   (patches | select(.value.patch.operation? as $o | ["INSERT_BEFORE","INSERT_AFTER","MERGE","REPLACE","REMOVE"] | index($o))
    | "EF101\tconfigPatches[\(.key)] relative operation \(.value.patch.operation) without priority")
 else empty end),
(patches | select((tc["@type"]? // "") | test("TypedStruct$"))
 | "EF102\tconfigPatches[\(.key)] typed_config is a TypedStruct: the value is not decoded at admission"),
(patches | select(.value.applyTo == "HTTP_FILTER")
 | select(.value.patch.operation? == "INSERT_BEFORE" or .value.patch.operation? == "INSERT_AFTER")
 | select(.value.match.listener.filterChain.filter.subFilter.name? == null)
 | "EF103\tconfigPatches[\(.key)] \(.value.patch.operation) without subFilter: placed at the \(if .value.patch.operation == "INSERT_BEFORE" then "front" else "end" end) of the HTTP filter chain")
'

ef_files=()
for f in "${files[@]}"; do
  [ -f "${f}" ] || { echo "not a file: ${f}" >&2; exit 2; }
  docs="$(yq -o=json -I=0 'select(.kind == "EnvoyFilter")' "${f}" 2>/dev/null)" || { report ERROR EF000 "${f}" "-" "not valid YAML"; continue; }
  [ -n "${docs}" ] || continue
  ef_files+=("${f}")
  while IFS= read -r doc; do
    [ -n "${doc}" ] || continue
    CHECKED=$((CHECKED + 1))
    res="$(jq -r '"\(.metadata.namespace // "default")/\(.metadata.name)"' <<< "${doc}")"
    while IFS=$'\t' read -r code msg; do
      [ -n "${code}" ] || continue
      if [[ "${code}" == EF1* ]]; then report WARN "${code}" "${f}" "${res}" "${msg}"; else report ERROR "${code}" "${f}" "${res}" "${msg}"; fi
    done < <(jq -r --argjson deprecated "${DEPRECATED}" "${CHECKS}" <<< "${doc}")
  done <<< "${docs}"
done

if [ "${#ef_files[@]}" -gt 0 ]; then
  # istioctl analyze on the EnvoyFilter files alone; its EnvoyFilter
  # analyzer works per resource, so nothing else is needed.
  out="$(istioctl analyze --use-kube=false --all-namespaces "${ef_files[@]}" 2>&1)"
  while IFS= read -r line; do
    case "${line}" in
      # IST0133 on every EnvoyFilter ("exposes internal implementation
      # details"): true, and the reason this lint exists; not repeated.
      *"exposes internal implementation details"*) ;;
      *"unknown field"*) report ERROR EF008 "-" "-" "${line}" ;;
      Error*) report ERROR ANALYZE "-" "-" "${line}" ;;
      Warning*) report WARN ANALYZE "-" "-" "${line}" ;;
    esac
  done <<< "${out}"
fi

echo "envoyfilter-lint: ${CHECKED} EnvoyFilter(s) checked, ${ERRORS} error(s), ${WARNINGS} warning(s)"
[ "${ERRORS}" -eq 0 ]
