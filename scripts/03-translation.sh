#!/usr/bin/env bash
# Step 3: every Istio resource becomes Envoy configuration. Apply one resource
# at a time and diff what the proxies received, before and after:
#   DestinationRule (subsets) -> new clusters, one per subset and port
#   VirtualService            -> routes inside the virtual host
#   ServiceEntry              -> a cluster and an SNI filter chain on 0.0.0.0_443
#   PeerAuthentication STRICT -> fewer inbound filter chains (no plain text)
#   AuthorizationPolicy       -> an RBAC HTTP filter in the inbound chain
# Needs Internet egress from the kind nodes (one request to api.github.com).
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context
reset_payments

FQDN="fraud-check.payments.svc.cluster.local"
CALLER="$(pod_of payments app=payments-api)"
RECV="$(pod_of payments app=fraud-check,version=v1)"

# snapshot <pod> -> one line per Envoy object: listeners, filter chains
# (with their match), HTTP filters per chain, routes, clusters
snapshot() {
  {
    pc listener "$1" payments | jq -r '.[] | .name as $l | "listener \($l)",
      (.filterChains[]? | "chain \($l) \(.name // "-") \(.filterChainMatch // {} | tojson)",
        (.filters[]? | select(.name == "envoy.filters.network.http_connection_manager")
          | "httpfilters \($l) \(.typedConfig.httpFilters | map(.name) | join(","))"))'
    pc route "$1" payments | jq -r '.[] | .name as $r | .virtualHosts[]? | .name as $v
      | .routes[]? | "route \($r) \($v) \(.name // "-") -> \(.route.cluster // .route.weightedClusters // .directResponse // "-" | tostring)"'
    pc cluster "$1" payments | jq -r '.[] | "cluster \(.name) \(.type // "-")"'
  } | sort -u
}
# show_diff <label> <before> <after>: prints how many objects were added and
# removed, then the first lines of each
show_diff() {
  local add rem
  add="$(comm -13 <(printf '%s\n' "$2") <(printf '%s\n' "$3"))"
  rem="$(comm -23 <(printf '%s\n' "$2") <(printf '%s\n' "$3"))"
  note "$1, objects changed: +$(grep -c . <<< "${add}" || true) -$(grep -c . <<< "${rem}" || true)"
  { grep . <<< "${add}" | sed 's/^/      + /' | head -12; grep . <<< "${rem}" | sed 's/^/      - /' | head -12; } | cut -c1-230 || true
}
clusters_of() { pc cluster "$1" payments | jq -r '.[].name' | grep -F "$2" | sort | paste -sd' ' -; }

step "DestinationRule with subsets v1 and v2 (translation/10-destinationrule-subsets.yaml)"
before="$(snapshot "${CALLER}")"
apply_file "${REPO_ROOT}/translation/10-destinationrule-subsets.yaml"
wait_for 60 "2" endpoint_count "${CALLER}" payments "outbound|8080|v1|${FQDN}" || true
after="$(snapshot "${CALLER}")"
show_diff "payments-api" "${before}" "${after}"
expect_eq "four new clusters: subsets v1/v2 x ports 8080/8090" \
  "outbound|8080|v1|${FQDN} outbound|8080|v2|${FQDN} outbound|8090|v1|${FQDN} outbound|8090|v2|${FQDN}" \
  "$(comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | awk '$1 == "cluster" { print $2 }' | sort | paste -sd' ' -)"
expect_eq "nothing else changed (no route, no listener)" "0" \
  "$(comm -3 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | grep -vc '^[[:space:]]*cluster ' || true)"
expect_eq "subset v1 cluster: 2 endpoints, v2: 1" "2 1" \
  "$(endpoint_count "${CALLER}" payments "outbound|8080|v1|${FQDN}") $(endpoint_count "${CALLER}" payments "outbound|8080|v2|${FQDN}")"
expect_eq "the route still targets the subset-less cluster: a DestinationRule alone routes nothing" "outbound|8080||${FQDN}" \
  "$(route_vhost "${CALLER}" payments 8080 "${FQDN}:8080" | jq -r '.routes[0].route.cluster')"

