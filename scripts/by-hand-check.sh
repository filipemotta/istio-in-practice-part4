#!/usr/bin/env bash
# Runs the "By hand" commands of README.md exactly as printed there (every
# line of each block, extracted from the README, run from the repository
# root), and checks their output against what the README and the article
# say. Needs the lab of steps 01..08 (scripts/test-all.sh runs this last).
#   block 1  follow one request: listener 15001 and 8080, route 8080,
#            cluster, endpoints
#   block 2  istioctl proxy-status -v 1 at rest: nothing STALE or in ERROR
#   block 3  the rate limit: apply, FC=..., eight requests -> 200=5 429=3
#            (200=6 429=2 is the draining case the README describes)
#   block 4  delete the filter
#   block 5  the full run and the teardown: checked as text only (running it
#            from here would recurse; it is how this script gets run)
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

FQDN="fraud-check.payments.svc.cluster.local"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# block <n> -> the n-th ```bash block of the "## By hand" section of README.md
block() {
  awk -v want="$1" '
    /^## / { insec = ($0 == "## By hand") }
    insec && /^```bash$/ { n++; inb = 1; next }
    insec && inb && /^```$/ { inb = 0; next }
    insec && inb && n == want { print }' "${REPO_ROOT}/README.md"
}
# run_block <n> <prefix>: run each logical line of block n (backslash
# continuations joined) in this shell, from the repository root, in order;
# the output of line i goes to ${TMP}/<prefix>.<i>
run_block() {
  local i=0 line="" l
  while IFS= read -r l; do
    if [[ "${l}" == *\\ ]]; then line+="${l%\\}"; continue; fi
    line+="${l}"
    i=$((i + 1))
    printf '    $ %s\n' "${line}"
    (cd "${REPO_ROOT}" && eval "${line}") > "${TMP}/$2.${i}" 2>&1 || echo "(exit $?)" >> "${TMP}/$2.${i}"
    # variables set by the line (POD=..., FC=..., export PATH) must persist
    case "${line}" in
      export\ *|[A-Z]*=*) eval "${line}" ;;
    esac
    sed 's/^/      /' "${TMP}/$2.${i}"
    line=""
  done < <(block "$1")
}
cd "${REPO_ROOT}"

step "Block 1: follow one request, layer by layer"
run_block 1 b1
expect_eq "block 1 has 7 command lines" "7" "$(block 1 | grep -c .)"
expect_match "listener 15001: catch-all to PassthroughCluster" '^0\.0\.0\.0 +15001 +ALL +PassthroughCluster' "$(cat "${TMP}/b1.3")"
expect_match "listener 15001: the chain for port 15001 itself (the blackhole)" 'Addr: \*:15001' "$(cat "${TMP}/b1.3")"
expect_match "listener 8080: plain-text HTTP/1.1 or h2c chain loading Route: 8080" 'Trans: raw_buffer; App: http/1.1,h2c +Route: 8080' "$(cat "${TMP}/b1.4")"
expect_match "listener 8080: everything else to PassthroughCluster" '^0\.0\.0\.0 +8080 +ALL +PassthroughCluster' "$(cat "${TMP}/b1.4")"
vhosts="$(awk '$1 == "8080" { print $2 }' "${TMP}/b1.5" | sort | paste -sd' ' -)"
expect_eq "route 8080: one virtual host per HTTP service on 8080, the ambient fraud-check included" \
  "fraud-check.payments-ambient.svc.cluster.local:8080 fraud-check.payments.svc.cluster.local:8080 payments-api.payments.svc.cluster.local:8080 risk-score.payments.svc.cluster.local:8080" "${vhosts}"
expect_eq "cluster: two outbound EDS clusters for fraud-check (8080, 8090), no subset" "8080:-:outbound:EDS 8090:-:outbound:EDS" \
  "$(awk -v f="${FQDN}" '$1 == f { print $2 ":" $3 ":" $4 ":" $5 }' "${TMP}/b1.6" | sort | paste -sd' ' -)"
