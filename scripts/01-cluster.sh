#!/usr/bin/env bash
# Step 1: kind cluster, Gateway API CRDs (standard channel), Istio 1.31.2 with
# the ambient profile (istiod + istio-cni + ztunnel), mesh-wide access logs
# through the Telemetry API, and the workloads:
#   payments          sidecar mode: payments-api, fraud-check v1 (x2) and v2 (x1), risk-score
#   payments-ingress  Gateway API Gateway payments-gateway (an Envoy deployment)
#   payments-ambient  ambient mode: payments-api, fraud-check, and a waypoint
# Ends by checking that every proxy is connected to istiod and in sync.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_clis

step "kind cluster ${CLUSTER_NAME} ($(kind version))"
if grep -qx "${CLUSTER_NAME}" <<< "$(kind get clusters 2>/dev/null)"; then
  note "already exists"
else
  kind create cluster --config "${REPO_ROOT}/kind/cluster.yaml"
fi
assert_lab_context
k get nodes -o wide

step "Gateway API ${GATEWAY_API_VERSION} CRDs, standard channel"
k apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
k get crd -l gateway.networking.k8s.io/channel=standard \
  -o custom-columns='CRD:.metadata.name,VERSION:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version'

step "Istio ${ISTIO_VERSION}, ambient profile (istio/install.yaml)"
ictl install -y -f "${REPO_ROOT}/istio/install.yaml"
k -n istio-system get pods -o wide
apply_file "${REPO_ROOT}/observability/access-log.yaml"

step "Workloads"
apply_file "${REPO_ROOT}/apps/payments-sidecar.yaml"
apply_file "${REPO_ROOT}/ingress/gateway.yaml"
apply_file "${REPO_ROOT}/ingress/httproute.yaml"
apply_file "${REPO_ROOT}/apps/payments-ambient.yaml"
apply_file "${REPO_ROOT}/ambient/waypoint.yaml"
for d in payments-api fraud-check fraud-check-v2 risk-score; do
  k -n payments rollout status "deploy/${d}" --timeout=300s
done
k -n payments-ingress wait --for=condition=Programmed gateway/payments-gateway --timeout=180s
k -n payments-ingress rollout status deploy/payments-gateway-istio --timeout=180s
k -n payments-ambient wait --for=condition=Programmed gateway/waypoint --timeout=180s
for d in payments-api fraud-check waypoint; do
  k -n payments-ambient rollout status "deploy/${d}" --timeout=300s
done
k get pods -A -o wide | grep -E '^(payments|payments-ingress|payments-ambient) '

step "Checks"
expect_eq "istiod ready" "1" "$(k -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}')"
nodes="$(k get nodes --no-headers | wc -l | tr -d ' ')"
expect_eq "one ztunnel per node" "${nodes}" "$(k -n istio-system get ds ztunnel -o jsonpath='{.status.numberReady}')"
expect_eq "Gateway API CRDs from bundle ${GATEWAY_API_VERSION}, standard" "${GATEWAY_API_VERSION}/standard" \
  "$(k get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}/{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')"
# Istio 1.31 deploys distroless images by default: no shell in istiod or in
# istio-proxy (pilot-agent is there, sh is not).
expect_eq "control plane image" "pilot:${ISTIO_VERSION}-distroless" \
  "$(k -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*/||')"
expect_eq "sidecar image" "proxyv2:${ISTIO_VERSION}-distroless" \
  "$(k -n payments get pod -l app=payments-api -o jsonpath='{.items[0].spec.initContainers[?(@.name=="istio-proxy")].image}' | sed 's|.*/||')"
expect_eq "sidecar pods in payments (5, each with istio-proxy)" "5" \
  "$(k -n payments get pods -o json | jq '[.items[] | select([.spec.initContainers[]?.name, .spec.containers[].name] | index("istio-proxy"))] | length')"
expect_eq "ambient pods have no proxy container" "app fortio" \
  "$(k -n payments-ambient get pods -l 'app in (payments-api,fraud-check)' -o jsonpath='{.items[*].spec.containers[*].name}' | tr ' ' '\n' | sort | paste -sd' ' -)"

# The Envoy version inside the proxy image (server_info of the admin API).
ver="$(k -n payments exec deploy/payments-api -c istio-proxy -- pilot-agent request GET server_info 2>/dev/null | jq -r '.version')"
note "Envoy build in istio-proxy: ${ver}"
expect_match "the sidecar runs Envoy 1.39 (Istio 1.31 uses the release/v1.39 branch)" '/1\.39\.[0-9]+(-dev)?/' "${ver}"

step "istioctl proxy-status: every proxy connected and acknowledged"
# istioctl 1.31.2 verifies the istiod certificate when it talks XDS to it
# (against the istio-ca-root-cert ConfigMap); no --insecure needed or used.
ictl proxy-status | show
ps_json="$(ictl proxy-status -o json)"
proxies="$(jq '[.resources[]?] | length' <<< "${ps_json}")"
# 5 sidecars + ingress gateway + waypoint + one ztunnel per node
expect_eq "proxies connected to istiod: 5 sidecars + gateway + waypoint + ${nodes} ztunnels" "$((7 + nodes))" "${proxies}"
not_synced="$(jq -r '[.resources[]? | .node.id as $id | .genericXdsConfigs[]?
  | select(.typeUrl | test("(Listener|Cluster|RouteConfiguration|ClusterLoadAssignment)$"))
  | select(.configStatus != "SYNCED") | "\($id) \(.typeUrl | split(".") | last)=\(.configStatus // "UNKNOWN")"] | join("; ")' <<< "${ps_json}")"
expect_eq "every Envoy acknowledged its LDS, RDS, CDS and EDS (SYNCED)" "" "${not_synced}"
out="$(ictl proxy-status --authority not-istiod.example 2>&1 || true)"
note "with --authority not-istiod.example: $(tail -1 <<< "${out}" | cut -c1-220)"
expect_match "a wrong expected server name is refused (certificate verified)" 'x509|certificate|tls' "${out}"

step "Traffic"
expect_eq "payments-api -> fraud-check (sidecar)" "200 0" "$(req payments payments-api http://fraud-check:8080/warmup)"
expect_eq "payments-api -> fraud-check:8090 -> risk-score" "200 0" "$(req payments payments-api http://fraud-check:8090/warmup)"
expect_eq "payments-gateway (ingress) -> payments-api" "200 0" "$(req payments payments-api http://payments-gateway-istio.payments-ingress/v1/payments -H 'Host: api.payments.example')"
expect_eq "ambient payments-api -> fraud-check (through the waypoint)" "200 0" "$(req payments-ambient payments-api http://fraud-check:8080/warmup)"
finish