step "VirtualService canary/stable (translation/20-virtualservice-canary.yaml)"
before="$(snapshot "${CALLER}")"
apply_file "${REPO_ROOT}/translation/20-virtualservice-canary.yaml"
wait_for 60 "canary,stable" sh -c "istioctl --context ${KUBE_CONTEXT} proxy-config route ${CALLER}.payments --name 8080 -o json | jq -r '[.[].virtualHosts[] | select(.name == \"${FQDN}:8080\") | .routes[].name] | join(\",\")'" || true
after="$(snapshot "${CALLER}")"
show_diff "payments-api" "${before}" "${after}"
vh="$(route_vhost "${CALLER}" payments 8080 "${FQDN}:8080")"
expect_eq "virtual host routes, in order" "canary stable" "$(jq -r '[.routes[].name] | join(" ")' <<< "${vh}")"
expect_eq "canary: header x-canary exact true -> subset v2 cluster" "x-canary=true outbound|8080|v2|${FQDN}" \
  "$(jq -r '.routes[0] | "\(.match.headers[0].name)=\(.match.headers[0].stringMatch.exact) \(.route.cluster)"' <<< "${vh}")"
expect_eq "stable: no match condition -> subset v1 cluster" "/ outbound|8080|v1|${FQDN}" \
  "$(jq -r '.routes[1] | "\(.match.prefix) \(.route.cluster)"' <<< "${vh}")"
expect_eq "no cluster changed (the subsets came from the DestinationRule)" "0" \
  "$(comm -3 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | grep -c '^[[:space:]]*cluster ' || true)"
id="$(run_id)"
req payments payments-api "http://fraud-check:8080/${id}/canary" -H 'x-canary: true' >/dev/null
req payments payments-api "http://fraud-check:8080/${id}/stable" >/dev/null
log="$(proxy_log payments app=payments-api "${id}")"
expect_eq "access log: with the header -> route canary, cluster v2" "canary outbound|8080|v2|${FQDN}" \
  "$(kv route "$(grep -F /canary <<< "${log}")") $(kv cluster "$(grep -F /canary <<< "${log}")")"
expect_eq "access log: without it -> route stable, cluster v1" "stable outbound|8080|v1|${FQDN}" \
  "$(kv route "$(grep -F /stable <<< "${log}")") $(kv cluster "$(grep -F /stable <<< "${log}")")"
# The same facts as a CI gate after a rollout (ci/route-assert.sh): exit 0
# when the virtual host holds the named route to the cluster, 1 when not.
ra() { bash "${REPO_ROOT}/ci/route-assert.sh" --context "${KUBE_CONTEXT}" --wait 0 payments deployment/payments-api "${FQDN}:8080" "$@" 2>&1; }
out="$(ra canary "outbound|8080|v2|${FQDN}")" && rc=0 || rc=$?
note "${out}"
expect_eq "ci/route-assert.sh: canary -> v2 passes" "0" "${rc}"
out="$(ra stable "outbound|8080|v1|${FQDN}")" && rc=0 || rc=$?
expect_eq "ci/route-assert.sh: stable -> v1 passes" "0" "${rc}"
out="$(ra canary "outbound|8080|v1|${FQDN}")" && rc=0 || rc=$?
printf '%s\n' "${out}" | show
expect_eq "ci/route-assert.sh: canary -> v1 fails, listing what the virtual host holds" "1 2" \
  "${rc} $(grep -cE '^  (canary|stable) -> ' <<< "${out}" || true)"

step "ServiceEntry api.github.com:443 TLS, resolution DNS (translation/30-serviceentry-github.yaml)"
before="$(snapshot "${CALLER}")"
apply_file "${REPO_ROOT}/translation/30-serviceentry-github.yaml"
wait_for 60 "outbound|443||api.github.com" clusters_of "${CALLER}" "api.github.com" || true
after="$(snapshot "${CALLER}")"
show_diff "payments-api" "${before}" "${after}"
expect_eq "new cluster, type STRICT_DNS (resolution: DNS)" "outbound|443||api.github.com STRICT_DNS" \
  "$(pc cluster "${CALLER}" payments --fqdn api.github.com | jq -r '.[] | "\(.name) \(.type)"')"