expect_eq "endpoint: three HEALTHY endpoints of outbound|8080||${FQDN}" "3" \
  "$(grep -cE "HEALTHY +OK +outbound\|8080\|\|${FQDN//./\\.}$" "${TMP}/b1.7" || true)"
# "Add -o json to any of them": after steps 03 and 04 cleaned up, the virtual
# host is back to its single route, default
POD="$(pod_of payments app=payments-api)"
expect_eq "route 8080 -o json: fraud-check's virtual host has the single route default -> the subset-less cluster" \
  "default outbound|8080||${FQDN}" \
  "$(istioctl --context "${KUBE_CONTEXT}" proxy-config route "${POD}.payments" --name 8080 -o json \
     | jq -r --arg v "${FQDN}:8080" '[.[].virtualHosts[] | select(.name == $v) | .routes[] | "\(.name) \(.route.cluster)"] | join(";")')"

step "Block 2: proxy-status -v 1, at rest"
run_block 2 b2
rows="$(grep -cE '^[a-z0-9-]+\.(payments|payments-ingress|payments-ambient|istio-system) ' "${TMP}/b2.1" || true)"
expect_eq "9 proxies listed (5 sidecars, gateway, waypoint, 2 ztunnels)" "9" "${rows}"
expect_no_match "no type STALE, ERROR or NOT SENT" 'STALE|ERROR|NOT SENT' "$(cat "${TMP}/b2.1")"
# SYNCED per row: sidecars and gateway 5 (CDS, EDS, LDS, RDS, WDS), the
# waypoint 4 (no RDS), each ztunnel 2 (WADS, WDS)
synced() { awk -v r="$1" '$1 ~ r { n = 0; for (i = 1; i <= NF; i++) if ($i == "SYNCED") n++; print n }' "${TMP}/b2.1" | sort -u | paste -sd, -; }
expect_eq "5 sidecars + gateway: 5 types SYNCED each" "5" "$(synced '\\.(payments|payments-ingress)$')"
expect_eq "waypoint: 4 types SYNCED" "4" "$(synced '^waypoint-')"
expect_eq "ztunnels: 2 types SYNCED each" "2" "$(synced '^ztunnel-')"

step "Block 3: the rate limit by hand"
b3=()
while IFS= read -r l; do b3+=("${l}"); done < <(block 3)
expect_eq "block 3 starts with the apply" "kubectl --context kind-istio-p4 apply -f envoyfilter/fraud-check-local-ratelimit.yaml" "${b3[0]}"
# Run the apply, then "wait a few seconds" as the README says: until the
# filter is in the v2 proxy's inbound listener, plus 5 seconds. No wait for
# draining here: this is what a reader gets.
first="${TMP}/block3-first"; rest="${TMP}/block3-rest"
printf '%s\n' "${b3[0]}" > "${first}"; printf '%s\n' "${b3[@]:1}" > "${rest}"
V2="$(pod_of payments app=fraud-check,version=v2)"
out="$(cd "${REPO_ROOT}" && eval "${b3[0]}" 2>&1)"
printf '    $ %s\n%s\n' "${b3[0]}" "${out}" | sed 's/^/  /'
expect_match "apply: created" 'envoyfilter.networking.istio.io/fraud-check-local-ratelimit (created|configured)' "${out}"
in_v2() { inbound_http_filters "${V2}" payments 8080 | grep -c 'local_ratelimit' || true; }
wait_for 60 "2" in_v2 || true
sleep 5
rl() { envoy_stat payments "${V2}" "http_local_rate_limiter.http_local_rate_limit.$1"; }
en0="$(rl enabled)"; ok0="$(rl ok)"; enf0="$(rl enforced)"
i=0; line=""
while IFS= read -r l; do
  if [[ "${l}" == *\\ ]]; then line+="${l%\\}"; continue; fi
  line+="${l}"; i=$((i + 1))
  printf '    $ %s\n' "${line}"
  case "${line}" in
    FC=*) eval "${line}" ;;
    *) (cd "${REPO_ROOT}" && eval "${line}") > "${TMP}/b3.${i}" 2>&1 || true; sed 's/^/      /' "${TMP}/b3.${i}" ;;
  esac
  line=""
done < "${rest}"
expect_eq "FC is the v2 pod IP" "$(ip_of payments "${V2}")" "${FC:-}"
h="$(sort "${TMP}/b3.2" | uniq -c | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }')"
note "eight requests: ${h}"
# The limiter's own counters tell the two cases apart: requests that went
# through the new filter chain count in "enabled"; the rest rode connections
# opened before the push, on the old chain without the limiter (draining).
en=$(( $(rl enabled) - en0 )); okd=$(( $(rl ok) - ok0 )); enf=$(( $(rl enforced) - enf0 ))
c200="$(field 200 "${h}")"; c429="$(field 429 "${h}")"
note "limiter stats for the burst: enabled +${en}, ok +${okd}, enforced +${enf}; requests that skipped the limiter: $((8 - en))"
expect_eq "every 429 was enforced by the limiter" "${c429}" "${enf}"
expect_eq "every 200 is a limiter ok or a request on an old (draining) chain" "${c200}" "$((okd + 8 - en))"
if [ "${en}" -eq 8 ]; then
  expect_eq "the limiter saw all 8: 200=5 429=3, as the README and the article expect" "200=5 429=3" "${h}"
else
  note "the limiter saw ${en} of 8 (the draining case): ${h}"
  expect_eq "of the requests the limiter saw, it allowed 5 at most" "1" "$([ "${okd}" -le 5 ] && echo 1 || echo 0)"
fi

step "Block 4: delete the filter"
run_block 4 b4
expect_match "deleted" 'envoyfilter.networking.istio.io "fraud-check-local-ratelimit" deleted' "$(cat "${TMP}/b4.1")"
wait_for 60 "0" in_v2 || true
expect_eq "the filter left the v2 proxy" "0" "$(in_v2)"

step "Block 5: the full run and the teardown (text check only)"
block 5 | show
expect_eq "block 5 runs test-all then teardown" "bash scripts/test-all.sh|bash scripts/teardown.sh" \
  "$(block 5 | awk '{ print $1 " " $2 }' | paste -sd'|' -)"
finish