expect_eq "listener 0.0.0.0_443 has a filter chain for SNI api.github.com" "outbound|443||api.github.com" \
  "$(pc listener "${CALLER}" payments --address 0.0.0.0 --port 443 | jq -r '[.[].filterChains[] | select(.filterChainMatch.serverNames // [] | index("api.github.com")) | .filters[] | select(.name == "envoy.filters.network.tcp_proxy") | .typedConfig.cluster] | join(",")')"
id="$(run_id)"
r="$(req payments payments-api "https://api.github.com/zen")"
expect_eq "payments-api -> https://api.github.com/zen" "200 0" "${r}"
sleep 3
log="$(k -n payments logs "${CALLER}" -c istio-proxy --since=30s | grep -F 'sni=api.github.com' | tail -1 || true)"
note "${log:0:300}"
expect_eq "access log (TCP): cluster" "outbound|443||api.github.com" "$(kv cluster "${log}")"

step "PeerAuthentication STRICT (translation/40-peerauthentication-strict.yaml)"
plain_chains() {
  pc listener "${RECV}" payments --port 15006 | jq '[.[0].filterChains[] | select(.filterChainMatch.destinationPort == 8080)
    | select((.filterChainMatch.transportProtocol // "") != "tls")] | length'
}
all_chains() { pc listener "${RECV}" payments --port 15006 | jq '[.[0].filterChains[] | select(.filterChainMatch.destinationPort == 8080)] | length'; }
b_plain="$(plain_chains)"; b_all="$(all_chains)"
before="$(snapshot "${RECV}")"
apply_file "${REPO_ROOT}/translation/40-peerauthentication-strict.yaml"
wait_for 60 "0" plain_chains || true
after="$(snapshot "${RECV}")"
show_diff "fraud-check" "${before}" "${after}"
note "inbound chains for port 8080: before ${b_all} (${b_plain} plain text), after $(all_chains)"
expect_between "PERMISSIVE: plain-text chains for port 8080 existed" 1 10 "${b_plain}"
expect_eq "STRICT: none left, only TLS chains" "0" "$(plain_chains)"
expect_eq "no cluster or route changed on fraud-check" "0" \
  "$(comm -3 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | grep -Ec '^[[:space:]]*(cluster|route) ' || true)"

step "AuthorizationPolicy ALLOW payments-api (translation/50-authorizationpolicy-fraud-check.yaml)"
before="$(snapshot "${RECV}")"
apply_file "${REPO_ROOT}/translation/50-authorizationpolicy-fraud-check.yaml"
has_rbac() { inbound_http_filters "${RECV}" payments 8080 | grep -c 'envoy.filters.http.rbac' || true; }
wait_for 60 "$(all_chains)" has_rbac || true
after="$(snapshot "${RECV}")"
show_diff "fraud-check" "${before}" "${after}"
httpf="$(inbound_http_filters "${RECV}" payments 8080 | sort -u)"
note "HTTP filters now: $(head -1 <<< "${httpf}")"
expect_eq "every inbound HTTP chain for 8080 has the RBAC filter" "$(all_chains)" "$(has_rbac)"
expect_eq "RBAC sits before the router (router still last)" "envoy.filters.http.router" "$(awk -F, '{ print $NF }' <<< "${httpf}" | sort -u)"
expect_match "the policy appears by name in the RBAC config" 'ns\[payments\]-policy\[fraud-check-allow\]-rule\[0\]' \
  "$(pc listener "${RECV}" payments --port 15006 | jq -c '[.. | objects | select(has("policies")) | .policies | keys[]] | unique')"
expect_eq "payments-api is still allowed" "200 0" "$(req payments payments-api http://fraud-check:8080/after-authz)"

reset_payments
finish
